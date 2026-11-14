import AVFoundation

/// Which insect to synthesize. The numbers live in `TuningConfig`, not here.
enum InsectSpecies: String, CaseIterable, Identifiable {
    case bee
    case mosquito

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bee: return "Bee"
        case .mosquito: return "Mosquito"
        }
    }
}

/// Real-time additive synthesizer for a single insect. Produces mono float audio
/// from an AVAudioSourceNode render block. The render block never allocates or locks.
///
/// Parameters are plain stored properties written from the main thread and read from
/// the audio thread. Each scalar is a single 64-bit aligned store on arm64, so the audio
/// thread sees either the old or the new value, never a torn one. A struct of several
/// scalars can be read mid-update; for a prototype that is harmless.
final class InsectSynth {

    /// Scalar parameters. Written from the main thread, read per render block.
    struct Params {
        var f0: Double = 230
        var pitchWander: Double = 0.05
        var noiseLevel: Double = 0.18
        var noiseCutoffHz: Double = 9_000
        var gain: Double = 0.22
        /// Low-pass cutoff on the whole insect before spatialization, Hz.
        var cutoffHz: Double = 16_000
        /// High-shelf tilt for the pinna-band experiment.
        var shelfFrequencyHz: Double = 5_000
        var shelfGainDb: Double = 0
    }

    var params = Params()

    /// Doppler frequency ratio: 1.0 at rest, > 1 approaching, < 1 receding.
    var dopplerRatio: Double = 1.0

    // MARK: Harmonic series (fixed buffer so the audio thread never touches an Array)

    static let maxHarmonics = 64
    private let harmonicAmps = UnsafeMutablePointer<Double>.allocate(capacity: InsectSynth.maxHarmonics)
    private var harmonicCount = 0

    /// Fill the harmonic table: amplitude of harmonic k (1-based) is k^-rolloff,
    /// normalized so the series sums to one. Main thread only.
    func setHarmonics(count: Int, rolloff: Double) {
        let n = max(1, min(count, InsectSynth.maxHarmonics))
        var norm = 0.0
        for k in 0..<n {
            let a = pow(Double(k + 1), -rolloff)
            harmonicAmps[k] = a
            norm += a
        }
        for k in 0..<n { harmonicAmps[k] /= max(norm, 1e-9) }
        harmonicCount = n   // published last so a reader never sees uninitialized slots
    }

    // MARK: State (audio thread only)

    private let sampleRate: Double
    private var phase: Double = 0
    private var wander: Double = 0
    private var wanderTarget: Double = 0
    private var flutter: Double = 1
    private var flutterTarget: Double = 1
    private var samplesUntilRetarget = 0
    private var rng: UInt32 = 0x9E3779B9
    private var noiseLP: Double = 0

    // Two biquads in direct form I: a Butterworth low-pass and a high shelf.
    private var lp = Biquad()
    private var shelf = Biquad()
    private var lpCutoff: Double = -1
    private var shelfKey: (Double, Double) = (-1, -1)

