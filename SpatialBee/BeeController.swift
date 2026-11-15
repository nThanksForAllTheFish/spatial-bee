import AVFoundation
import Combine
import QuartzCore
import simd

/// Glue between the phone's pointing direction and the spatial audio source, plus the
/// owner of the tuning config.
///
/// Every frame it takes the world-frame pointing vector (or a synthetic orbit when
/// Auto-orbit is on), expresses it in the listener's frame, holds azimuth steady near
/// the zenith, pushes it out to a chosen radius, adds a small random-walk wobble so the
/// insect never sits perfectly still, and hands the result to the audio engine. Radial
/// velocity drives a Doppler ratio on the synthesizer.
@MainActor
final class BeeController: ObservableObject {

    let audio = SpatialAudioEngine()
    let motion = MotionTracker()
    let head = HeadTracker()

    // MARK: User settings

    @Published var species: InsectSpecies = .bee {
        didSet { applySpecies() }
    }
    /// Distance from the head center, meters.
    @Published var radius: Double = 0.6
    /// Low-pass on the insect before spatialization, Hz.
    @Published var bandwidthHz: Double = 16_000 {
        didSet { audio.synth.params.cutoffHz = bandwidthHz }
    }
    @Published var pointingAxis: PointingAxis = .topEdge {
        didSet { motion.axis = pointingAxis }
    }
    @Published var renderer: SpatialRenderer = .hrtfHQ {
        didSet { audio.renderer = renderer }
    }
    /// When on, the insect circles the head on its own. Useful in the simulator,
    /// which has no motion sensors, and as a sanity check on a device.
    @Published var autoOrbit = false
    /// Revolutions per second for auto-orbit. Positive is counterclockwise seen from above.
    @Published var orbitRate: Double = 0.15
    /// Drive the listener orientation from AirPods head motion so the insect stays put
    /// in the room when the head turns.
    @Published var headTracking = false {
        didSet {
            if headTracking {
                head.start()
            } else {
                head.stop()
                audio.resetListenerOrientation()
                headYawDegrees = 0
                headPitchDegrees = 0
            }
        }
    }
    /// First-run insurance: flips the sense of head rotation if the frame convention
    /// turns out to be the other way round.
    @Published var invertHead = false

    // MARK: Tuning (mirrors of the config, editable live)

    @Published var config = TuningConfig.defaults
    @Published private(set) var configStatus = "Built-in defaults"
    @Published private(set) var configLoading = false

    @Published var gain: Double = 0.22 { didSet { if !applying { config.gain = gain; pushSynthParams() } } }
    @Published var reverbBlend: Double = 0.12 { didSet { if !applying { config.reverbBlend = reverbBlend; audio.tuning = config } } }
    @Published var shelfGainDb: Double = 0 { didSet { if !applying { config.highShelf.gainDb = shelfGainDb; pushSynthParams() } } }
    @Published var shelfFrequencyHz: Double = 5000 { didSet { if !applying { config.highShelf.frequencyHz = shelfFrequencyHz; pushSynthParams() } } }
    @Published var harmonicRolloff: Double = 0.8 { didSet { if !applying { updateSpecies { $0.harmonicRolloff = harmonicRolloff } } } }
    @Published var noiseLevel: Double = 0.18 { didSet { if !applying { updateSpecies { $0.noiseLevel = noiseLevel } } } }
    @Published var wobbleLimitCm: Double = 8 { didSet { if !applying { config.wobble.limitCm = wobbleLimitCm } } }

    // MARK: Readouts

    @Published private(set) var isRunning = false
    @Published private(set) var azimuthDegrees: Double = 0
    @Published private(set) var elevationDegrees: Double = 0
    @Published private(set) var distanceMeters: Double = 0
    /// Head yaw since Re-center, positive turning right.
    @Published private(set) var headYawDegrees: Double = 0
    @Published private(set) var headPitchDegrees: Double = 0

    // MARK: Internals

    private var displayLink: CADisplayLink?
    private var forwardYaw: Double = 0
    private var hasCenteredOnce = false
    private var orbitAngle: Double = 0
    private var wobble = SIMD3<Double>(0, 0, 0)
    private var azimuthDir = SIMD2<Double>(0, -1)
    private var lastDistance: Double?
    private var lastTimestamp: CFTimeInterval?
    private var smoothedRadialVelocity: Double = 0
    private var applying = false

    init() {
        applyConfig(TuningConfig.defaults, status: "Built-in defaults")
        Task { await reloadConfig() }
    }

    // MARK: Config

    func reloadConfig() async {
        configLoading = true
        defer { configLoading = false }
        do {
            let fetched = try await TuningConfigLoader.fetch()
            let stamp = Date().formatted(date: .omitted, time: .standard)
            applyConfig(fetched, status: "Loaded v\(fetched.version) at \(stamp)")
        } catch {
            configStatus = "Fetch failed: \(error.localizedDescription). Keeping current values."
        }
    }

    /// Discard live edits and go back to the last loaded config.
    func resetToLoadedConfig() {
        applyConfig(lastLoaded, status: configStatus)
    }

    private var lastLoaded = TuningConfig.defaults

