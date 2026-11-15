import AVFoundation

/// The training remote's voice: a harmonic whine with a fluttering tremolo, a constant
/// high-frequency hiss so the pinna has something to work with, a whoosh of mid-band
/// noise when it darts, and a rising charge tone before it fires. Mono, rendered in an
/// AVAudioSourceNode. Same threading rules as InsectSynth.
final class RemoteSynth {

    struct Params {
        var f0: Double = 520
        var tremoloHz: Double = 13
        var tremoloDepth: Double = 0.5
        /// Constant hiss level, relative to the tone.
        var hissLevel: Double = 0.14
        /// Hiss band: one-pole high-pass at this frequency, low-pass at `hissCutoffHz`.
        var hissLowHz: Double = 2500
        var hissCutoffHz: Double = 11_000
        var gain: Double = 0.25
    }

    var params = Params()
    /// 0 at rest, 1 at full dart speed. Main thread writes.
    var motion: Double = 0
    /// 0 idle, 1 at the moment of fire. Main thread writes.
    var charge: Double = 0

    static let maxHarmonics = 48
    private let harmonicAmps = UnsafeMutablePointer<Double>.allocate(capacity: RemoteSynth.maxHarmonics)
    private var harmonicCount = 0

    /// Harmonic k (1-based) at k^-rolloff, normalized. Main thread only.
    func setHarmonics(count: Int, rolloff: Double) {
        let n = max(1, min(count, RemoteSynth.maxHarmonics))
        var norm = 0.0
        for k in 0..<n {
            let a = pow(Double(k + 1), -rolloff)
            harmonicAmps[k] = a
            norm += a
        }
        for k in 0..<n { harmonicAmps[k] /= max(norm, 1e-9) }
        harmonicCount = n
    }

    private let sampleRate: Double
    private var phase = 0.0, phaseT = 0.0, phaseV = 0.0, phaseC = 0.0
    private var rng: UInt32 = 0x1234ABCD
    private var whooshLP = 0.0, whooshHP = 0.0
    private var hissLP = 0.0, hissHP = 0.0
    private var motionSmooth = 0.0, chargeSmooth = 0.0
    private let twoPi = 2.0 * Double.pi

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        setHarmonics(count: 24, rolloff: 0.9)
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
        let count = harmonicCount
        let motionTarget = motion
        let chargeTarget = charge
        let smooth = 1 - exp(-1 / (sampleRate * 0.03))
        let nyquistLimit = sampleRate * 0.42
        let hissLPCoeff = 1 - exp(-twoPi * min(p.hissCutoffHz, sampleRate * 0.45) / sampleRate)
        let hissHPCoeff = 1 - exp(-twoPi * p.hissLowHz / sampleRate)

        for i in 0..<frameCount {
            motionSmooth += (motionTarget - motionSmooth) * smooth
            chargeSmooth += (chargeTarget - chargeSmooth) * smooth

            // Slow vibrato plus a pitch lift when moving.
            phaseV += twoPi * 0.9 / sampleRate
            let vibrato = 1 + 0.012 * sin(phaseV)
            let f = p.f0 * vibrato * (1 + 0.35 * motionSmooth)
            phase += twoPi * f / sampleRate
            if phase > twoPi { phase -= twoPi }

            phaseT += twoPi * p.tremoloHz / sampleRate
            if phaseT > twoPi { phaseT -= twoPi }
            let tremolo = 1 - p.tremoloDepth * (0.5 + 0.5 * sin(phaseT))

            // Harmonic series up into the pinna band.
            var tone = 0.0
            for k in 0..<count {
                if f * Double(k + 1) > nyquistLimit { break }
                tone += harmonicAmps[k] * sin(phase * Double(k + 1))
            }
            var s = tone * tremolo

            // Constant hiss: white noise, high-passed then low-passed, lightly tremolo'd
            // so it reads as part of the same object.
            let white = uniform() * 2 - 1
            hissLP += (white - hissLP) * hissLPCoeff
            hissHP += (hissLP - hissHP) * hissHPCoeff
            s += (hissLP - hissHP) * p.hissLevel * (0.7 + 0.3 * tremolo)

            // Whoosh: mid-band noise, level follows motion.
            whooshLP += (white - whooshLP) * 0.25
            whooshHP += (whooshLP - whooshHP) * 0.02
            s += (whooshLP - whooshHP) * 0.9 * motionSmooth

            // Charge: rising tone 500 -> 2200 Hz with two harmonics, level rising with it.
            if chargeSmooth > 0.001 {
                let fc = 500 + 1700 * chargeSmooth * chargeSmooth
                phaseC += twoPi * fc / sampleRate
                if phaseC > twoPi { phaseC -= twoPi }
                let chargeTone = sin(phaseC) + 0.5 * sin(2 * phaseC) + 0.3 * sin(3 * phaseC)
                s += 0.5 * chargeSmooth * chargeTone * (0.6 + 0.4 * sin(phaseT * 2))
            } else {
                phaseC = 0
            }

            out[i] = Float(s * p.gain)
        }
    }

    private func uniform() -> Double {
        rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5
        return Double(rng) / Double(UInt32.max)
    }
}

/// Short synthesized one-shots for the game, rendered once into PCM buffers.
enum OneShots {
    static func bolt(sampleRate: Double) -> AVAudioPCMBuffer {
        render(seconds: 0.28, sampleRate: sampleRate) { t, u in
            let f = 1800 * pow(0.18, u) + 120          // steep downward sweep
            let env = exp(-t * 14)
            var rng = UInt32(truncatingIfNeeded: Int(t * 1e6) &* 2654435761)
            rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5
            let noise = (Double(rng) / Double(UInt32.max) * 2 - 1) * 0.3 * exp(-t * 30)
            return (sin(2 * .pi * f * t) * 0.8 + noise) * env * 0.7
        }
    }

    /// Saber contact: a bright crack with two ringing partials and a low thump.
    static func clash(sampleRate: Double) -> AVAudioPCMBuffer {
        render(seconds: 0.45, sampleRate: sampleRate) { t, _ in
            var rng = UInt32(truncatingIfNeeded: Int(t * 1e6) &* 2246822519)
            rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5
            let noise = (Double(rng) / Double(UInt32.max) * 2 - 1) * exp(-t * 28)
            let ring = (sin(2 * .pi * 2150 * t) * 0.5 + sin(2 * .pi * 3330 * t) * 0.3) * exp(-t * 9)
            let thump = sin(2 * .pi * 90 * t) * exp(-t * 18) * 0.8
            let fizz = sin(2 * .pi * 120 * t) * sin(2 * .pi * 55 * t) * exp(-t * 5) * 0.3
            return (noise * 0.6 + ring + thump + fizz) * 0.6
        }
    }

    /// Stun hit: a harsh buzz that decays over half a second.
    static func stun(sampleRate: Double) -> AVAudioPCMBuffer {
        render(seconds: 0.65, sampleRate: sampleRate) { t, _ in
            let buzz = sin(2 * .pi * 62 * t) > 0 ? 1.0 : -1.0
            let carrier = sin(2 * .pi * 740 * t) * 0.5 + sin(2 * .pi * 1110 * t) * 0.3
            let env = t < 0.05 ? t / 0.05 : exp(-(t - 0.05) * 5)
            return buzz * carrier * env * 0.6
        }
    }

    private static func render(seconds: Double, sampleRate: Double,
                               _ f: (_ t: Double, _ u: Double) -> Double) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let data = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            let t = Double(i) / sampleRate
            data[i] = Float(f(t, t / seconds))
        }
        return buffer
    }
}
