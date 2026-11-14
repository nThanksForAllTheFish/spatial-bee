import AVFoundation

/// Which insect to synthesize. Values are wingbeat fundamentals and harmonic shapes
/// chosen by ear to read as "bee" and "mosquito", not measured spectra.
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

    /// Wingbeat fundamental in Hz.
    var fundamental: Double {
        switch self {
        case .bee: return 230
        case .mosquito: return 620
        }
    }

    /// Relative harmonic amplitudes, index 0 is the fundamental. The series must reach
    /// the pinna band (roughly 5 to 12 kHz) or the HRTF has nothing to shape there and
    /// elevation collapses to left-right panning. Power-law rolloff keeps it bright
    /// without sounding like a buzzer.
    var harmonics: [Double] {
        switch self {
        case .bee:      return (1...40).map { pow(Double($0), -0.8) }
        case .mosquito: return (1...16).map { pow(Double($0), -1.0) }
        }
    }

    /// Level of the breathy noise component relative to the tone.
    var noiseLevel: Double {
        switch self {
        case .bee: return 0.18
        case .mosquito: return 0.06
        }
    }

    /// One-pole low-pass coefficient for the noise, as a cutoff in Hz.
    var noiseCutoffHz: Double {
        switch self {
        case .bee: return 9_000
        case .mosquito: return 10_000
        }
    }

    /// How far the pitch random-walks, as a fraction of the fundamental.
    var pitchWander: Double {
        switch self {
        case .bee: return 0.05
        case .mosquito: return 0.08
        }
    }
}

/// Real-time additive synthesizer for a single insect. Produces mono float audio
/// from an AVAudioSourceNode render block. The render block never allocates or locks.
///
/// Parameters are plain stored properties written from the main thread and read from
/// the audio thread. Each is a single 64-bit aligned store on arm64, so the audio thread
/// sees either the old or the new value, never a torn one. Good enough for a prototype.
final class InsectSynth {

    // MARK: Parameters (main thread writes, audio thread reads)

    var species: InsectSpecies = .bee
    /// Doppler frequency ratio: 1.0 at rest, > 1 approaching, < 1 receding.
    var dopplerRatio: Double = 1.0
    /// Output gain. Keep well under 1 so HRTF filtering has headroom.
    var gain: Double = 0.22
    /// Low-pass cutoff on the whole insect before spatialization, Hz. The elevation
    /// experiment: pull it below ~4 kHz and the pinna cues disappear.
    var cutoffHz: Double = 16_000

    // MARK: State (audio thread only)

    private let sampleRate: Double
    private var phase: Double = 0
    private var wander: Double = 0          // smoothed pitch offset, fraction of f0
    private var wanderTarget: Double = 0
    private var flutter: Double = 1         // smoothed amplitude multiplier
    private var flutterTarget: Double = 1
    private var samplesUntilRetarget = 0
    private var rng: UInt32 = 0x9E3779B9
    private var noiseLP: Double = 0

    // Second-order Butterworth low-pass (RBJ cookbook), coefficients recomputed only
    // when the cutoff changes. State in direct form I.
    private var lpCutoff: Double = -1
    private var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    /// Build the AVAudioSourceNode that pulls audio from this synth.
    func makeSourceNode() -> AVAudioSourceNode {
        AVAudioSourceNode { [unowned self] _, _, frameCount, audioBufferList -> OSStatus in
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let buffer = ablPointer.first,
                  let data = buffer.mData?.assumingMemoryBound(to: Float.self) else {
                return noErr
            }
            self.render(into: data, frameCount: Int(frameCount))
            // Mono source: if the engine ever hands us more buffers, copy channel 0.
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
        let species = self.species
        let doppler = self.dopplerRatio
        let gain = self.gain
        let harmonics = species.harmonics
        let noiseLevel = species.noiseLevel
        let wanderDepth = species.pitchWander

        // Pitch and amplitude targets jump every ~40 ms and are smoothed per sample,
        // which gives the continuous wobble of a real wingbeat.
        let retargetInterval = Int(sampleRate * 0.04)
        let smoothing = 1.0 - exp(-1.0 / (sampleRate * 0.02))   // ~20 ms time constant
        let noiseCoefficient = 1.0 - exp(-twoPiConst * species.noiseCutoffHz / sampleRate)
        let twoPi = twoPiConst
        let nyquistLimit = sampleRate * 0.42
        updateLowPassIfNeeded(cutoff: min(self.cutoffHz, sampleRate * 0.45))

        for i in 0..<frameCount {
            if samplesUntilRetarget <= 0 {
                samplesUntilRetarget = retargetInterval
                // Mean-reverting random walk so the pitch never drifts off entirely.
                wanderTarget = wanderTarget * 0.7 + gaussian() * wanderDepth * 0.6
                flutterTarget = 1.0 + gaussian() * 0.12
            }
            samplesUntilRetarget -= 1

            wander += (wanderTarget - wander) * smoothing
            flutter += (flutterTarget - flutter) * smoothing

            let f0 = species.fundamental * (1.0 + wander) * doppler
            phase += twoPi * f0 / sampleRate
            if phase > twoPi { phase -= twoPi }

            var sample = 0.0
            var norm = 0.0
            for (k, amp) in harmonics.enumerated() {
                let harmonicFrequency = f0 * Double(k + 1)
                if harmonicFrequency > nyquistLimit { break }
                sample += amp * sin(phase * Double(k + 1))
                norm += amp
            }
            sample /= max(norm, 1e-6)

            // Low-passed white noise adds the breathy buzz of the body and wings.
            let white = uniform() * 2.0 - 1.0
            noiseLP += (white - noiseLP) * noiseCoefficient
            sample += noiseLP * noiseLevel

            // Bandwidth low-pass.
            let x0 = sample
            let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x0; y2 = y1; y1 = y0

            out[i] = Float(y0 * flutter * gain)
        }
    }

    private func updateLowPassIfNeeded(cutoff: Double) {
        guard cutoff != lpCutoff else { return }
        lpCutoff = cutoff
        let w0 = twoPiConst * cutoff / sampleRate
        let cosw = cos(w0), sinw = sin(w0)
        let q = 0.7071
        let alpha = sinw / (2 * q)
        let a0 = 1 + alpha
        b0 = ((1 - cosw) / 2) / a0
        b1 = (1 - cosw) / a0
        b2 = b0
        a1 = (-2 * cosw) / a0
        a2 = (1 - alpha) / a0
    }

    private let twoPiConst = 2.0 * Double.pi

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