    private func applyConfig(_ c: TuningConfig, status: String) {
        applying = true
        defer { applying = false }
        lastLoaded = c
        config = c
        configStatus = status

        renderer = SpatialRenderer(rawValue: c.renderer) ?? .hrtfHQ
        audio.renderer = renderer
        audio.tuning = c

        gain = c.gain
        reverbBlend = c.reverbBlend
        shelfGainDb = c.highShelf.gainDb
        shelfFrequencyHz = c.highShelf.frequencyHz
        wobbleLimitCm = c.wobble.limitCm

        applySpecies()
    }

    private func applySpecies() {
        let s = config.species(species)
        let wasApplying = applying
        applying = true
        harmonicRolloff = s.harmonicRolloff
        noiseLevel = s.noiseLevel
        applying = wasApplying
        audio.synth.setHarmonics(count: s.harmonicCount, rolloff: s.harmonicRolloff)
        pushSynthParams()
    }

    private func updateSpecies(_ edit: (inout TuningConfig.Species) -> Void) {
        var s = config.species(species)
        edit(&s)
        config.species[species.rawValue] = s
        audio.synth.setHarmonics(count: s.harmonicCount, rolloff: s.harmonicRolloff)
        pushSynthParams()
    }

    private func pushSynthParams() {
        let s = config.species(species)
        var p = audio.synth.params
        p.f0 = s.f0
        p.pitchWander = s.pitchWander
        p.noiseLevel = s.noiseLevel
        p.noiseCutoffHz = s.noiseCutoffHz
        p.gain = config.gain
        p.cutoffHz = bandwidthHz
        p.shelfFrequencyHz = config.highShelf.frequencyHz
        p.shelfGainDb = config.highShelf.gainDb
        audio.synth.params = p
    }

    // MARK: Control

    func start() {
        guard !isRunning else { return }
        audio.renderer = renderer
        motion.axis = pointingAxis
        audio.start()
        if headTracking { head.start() }
        audio.tuning = config   // nodes exist now; re-apply reverb blend on the source
        motion.start()
        if !hasCenteredOnce {
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
        if headTracking { head.stop() }
        audio.stop()
        isRunning = false
    }

    /// Make "straight ahead" the direction the phone is pointing right now, and, with
    /// head tracking on, the direction the head is facing right now. Do both at once:
    /// look at the phone while pointing it forward.
    func recenter() {
        let p = motion.pointing
        forwardYaw = atan2(p.y, p.x)
        hasCenteredOnce = true
        head.align()
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
        let rawDirection: SIMD3<Double>
        if autoOrbit || !motion.isAvailable {
            orbitAngle += 2 * .pi * orbitRate * dt
            let bob = 0.15 * sin(orbitAngle * 0.7)
            rawDirection = simd_normalize(SIMD3(sin(orbitAngle), bob, -cos(orbitAngle)))
        } else {
            rawDirection = worldToListener(motion.pointing)
        }

        // 1b. Pole handling: smooth the horizontal direction with a time constant that
        // grows as cos^2(el) shrinks, so azimuth holds near the zenith instead of spinning.
        let sinEl = max(-1, min(1, rawDirection.y))
        let cosEl = sqrt(max(0, 1 - sinEl * sinEl))
        let rawHorizontal = SIMD2(rawDirection.x, rawDirection.z)
        let rawHorizontalLength = simd_length(rawHorizontal)
        if rawHorizontalLength > 1e-3 {
            let target = rawHorizontal / rawHorizontalLength
            let tau = 0.05 / max(0.02, cosEl * cosEl)
            let k = 1 - exp(-dt / tau)
            azimuthDir += (target - azimuthDir) * k
            let n = simd_length(azimuthDir)
            if n > 1e-6 { azimuthDir /= n }
        }
        let direction = SIMD3(azimuthDir.x * cosEl, sinEl, azimuthDir.y * cosEl)

        // 2. Random-walk wobble; horizontal part scaled by cos(el) so it cannot swing
        // azimuth at the pole.
        let step = config.wobble.stepCm / 100
        wobble += SIMD3(
            Double.random(in: -step...step),
            Double.random(in: -step...step),
            Double.random(in: -step...step)
        )
        wobble *= 0.9
        let wobbleLimit = config.wobble.limitCm / 100
        let wobbleLength = simd_length(wobble)
        if wobbleLength > wobbleLimit, wobbleLength > 0 { wobble *= wobbleLimit / wobbleLength }
        let shapedWobble = SIMD3(wobble.x * cosEl, wobble.y, wobble.z * cosEl)

        let position = direction * radius + shapedWobble
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

        // 5. Listener orientation from the head, relative to the Re-center pose. The source
        // stays in the aligned frame, so turning the head leaves the insect where it is.
        if headTracking, head.hasSample {
            var rel = head.relativeRotation
            if invertHead { rel = rel.transpose }
            let forward = simd_normalize(rel * SIMD3(0, 0, -1))
            let up = simd_normalize(rel * SIMD3(0, 1, 0))
            audio.setListenerOrientation(forward: forward, up: up)
            headYawDegrees = atan2(forward.x, -forward.z) * 180 / .pi
            headPitchDegrees = asin(max(-1, min(1, forward.y))) * 180 / .pi
        }

        let horizontal = sqrt(position.x * position.x + position.z * position.z)
        azimuthDegrees = atan2(position.x, -position.z) * 180 / .pi
        elevationDegrees = atan2(position.y, horizontal) * 180 / .pi
        distanceMeters = distance
    }

    /// Convert a world-frame unit vector (z up) into the listener frame.
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
