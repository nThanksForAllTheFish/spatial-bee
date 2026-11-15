import Foundation
import simd

/// The training remote. Runs the patrol → hover → charge → fire → resolve loop in the
/// listener-aligned frame (x right, y up, z backward, unit directions). The controller
/// calls `update` every frame with the saber direction and forwards events to audio and
/// haptics.
@MainActor
final class TrainingGame: ObservableObject {

    enum Phase: String {
        case idle, patrolling, hovering, charging, resolving, roundOver
    }

    enum Event {
        case dart
        case chargeStart
        case fire(blocked: Bool)
        case roundOver
    }

    struct Shot: Identifiable {
        let id = UUID()
        let index: Int
        let blocked: Bool
        /// Time from the charge cue to the saber first entering the block cone.
        let reactionMs: Int?
        /// Angle between saber and remote at the moment of fire.
        let errorDeg: Double
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var shots: [Shot] = []
    @Published private(set) var score = 0
    @Published private(set) var streak = 0
    @Published private(set) var bestStreak = 0
    @Published private(set) var boltsFired = 0
    @Published private(set) var statusText = "Ready"

    var params = TuningConfig.defaults.training
    var onEvent: ((Event) -> Void)?

    /// Where the remote is, unit vector in the aligned frame.
    private(set) var remoteDirection = SIMD3<Double>(0, 0, -1)
    /// 0 at rest, ~1 at full dart speed. Drives the whoosh.
    private(set) var motionLevel: Double = 0
    /// 0 idle, rising to 1 across the charge. Drives the charge tone.
    private(set) var chargeLevel: Double = 0
    /// Angle between saber and remote right now, degrees. For the UI.
    private(set) var saberErrorDeg: Double = 0

    private var now: Double = 0
    private var phaseEndsAt: Double = 0
    private var moveFrom = SIMD3<Double>(0, 0, -1)
    private var moveTo = SIMD3<Double>(0, 0, -1)
    private var moveStart: Double = 0
    private var moveDuration: Double = 1
    private var chargeStart: Double = 0
    private var saberInConeSince: Double?
    private var lastDirection = SIMD3<Double>(0, 0, -1)

    // MARK: Control

    func startRound() {
        shots = []
        score = 0
        streak = 0
        bestStreak = 0
        boltsFired = 0
        now = 0
        remoteDirection = randomDirection(awayFrom: nil)
        lastDirection = remoteDirection
        beginPatrol()
    }

    func abort() {
        phase = .idle
        chargeLevel = 0
        motionLevel = 0
        statusText = "Ready"
    }

    // MARK: Per-frame

    func update(dt: Double, saberDirection: SIMD3<Double>) {
        guard phase != .idle, phase != .roundOver else { return }
        now += dt

        let errorRad = acos(max(-1, min(1, simd_dot(saberDirection, remoteDirection))))
        saberErrorDeg = errorRad * 180 / .pi
        let inCone = saberErrorDeg <= params.blockConeDeg

        switch phase {
        case .patrolling:
            let t = min(1, (now - moveStart) / moveDuration)
            let s = t * t * (3 - 2 * t)                     // smoothstep ease
            remoteDirection = slerp(moveFrom, moveTo, s)
            if t >= 1 {
                phase = .hovering
                phaseEndsAt = now + Double.random(in: params.hoverSecondsMin...params.hoverSecondsMax)
                statusText = "Hovering"
            }

        case .hovering:
            if now >= phaseEndsAt {
                phase = .charging
                chargeStart = now
                phaseEndsAt = now + params.chargeSeconds
                saberInConeSince = nil
                statusText = "Charging"
                onEvent?(.chargeStart)
            }

        case .charging:
            chargeLevel = min(1, (now - chargeStart) / params.chargeSeconds)
            if inCone, saberInConeSince == nil { saberInConeSince = now }
            if now >= phaseEndsAt {
                fire(inCone: inCone)
            }

        case .resolving:
            chargeLevel = 0
            if now >= phaseEndsAt {
                if boltsFired >= params.boltsPerRound {
                    phase = .roundOver
                    statusText = "Round over: \(score)/\(params.boltsPerRound) blocked"
                    onEvent?(.roundOver)
                } else {
                    beginPatrol()
                }
            }

        case .idle, .roundOver:
            break
        }

        // Motion level from angular speed, normalized to the configured dart speed.
        let step = acos(max(-1, min(1, simd_dot(lastDirection, remoteDirection)))) * 180 / .pi
        let speed = step / max(dt, 1e-3)
        let target = min(1, speed / max(params.remoteSpeedDegPerSec, 1))
        motionLevel += (target - motionLevel) * min(1, dt * 12)
        lastDirection = remoteDirection
    }

    // MARK: Phases

    private func beginPatrol() {
        moveFrom = remoteDirection
        moveTo = randomDirection(awayFrom: remoteDirection)
        let angle = acos(max(-1, min(1, simd_dot(moveFrom, moveTo)))) * 180 / .pi
        moveDuration = max(0.3, angle / max(params.remoteSpeedDegPerSec, 1))
        moveStart = now
        phase = .patrolling
        statusText = "Moving"
        onEvent?(.dart)
    }

    private func fire(inCone: Bool) {
        boltsFired += 1
        let reaction = saberInConeSince.map { Int(($0 - chargeStart) * 1000) }
        let shot = Shot(index: boltsFired, blocked: inCone, reactionMs: inCone ? reaction : nil, errorDeg: saberErrorDeg)
        shots.append(shot)
        if inCone {
            score += 1
            streak += 1
            bestStreak = max(bestStreak, streak)
            statusText = "Blocked" + (reaction.map { " · \($0) ms" } ?? "")
        } else {
            streak = 0
            statusText = String(format: "Hit · saber was %.0f° off", saberErrorDeg)
        }
        chargeLevel = 0
        onEvent?(.fire(blocked: inCone))
        phase = .resolving
        phaseEndsAt = now + params.resolveSeconds
    }

    // MARK: Geometry

    /// Random unit direction within the configured elevation band, at least 40 degrees
    /// away from `awayFrom` so every dart is a real move.
    private func randomDirection(awayFrom: SIMD3<Double>?) -> SIMD3<Double> {
        for _ in 0..<20 {
            let az = Double.random(in: -Double.pi..<Double.pi)
            let el = Double.random(in: params.elevationMinDeg...params.elevationMaxDeg) * .pi / 180
            let d = SIMD3(sin(az) * cos(el), sin(el), -cos(az) * cos(el))
            if let from = awayFrom {
                let angle = acos(max(-1, min(1, simd_dot(from, d)))) * 180 / .pi
                if angle < 40 { continue }
            }
            return d
        }
        return SIMD3(0, 0, -1)
    }

    private func slerp(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ t: Double) -> SIMD3<Double> {
        let d = max(-1, min(1, simd_dot(a, b)))
        let theta = acos(d)
        if theta < 1e-4 { return simd_normalize(a + (b - a) * t) }
        let s = sin(theta)
        return simd_normalize(a * (sin((1 - t) * theta) / s) + b * (sin(t * theta) / s))
    }
}
