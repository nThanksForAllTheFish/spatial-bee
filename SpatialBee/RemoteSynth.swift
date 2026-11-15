import AVFoundation

/// The training remote's voice: a hovering whine with a fluttering tremolo, a whoosh of
/// band-passed noise when it darts, and a rising charge tone before it fires. Mono,
/// rendered in an AVAudioSourceNode. Same threading rules as InsectSynth.
final class RemoteSynth {

    struct Params {
        var f0: Double = 520
        var tremoloHz: Double = 13
        var tremoloDepth: Double = 0.5
        var gain: Double = 0.25
    }

    var params = Params()
    /// 0 at rest, 1 at full dart speed. Main thread writes.
    var motion: Double = 0
    /// 0 idle, 1 at the moment of fire. Main thread writes.
    var charge: Double = 0

    private let sampleRate: Double
    private var phase1 = 0.0, phase2 = 0.0, phaseT = 0.0, phaseV = 0.0, phaseC = 0.0
    private var rng: UInt32 = 0x1234ABCD
    private var hp = 0.0, lp = 0.0
    private var motionSmooth = 0.0, chargeSmooth = 0.0
    private let twoPi = 2.0 * Double.pi

    init(sampleRate: Double) { self.sampleRate = sampleRate }

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
        let motionTarget = motion
        let chargeTarget = charge
        let smooth = 1 - exp(-1 / (sampleRate * 0.03))

        for i in 0..<frameCount {
            motionSmooth += (motionTarget - motionSmooth) * smooth
            chargeSmooth += (chargeTarget - chargeSmooth) * smooth

            // Slow vibrato plus a pitch lift when moving.
            phaseV += twoPi * 0.9 / sampleRate
            let vibrato = 1 + 0.012 * sin(phaseV)
            let f = p.f0 * vibrato * (1 + 0.35 * motionSmooth)

            phase1 += twoPi * f / sampleRate
            phase2 += twoPi * f * 1.5 / sampleRate   // a fifth above, thinner
            if phase1 > twoPi { phase1 -= twoPi }
            if phase2 > twoPi { phase2 -= twoPi }

            phaseT += twoPi * p.tremoloHz / sampleRate
            if phaseT > twoPi { phaseT -= twoPi }
            let tremolo = 1 - p.tremoloDepth * (0.5 + 0.5 * sin(phaseT))

            var s = (sin(phase1) + 0.45 * sin(phase2) + 0.25 * sin(2 * phase1)) / 1.7 * tremolo

            // Whoosh: band-passed noise, level follows motion.
            let white = uniform() * 2 - 1
            lp += (white - lp) * 0.25
            hp += (lp - hp) * 0.02
            s += (lp - hp) * 0.9 * motionSmooth

            // Charge: rising tone 500 -> 2200 Hz, level rising with it.
            if chargeSmooth > 0.001 {
                let fc = 500 + 1700 * chargeSmooth * chargeSmooth
                phaseC += twoPi * fc / sampleRate
                if phaseC > twoPi { phaseC -= twoPi }
                s += 0.7 * chargeSmooth * sin(phaseC) * (0.6 + 0.4 * sin(phaseT * 2))
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
