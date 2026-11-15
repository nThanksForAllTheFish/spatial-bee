import AVFoundation
import Combine
import QuartzCore
import simd

enum AppMode: String, CaseIterable, Identifiable {
    case explore, training
    var id: String { rawValue }
    var label: String {
        switch self {
        case .explore: return "Explore"
        case .training: return "Training"
        }
    }
}

/// Hub for both modes.
///
/// Explore: the phone's pointing direction places the insect.
/// Training: the remote flies itself (TrainingGame); the phone is the saber, and the
/// block test compares the pointing direction with the remote's direction when it fires.
///
/// Every frame: pointing vector from the phone, expressed in the listener frame aligned
/// at Re-center, with azimuth held near the zenith; head rotation from the AirPods turns
/// the listener; positions go to the engine.
@MainActor
final class BeeController: ObservableObject {

    let audio = SpatialAudioEngine()
    let motion = MotionTracker()
    let head = HeadTracker()
    let game = TrainingGame()
    let haptics = Haptics()

    // MARK: Mode

    @Published var mode: AppMode = .explore {
        didSet {
            if mode == .explore { game.abort() }
            pushSynthParams()
            pushSaberParams()
        }
    }

    // MARK: User settings

    @Published var species: InsectSpecies = .bee {
        didSet { applySpecies() }
    }
    @Published var radius: Double = 0.6
    @Published var bandwidthHz: Double = 16_000 {
        didSet { audio.synth.params.cutoffHz = bandwidthHz }
    }
    @Published var pointingAxis: PointingAxis = .topEdge {
        didSet { motion.axis = pointingAxis }
    }
    @Published var renderer: SpatialRenderer = .hrtfHQ {
        didSet { audio.renderer = renderer }
    }
    @Published var autoOrbit = false
    @Published var orbitRate: Double = 0.15
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
    /// Training: a low hum spatialized at the saber so you can hear where it is.
    @Published var saberHum = true {
        didSet { pushSaberParams() }
    }
    /// Training: blank the screen.
    @Published var blastShield = false

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
    @Published var chargeSeconds: Double = 0.9 { didSet { if !applying { config.training.chargeSeconds = chargeSeconds; game.params = config.training } } }
    @Published var blockConeDeg: Double = 25 { didSet { if !applying { config.training.blockConeDeg = blockConeDeg; game.params = config.training } } }
    @Published var remoteSpeed: Double = 150 { didSet { if !applying { config.training.remoteSpeedDegPerSec = remoteSpeed; game.params = config.training } } }
    @Published var remoteHiss: Double = 0.14 { didSet { if !applying { config.training.remoteHissLevel = remoteHiss; audio.tuning = config } } }
    @Published var remoteRolloff: Double = 0.9 { didSet { if !applying { config.training.remoteHarmonicRolloff = remoteRolloff; audio.tuning = config } } }
    @Published var remoteGain: Double = 0.25 { didSet { if !applying { config.training.remoteGain = remoteGain; audio.tuning = config } } }
    @Published var saberHumGain: Double = 0.12 { didSet { if !applying { config.training.saberHumGain = saberHumGain; pushSaberParams() } } }
    @Published var saberTipGain: Double = 0.18 { didSet { if !applying { config.training.saberTipGain = saberTipGain; pushSaberParams() } } }
    @Published var saberFizz: Double = 0.35 { didSet { if !applying { config.training.saberFizzLevel = saberFizz; audio.tuning = config } } }
    @Published var saberTicks: Double = 0.6 { didSet { if !applying { config.training.saberTickLevel = saberTicks; audio.tuning = config } } }

    // MARK: Readouts

    @Published private(set) var isRunning = false
    /// Explore: the insect. Training: the remote.
    @Published private(set) var azimuthDegrees: Double = 0
    @Published private(set) var elevationDegrees: Double = 0
    @Published private(set) var distanceMeters: Double = 0
    /// Training: where the saber points.
    @Published private(set) var saberAzimuthDegrees: Double = 0
    @Published private(set) var saberElevationDegrees: Double = 0
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
    private var lastLoaded = TuningConfig.defaults
    private var cancellables = Set<AnyCancellable>()

