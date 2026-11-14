import AVFoundation
import Combine
import QuartzCore
import simd

/// Glue between the phone's pointing direction and the spatial audio source.
///
/// Every frame it takes the world-frame pointing vector (or a synthetic orbit when
/// Auto-orbit is on), expresses it in the listener's frame, pushes it out to a chosen
/// radius, adds a small random-walk wobble so the insect never sits perfectly still,
/// and hands the result to the audio engine. Radial velocity drives a Doppler ratio
/// on the synthesizer.
@MainActor
final class BeeController: ObservableObject {

    let audio = SpatialAudioEngine()
    let motion = MotionTracker()

    // MARK: User settings

    @Published var species: InsectSpecies = .bee {
        didSet { audio.species = species }
    }
    /// Distance from the head center, meters.
    @Published var radius: Double = 0.6
    @Published var pointingAxis: PointingAxis = .topEdge {
        didSet { motion.axis = pointingAxis }
    }
    /// When on, the insect circles the head on its own. Useful in the simulator,
    /// which has no motion sensors, and as a sanity check on a device.
    @Published var autoOrbit = false
    /// Revolutions per second for auto-orbit. Positive is counterclockwise seen from above.
    @Published var orbitRate: Double = 0.15

    // MARK: Readouts

    @Published private(set) var isRunning = false
    /// Azimuth in degrees, 0 ahead, positive to the right.
    @Published private(set) var azimuthDegrees: Double = 0
    /// Elevation in degrees, positive above the ears.
    @Published private(set) var elevationDegrees: Double = 0
    @Published private(set) var distanceMeters: Double = 0

    // MARK: Internals

    private var displayLink: CADisplayLink?
    /// Yaw of the listener's forward direction in the world frame, radians.
    private var forwardYaw: Double = 0
    private var hasCenteredOnce = false
    private var orbitAngle: Double = 0
    private var wobble = SIMD3<Double>(0, 0, 0)
    private var lastDistance: Double?
    private var lastTimestamp: CFTimeInterval?
    private var smoothedRadialVelocity: Double = 0

    // MARK: Control

    func start() {
        guard !isRunning else { return }
        audio.species = species
        motion.axis = pointingAxis
        audio.start()
        motion.start()
        if !hasCenteredOnce {
            // Give CoreMotion a moment to settle before taking the first forward reference.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.recenter()
            }
        }
        startDisplayLink()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        displayLink?.invalidate()
        displayLink = nil
        motion.stop()
        audio.stop()
        isRunning = false
    }

    /// Make "straight ahead" the direction the phone is pointing right now.
    /// Hold the phone out in front of your face and tap this.
    func recenter() {
        let p = motion.pointing
        forwardYaw = atan2(p.y, p.x)
        hasCenteredOnce = true
    }

    // MARK: Per-frame update

    private func startDisplayLink() {
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = lastTimestamp.map { max(1e-3, now - $0) } ?? (1.0 / 60.0)
        lastTimestamp = now

        // 1. Direction in the listener frame (x right, y up, z backward).
        let direction: SIMD3<Double>
        if autoOrbit || !motion.isAvailable {
            orbitAngle += 2 * .pi * orbitRate * dt
            // Circle at ear height with a gentle bob.
            let bob = 0.15 * sin(orbitAngle * 0.7)
            direction = simd_normalize(SIMD3(sin(orbitAngle), bob, -cos(orbitAngle)))
        } else {
            direction = worldToListener(motion.pointing)
        }

        // 2. Random-walk wobble, a few centimeters, so the insect feels alive.
        let step = 0.02
        wobble += SIMD3(
            Double.random(in: -step...step),
            Double.random(in: -step...step),
            Double.random(in: -step...step)
        )
        wobble *= 0.9  // mean reversion keeps it within ~10 cm
        let wobbleLimit = 0.08
        let wobbleLength = simd_length(wobble)
        if wobbleLength > wobbleLimit { wobble *= wobbleLimit / wobbleLength }

        let position = direction * radius + wobble
        let distance = simd_length(position)

        // 3. Doppler from radial velocity. Positive velocity is receding.
        if let last = lastDistance {
            let radialVelocity = (distance - last) / dt
            smoothedRadialVelocity += (radialVelocity - smoothedRadialVelocity) * 0.2
        }
        lastDistance = distance
        let speedOfSound = 343.0
        audio.synth.dopplerRatio = speedOfSound / (speedOfSound + smoothedRadialVelocity)

        // 4. Push to the engine and the readouts.
        audio.setSourcePosition(AVAudio3DPoint(x: Float(position.x), y: Float(position.y), z: Float(position.z)))

        let horizontal = sqrt(position.x * position.x + position.z * position.z)
        azimuthDegrees = atan2(position.x, -position.z) * 180 / .pi
        elevationDegrees = atan2(position.y, horizontal) * 180 / .pi
        distanceMeters = distance
    }

    /// Convert a world-frame unit vector (z up) into the listener frame.
    /// Listener forward is the world direction at yaw `forwardYaw`; listener up is world +z.
    private func worldToListener(_ v: SIMD3<Double>) -> SIMD3<Double> {
        let forward = SIMD3(cos(forwardYaw), sin(forwardYaw), 0.0)
        let up = SIMD3(0.0, 0.0, 1.0)
        let right = simd_cross(forward, up)
        return SIMD3(
            simd_dot(v, right),
            simd_dot(v, up),
            -simd_dot(v, forward)
        )
    }
}
