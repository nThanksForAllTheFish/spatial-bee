import CoreHaptics
import UIKit

/// Block and hit haptics. Core Haptics when the device supports it, UIKit impact
/// feedback otherwise.
@MainActor
final class Haptics {
    private var engine: CHHapticEngine?
    private let impact = UIImpactFeedbackGenerator(style: .heavy)
    private let notify = UINotificationFeedbackGenerator()

    init() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            engine = try CHHapticEngine()
            engine?.resetHandler = { [weak self] in try? self?.engine?.start() }
            try engine?.start()
        } catch {
            engine = nil
        }
        impact.prepare()
        notify.prepare()
    }

    /// Saber contact: one sharp, strong tap.
    func block() {
        if let engine {
            let event = CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.9),
            ], relativeTime: 0)
            play(engine, [event])
        } else {
            impact.impactOccurred(intensity: 1.0)
        }
    }

    /// Stun hit: a half-second rumble.
    func hit() {
        if let engine {
            let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.9),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.25),
            ], relativeTime: 0, duration: 0.5)
            play(engine, [event])
        } else {
            notify.notificationOccurred(.error)
        }
    }

    private func play(_ engine: CHHapticEngine, _ events: [CHHapticEvent]) {
        do {
            let pattern = try CHHapticPattern(events: events, parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try engine.start()
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            impact.impactOccurred()
        }
    }
}