    init() {
        // Nested observable objects do not propagate on their own.
        for child in [audio.objectWillChange.eraseToAnyPublisher(),
                      head.objectWillChange.eraseToAnyPublisher(),
                      motion.objectWillChange.eraseToAnyPublisher(),
                      game.objectWillChange.eraseToAnyPublisher()] {
            child.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        }
        game.onEvent = { [weak self] event in self?.handle(event) }
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

    func resetToLoadedConfig() {
        applyConfig(lastLoaded, status: configStatus)
    }

    private func applyConfig(_ c: TuningConfig, status: String) {
        applying = true
        defer { applying = false }
        lastLoaded = c
        config = c
        configStatus = status

        renderer = SpatialRenderer(rawValue: c.renderer) ?? .hrtfHQ
        audio.renderer = renderer
        audio.tuning = c
        game.params = c.training

        gain = c.gain
        reverbBlend = c.reverbBlend
        shelfGainDb = c.highShelf.gainDb
        shelfFrequencyHz = c.highShelf.frequencyHz
        wobbleLimitCm = c.wobble.limitCm
        chargeSeconds = c.training.chargeSeconds
        blockConeDeg = c.training.blockConeDeg
        remoteSpeed = c.training.remoteSpeedDegPerSec
        remoteHiss = c.training.remoteHissLevel
        remoteRolloff = c.training.remoteHarmonicRolloff
        remoteGain = c.training.remoteGain
        saberHumGain = c.training.saberHumGain
        saberTipGain = c.training.saberTipGain
        saberFizz = c.training.saberFizzLevel
        saberTicks = c.training.saberTickLevel

        applySpecies()
        pushSaberParams()
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
        p.gain = mode == .explore ? config.gain : 0
        p.cutoffHz = bandwidthHz
        p.shelfFrequencyHz = config.highShelf.frequencyHz
        p.shelfGainDb = config.highShelf.gainDb
        audio.synth.params = p
    }

    private func pushSaberParams() {
        let on = mode == .training && saberHum
        var p = audio.saberSynth.params
        p.gain = on ? config.training.saberHumGain : 0
        audio.saberSynth.params = p
        var t = audio.tipSynth.params
        t.gain = on ? config.training.saberTipGain : 0
        audio.tipSynth.params = t
    }

    // MARK: Control

    func start() {
        guard !isRunning else { return }
        audio.renderer = renderer
        motion.axis = pointingAxis
        audio.start()
        audio.tuning = config
        if headTracking { head.start() }
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
        game.abort()
        displayLink?.invalidate()
        displayLink = nil
        motion.stop()
        if headTracking { head.stop() }
        audio.stop()
        isRunning = false
    }

    /// Make "straight ahead" the direction the phone is pointing right now, and, with
    /// head tracking on, the direction the head is facing right now.
    func recenter() {
        let p = motion.pointing
        forwardYaw = atan2(p.y, p.x)
        hasCenteredOnce = true
        head.align()
    }

    func startRound() {
        guard isRunning, mode == .training else { return }
        game.params = config.training
        game.startRound()
    }

    func abortRound() {
        game.abort()
        audio.remoteSynth.charge = 0
        audio.remoteSynth.motion = 0
    }

    // MARK: Game events

    private func handle(_ event: TrainingGame.Event) {
        switch event {
        case .dart, .chargeStart, .roundOver:
            break
        case .fire(let blocked):
            let remotePosition = game.remoteDirection * config.training.remoteRadius
            audio.playBolt(at: remotePosition)
            // Contact happens at the blade, so the clash plays at the tip.
            let tipPosition = lastSaberDirection * (config.training.saberRadius + config.training.saberLength)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
                guard let self else { return }
                if blocked {
                    self.audio.playClash(at: tipPosition)
                    self.haptics.block()
                } else {
                    self.audio.playStun(at: SIMD3(0, -0.1, -0.15))
                    self.haptics.hit()
                }
            }
        }
    }

