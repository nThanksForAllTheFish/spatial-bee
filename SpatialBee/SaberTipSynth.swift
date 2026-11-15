import AVFoundation

/// The bright end of the saber. Sits a blade length out along the pointing direction
/// while the low hum (an InsectSynth) sits at the hilt. Three parts:
///
/// - upper harmonics of the hum, so the tip and hilt read as one object;
/// - a fizz: band-limited noise in the pinna band with a crackle modulation, which is
///   what lets the ear place the tip in elevation and front-back;
/// - a swing: mid-band noise whose level follows the blade's angular speed, with a
///   pitch lift on the harmonics.
///
/// Same threading rules as InsectSynth.
final class SaberTipSynth {

    struct Params {
        var humF0: Double = 92
        var humLevel: Double = 0.35
        var fizzLevel: Double = 0.5
        var fizzLowHz: Double = 3000
        var fizzCutoffHz: Double = 10_000
        var swingLevel: Double = 0.6
        var gain: Double = 0.18
    }

    var params = Params()
    /// 0 at rest, 1 at a fast sweep. Main thread writes.
    var swing: Double = 0

    private let sampleRate: Double
    private var phase = 0.0
    private var rng: UInt32 = 0x7A3F19C5
    private var fizzLP = 0.0, fizzHP = 0.0
    private var swingLP = 0.0, swingHP = 0.0
    private var crackle = 1.0, crackleTarget = 1.0
    private var samplesUntilCrackle = 0
    private var swingSmooth = 0.0
    private let twoPi = 2.0 * Double.pi

    // Harmonics 4 through 20 of the hum, falling off, normalized.
    private static let harmonics: [Double] = {
        let raw = (4...20).map { pow(Double($0), -1.1) }
        let norm = raw.reduce(0, +)
        return raw.map { $0 / norm }
    }()
    private let harmonicAmps = UnsafeMutablePointer<Double>.allocate(capacity: 17)

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        for (i, a) in SaberTipSynth.harmonics.enumerated() { harmonicAmps[i] = a }
    }

    deinit { harmonicAmps.deallocate() }

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
        let crackleInterval = Int(sampleRate * 0.012)   // ~80 Hz retarget, a sputtering texture
        let nyquistLimit = sampleRate * 0.42

        for i in 0..<frameCount {
            swingSmooth += (swingTarget - swingSmooth) * smooth

            // Hum harmonics with a pitch lift on the swing.
            let f0 = p.humF0 * (1 + 0.18 * swingSmooth)
            phase += twoPi * f0 / sampleRate
            if phase > twoPi { phase -= twoPi }
            var hum = 0.0
            for (i, k) in (4...20).enumerated() {
                if f0 * Double(k) > nyquistLimit { break }
                hum += harmonicAmps[i] * sin(phase * Double(k))
            }

            // Fizz: pinna-band noise with crackle.
            if samplesUntilCrackle <= 0 {
                samplesUntilCrackle = crackleInterval
                crackleTarget = 0.4 + 0.6 * uniform() * uniform()
            }
            samplesUntilCrackle -= 1
            crackle += (crackleTarget - crackle) * 0.002
            let white = uniform() * 2 - 1
            fizzLP += (white - fizzLP) * fizzLPCoeff
            fizzHP += (fizzLP - fizzHP) * fizzHPCoeff
            let fizz = (fizzLP - fizzHP) * crackle

            // Swing: mid-band noise, level follows angular speed.
            swingLP += (white - swingLP) * 0.2
            swingHP += (swingLP - swingHP) * 0.015
            let swingNoise = (swingLP - swingHP) * swingSmooth

            let s = hum * p.humLevel * (1 + 0.5 * swingSmooth)
                  + fizz * p.fizzLevel
                  + swingNoise * p.swingLevel
            out[i] = Float(s * p.gain)
        }
    }

    private func uniform() -> Double {
        rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5
        return Double(rng) / Double(UInt32.max)
    }
}
