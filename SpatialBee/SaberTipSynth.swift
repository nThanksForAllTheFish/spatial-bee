import AVFoundation

/// The bright end of the saber. Sits a blade length out along the pointing direction
/// while the low hum (an InsectSynth) sits at the hilt. Built to sound electrical, not
/// insect-like: no dense harmonic stack and no flutter in the wingbeat band. Four parts:
///
/// - beating partials: three upper partials of the hum, each a detuned pair a few hertz
///   apart, so the tip has the slow beat of the film saber instead of a buzz;
/// - sizzle: band-limited noise in the pinna band with a slow, shallow random envelope;
/// - ticks: sparse, sharp, high-passed noise bursts at a random (Poisson) rate, the
///   small-arc crackle. These carry most of the elevation and front-back cue;
/// - swing: mid-band noise whose level follows the blade's angular speed, with a pitch
///   lift on the partials.
///
/// Same threading rules as InsectSynth: no allocation in render, params read once per
/// buffer.
final class SaberTipSynth {

    struct Params {
        var humF0: Double = 92
        var humLevel: Double = 0.35
        /// Beat rate of each detuned partial pair, Hz.
        var beatHz: Double = 2.5
        /// Sizzle (slow-modulated pinna-band noise) level.
        var fizzLevel: Double = 0.35
        var fizzLowHz: Double = 3000
        var fizzCutoffHz: Double = 10_000
        /// Tick (arc crackle) level and mean rate.
        var tickLevel: Double = 0.6
        var ticksPerSecond: Double = 25
        var swingLevel: Double = 0.6
        var gain: Double = 0.18
    }

    var params = Params()
    /// 0 at rest, 1 at a fast sweep. Main thread writes.
    var swing: Double = 0

    private let sampleRate: Double
    private var rng: UInt32 = 0x7A3F19C5
    private var fizzLP = 0.0, fizzHP = 0.0
    private var swingLP = 0.0, swingHP = 0.0
    private var tickHP = 0.0
    private var tickEnv = 0.0
    private var samplesUntilTick = 0
    private var sizzle = 1.0, sizzleTarget = 1.0
    private var samplesUntilSizzle = 0
    private var swingSmooth = 0.0
    private let twoPi = 2.0 * Double.pi

    // Partials of the hum: harmonic numbers and relative levels, normalized.
    private static let partialHarmonics: [Double] = [3, 5, 8]
    private static let partialLevels: [Double] = {
        let raw = [0.5, 0.3, 0.2]
        let norm = raw.reduce(0, +)
        return raw.map { $0 / norm }
    }()
    // Two phases per partial, the pair detuned by ±beatHz/2.
    private let phases = UnsafeMutablePointer<Double>.allocate(capacity: 6)

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        for i in 0..<6 { phases[i] = Double(i) * 0.7 }
    }

    deinit { phases.deallocate() }

    func makeSourceNode() -> AVAudioSourceNode {
        AVAudioSourceNode { [unowned self] _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let buffer = abl.first, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            self.render(into: data, frameCount: Int(frameCount))
            for extra in abl.dropFirst() {
                if let d = extra.mData?.assumingMemoryBound(to: Float.self) { d.update(from: data, count: Int(frameCount)) }
            }
            return noErr
        }
    }

    private func render(into out: UnsafeMutablePointer<Float>, frameCount: Int) {
        let p = params
        let swingTarget = swing
        let smooth = 1 - exp(-1 / (sampleRate * 0.04))
        let fizzLPCoeff = 1 - exp(-twoPi * min(p.fizzCutoffHz, sampleRate * 0.45) / sampleRate)
        let fizzHPCoeff = 1 - exp(-twoPi * p.fizzLowHz / sampleRate)
        let tickHPCoeff = 1 - exp(-twoPi * 2500 / sampleRate)
        let tickDecay = exp(-1 / (sampleRate * 0.0015))          // 1.5 ms bursts
        let sizzleInterval = Int(sampleRate * 0.15)              // retarget ~7 Hz
        let sizzleSmooth = 1 - exp(-1 / (sampleRate * 0.06))     // 60 ms glide, no flutter
        let tickRate = max(p.ticksPerSecond, 0.01)
        let nyquistLimit = sampleRate * 0.42
        let halfBeat = p.beatHz * 0.5

        for i in 0..<frameCount {
            swingSmooth += (swingTarget - swingSmooth) * smooth

            // Beating partials with a pitch lift on the swing.
            let f0 = p.humF0 * (1 + 0.18 * swingSmooth)
            var partials = 0.0
            for k in 0..<3 {
                let fc = f0 * SaberTipSynth.partialHarmonics[k]
                if fc > nyquistLimit { continue }
                let fa = fc - halfBeat, fb = fc + halfBeat
                phases[2 * k] += twoPi * fa / sampleRate
                phases[2 * k + 1] += twoPi * fb / sampleRate
                if phases[2 * k] > twoPi { phases[2 * k] -= twoPi }
                if phases[2 * k + 1] > twoPi { phases[2 * k + 1] -= twoPi }
                partials += SaberTipSynth.partialLevels[k] * 0.5 * (sin(phases[2 * k]) + sin(phases[2 * k + 1]))
            }

            // Sizzle: pinna-band noise under a slow, shallow envelope.
            if samplesUntilSizzle <= 0 {
                samplesUntilSizzle = sizzleInterval
                sizzleTarget = 0.6 + 0.4 * uniform()
            }
            samplesUntilSizzle -= 1
            sizzle += (sizzleTarget - sizzle) * sizzleSmooth
            let white = uniform() * 2 - 1
            fizzLP += (white - fizzLP) * fizzLPCoeff
            fizzHP += (fizzLP - fizzHP) * fizzHPCoeff
            let fizz = (fizzLP - fizzHP) * sizzle

            // Ticks: Poisson-timed, exponentially decaying noise bursts, high-passed.
            if samplesUntilTick <= 0 {
                let u = max(uniform(), 1e-6)
                samplesUntilTick = Int(-log(u) / tickRate * sampleRate)
                tickEnv = 0.5 + 0.5 * uniform()
            }
            samplesUntilTick -= 1
            tickEnv *= tickDecay
            let burst = white * tickEnv
            tickHP += (burst - tickHP) * tickHPCoeff
            let tick = burst - tickHP

            // Swing: mid-band noise, level follows angular speed.
            swingLP += (white - swingLP) * 0.2
            swingHP += (swingLP - swingHP) * 0.015
            let swingNoise = (swingLP - swingHP) * swingSmooth

            let s = partials * p.humLevel * (1 + 0.5 * swingSmooth)
                  + fizz * p.fizzLevel
                  + tick * p.tickLevel
                  + swingNoise * p.swingLevel
            out[i] = Float(s * p.gain)
        }
    }

    private func uniform() -> Double {
        rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5
        return Double(rng) / Double(UInt32.max)
    }
}