    private var lastSaberDirection = SIMD3<Double>(0, 0, -1)
    private var swingLevel = 0.0

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

        // 1. Pointing direction in the aligned listener frame.
        let rawDirection: SIMD3<Double>
        if mode == .explore && (autoOrbit || !motion.isAvailable) {
            orbitAngle += 2 * .pi * orbitRate * dt
            let bob = 0.15 * sin(orbitAngle * 0.7)
            rawDirection = simd_normalize(SIMD3(sin(orbitAngle), bob, -cos(orbitAngle)))
        } else {
            rawDirection = worldToListener(motion.pointing)
        }

        // 1b. Pole handling: hold azimuth near the zenith.
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

        // 2. Head orientation.
        if headTracking, head.hasSample {
            let rel = head.relativeRotation
            let forward = simd_normalize(rel * SIMD3(0, 0, -1))
            let up = simd_normalize(rel * SIMD3(0, 1, 0))
            audio.setListenerOrientation(forward: forward, up: up)
            headYawDegrees = atan2(forward.x, -forward.z) * 180 / .pi
            headPitchDegrees = asin(max(-1, min(1, forward.y))) * 180 / .pi
        }

        switch mode {
        case .explore:
            tickExplore(direction: direction, cosEl: cosEl, dt: dt)
        case .training:
            tickTraining(direction: direction, dt: dt)
        }
    }

    private func tickExplore(direction: SIMD3<Double>, cosEl: Double, dt: Double) {
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

        if let last = lastDistance {
            let radialVelocity = (distance - last) / dt
            smoothedRadialVelocity += (radialVelocity - smoothedRadialVelocity) * 0.2
        }
        lastDistance = distance
        let speedOfSound = 343.0
        audio.synth.dopplerRatio = speedOfSound / (speedOfSound + smoothedRadialVelocity)

        audio.setInsectPosition(position)
        publish(target: position, saber: nil)
    }

    private func tickTraining(direction: SIMD3<Double>, dt: Double) {
        // Blade angular speed drives the swing: noise burst at the tip and a pitch lift
        // on both ends. Normalized to the configured full-swing speed, smoothed.
        let stepDeg = acos(max(-1, min(1, simd_dot(lastSaberDirection, direction)))) * 180 / .pi
        let speed = stepDeg / max(dt, 1e-3)
        let swingTarget = min(1, speed / max(config.training.saberSwingFullDegPerSec, 1))
        swingLevel += (swingTarget - swingLevel) * min(1, dt * 10)
        lastSaberDirection = direction

        game.update(dt: dt, saberDirection: direction)

        let t = config.training
        let remotePosition = game.remoteDirection * t.remoteRadius
        audio.setRemotePosition(remotePosition)
        audio.setSaberPosition(direction * t.saberRadius)
        audio.setSaberTipPosition(direction * (t.saberRadius + t.saberLength))
        audio.tipSynth.swing = swingLevel
        audio.saberSynth.dopplerRatio = 1 + 0.12 * swingLevel
        audio.remoteSynth.motion = game.motionLevel
        audio.remoteSynth.charge = game.chargeLevel

        publish(target: remotePosition, saber: direction)
    }

    private func publish(target: SIMD3<Double>, saber: SIMD3<Double>?) {
        let horizontal = sqrt(target.x * target.x + target.z * target.z)
        azimuthDegrees = atan2(target.x, -target.z) * 180 / .pi
        elevationDegrees = atan2(target.y, horizontal) * 180 / .pi
        distanceMeters = simd_length(target)
        if let saber {
            let h = sqrt(saber.x * saber.x + saber.z * saber.z)
            saberAzimuthDegrees = atan2(saber.x, -saber.z) * 180 / .pi
            saberElevationDegrees = atan2(saber.y, h) * 180 / .pi
        }
    }

    /// Convert a world-frame unit vector (z up) into the aligned listener frame.
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