    private let twoPi = 2.0 * Double.pi

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        setHarmonics(count: 40, rolloff: 0.8)
    }

    deinit { harmonicAmps.deallocate() }

    /// Build the AVAudioSourceNode that pulls audio from this synth.
    func makeSourceNode() -> AVAudioSourceNode {
        AVAudioSourceNode { [unowned self] _, _, frameCount, audioBufferList -> OSStatus in
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let buffer = ablPointer.first,
                  let data = buffer.mData?.assumingMemoryBound(to: Float.self) else {
                return noErr
            }
            self.render(into: data, frameCount: Int(frameCount))
            for extra in ablPointer.dropFirst() {
                if let extraData = extra.mData?.assumingMemoryBound(to: Float.self) {
                    extraData.update(from: data, count: Int(frameCount))
                }
            }
            return noErr
        }
    }

    // MARK: Rendering

    private func render(into out: UnsafeMutablePointer<Float>, frameCount: Int) {
        let p = self.params
        let doppler = self.dopplerRatio
        let count = self.harmonicCount

        let retargetInterval = Int(sampleRate * 0.04)
        let smoothing = 1.0 - exp(-1.0 / (sampleRate * 0.02))   // ~20 ms time constant
        let noiseCoefficient = 1.0 - exp(-twoPi * p.noiseCutoffHz / sampleRate)
        let nyquistLimit = sampleRate * 0.42

        updateFilters(cutoff: min(p.cutoffHz, sampleRate * 0.45),
                      shelfHz: min(p.shelfFrequencyHz, sampleRate * 0.4),
                      shelfDb: p.shelfGainDb)

        for i in 0..<frameCount {
            if samplesUntilRetarget <= 0 {
                samplesUntilRetarget = retargetInterval
                wanderTarget = wanderTarget * 0.7 + gaussian() * p.pitchWander * 0.6
                flutterTarget = 1.0 + gaussian() * 0.12
            }
            samplesUntilRetarget -= 1

            wander += (wanderTarget - wander) * smoothing
            flutter += (flutterTarget - flutter) * smoothing

            let f0 = p.f0 * (1.0 + wander) * doppler
            phase += twoPi * f0 / sampleRate
            if phase > twoPi { phase -= twoPi }

            var sample = 0.0
            for k in 0..<count {
                let harmonicFrequency = f0 * Double(k + 1)
                if harmonicFrequency > nyquistLimit { break }
                sample += harmonicAmps[k] * sin(phase * Double(k + 1))
            }

            let white = uniform() * 2.0 - 1.0
            noiseLP += (white - noiseLP) * noiseCoefficient
            sample += noiseLP * p.noiseLevel

            sample = shelf.process(sample)
            sample = lp.process(sample)

            out[i] = Float(sample * flutter * p.gain)
        }
    }

    private func updateFilters(cutoff: Double, shelfHz: Double, shelfDb: Double) {
        if cutoff != lpCutoff {
            lpCutoff = cutoff
            lp.setLowPass(cutoff: cutoff, q: 0.7071, sampleRate: sampleRate)
        }
        if shelfKey != (shelfHz, shelfDb) {
            shelfKey = (shelfHz, shelfDb)
            shelf.setHighShelf(frequency: shelfHz, gainDb: shelfDb, sampleRate: sampleRate)
        }
    }

    // MARK: Cheap RNG (xorshift), safe for the audio thread

    private func uniform() -> Double {
        rng ^= rng << 13
        rng ^= rng >> 17
        rng ^= rng << 5
        return Double(rng) / Double(UInt32.max)
    }

    /// Approximate Gaussian from the sum of three uniforms, variance ~0.25.
    private func gaussian() -> Double {
        (uniform() + uniform() + uniform()) - 1.5
    }
}

/// RBJ cookbook biquad, direct form I, coefficients normalized by a0.
struct Biquad {
    private var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

    @inline(__always)
    mutating func process(_ x0: Double) -> Double {
        let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x0; y2 = y1; y1 = y0
        return y0
    }

    mutating func setLowPass(cutoff: Double, q: Double, sampleRate: Double) {
        let w0 = 2 * Double.pi * cutoff / sampleRate
        let cosw = cos(w0), sinw = sin(w0)
        let alpha = sinw / (2 * q)
        let a0 = 1 + alpha
        b0 = ((1 - cosw) / 2) / a0
        b1 = (1 - cosw) / a0
        b2 = b0
        a1 = (-2 * cosw) / a0
        a2 = (1 - alpha) / a0
    }

    /// Shelf slope S = 1.
    mutating func setHighShelf(frequency: Double, gainDb: Double, sampleRate: Double) {
        let A = pow(10, gainDb / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let cosw = cos(w0), sinw = sin(w0)
        let alpha = sinw / 2 * sqrt(2.0)
        let sqA2 = 2 * sqrt(A) * alpha
        let a0 = (A + 1) - (A - 1) * cosw + sqA2
        b0 = (A * ((A + 1) + (A - 1) * cosw + sqA2)) / a0
        b1 = (-2 * A * ((A - 1) + (A + 1) * cosw)) / a0
        b2 = (A * ((A + 1) + (A - 1) * cosw - sqA2)) / a0
        a1 = (2 * ((A - 1) - (A + 1) * cosw)) / a0
        a2 = ((A + 1) - (A - 1) * cosw - sqA2) / a0
    }
}
