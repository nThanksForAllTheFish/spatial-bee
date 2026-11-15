import AVFoundation
import Combine
import simd

/// Which binaural renderer the environment node uses. All three are Apple's; they differ
/// in HRTF data set and processing, so elevation cues differ audibly between them.
enum SpatialRenderer: String, CaseIterable, Identifiable {
    /// High-quality HRTF, the classic AVAudioEngine binaural renderer.
    case hrtfHQ
    /// The older, lighter HRTF variant. Judged clearest for front-back on AirPods Pro.
    case hrtf
    /// Automatic algorithm with the output type forced to headphones. On iOS 13+ this
    /// engages the newer spatial renderer used by system spatial audio.
    case appleSpatial

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hrtfHQ: return "HRTF-HQ"
        case .hrtf: return "HRTF"
        case .appleSpatial: return "Apple spatial"
        }
    }

    var algorithm: AVAudio3DMixingRenderingAlgorithm {
        switch self {
        case .hrtfHQ: return .HRTFHQ
        case .hrtf: return .HRTF
        case .appleSpatial: return .auto
        }
    }
}

/// Owns the AVAudioEngine graph:
///
///     insect / remote / saber (mono source nodes)  ─┐
///     bolt / clash / stun   (mono player nodes)     ─┴─> AVAudioEnvironmentNode (HRTF) -> main mixer -> output
///
/// The environment node renders every mono input binaurally for a listener at the
/// origin. The listener faces -z with +y up and +x to the right. Head tracking turns the
/// listener; every source position is in the aligned frame.
@MainActor
final class SpatialAudioEngine: ObservableObject {

    @Published private(set) var isRunning = false
    @Published private(set) var statusText = "Stopped"
    @Published private(set) var outputRouteText = "—"
    @Published private(set) var outputIsHeadphones = false

    /// Explore mode insect.
    let synth: InsectSynth
    /// Training mode remote.
    let remoteSynth: RemoteSynth
    /// Training mode saber hilt hum, an InsectSynth with a low fundamental.
    let saberSynth: InsectSynth
    /// Training mode saber tip: fizz, upper harmonics, swing.
    let tipSynth: SaberTipSynth

    private let engine = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()
    private var insectSource: AVAudioSourceNode?
    private var remoteSource: AVAudioSourceNode?
    private var saberSource: AVAudioSourceNode?
    private var tipSource: AVAudioSourceNode?
    private let boltPlayer = AVAudioPlayerNode()
    private let clashPlayer = AVAudioPlayerNode()
    private let stunPlayer = AVAudioPlayerNode()
    private var boltBuffer: AVAudioPCMBuffer?
    private var clashBuffer: AVAudioPCMBuffer?
    private var stunBuffer: AVAudioPCMBuffer?
    private var graphBuilt = false
    private var routeObserver: NSObjectProtocol?

    private var spatialNodes: [AVAudioNode] {
        [insectSource, remoteSource, saberSource, tipSource].compactMap { $0 } + [boltPlayer, clashPlayer, stunPlayer]
    }

    init() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        let rate = session.sampleRate > 0 ? session.sampleRate : 48_000
        synth = InsectSynth(sampleRate: rate)
        remoteSynth = RemoteSynth(sampleRate: rate)
        saberSynth = InsectSynth(sampleRate: rate)
        tipSynth = SaberTipSynth(sampleRate: rate)
        saberSynth.setHarmonics(count: 12, rolloff: 1.3)
        var sp = saberSynth.params
        sp.f0 = 92
        sp.pitchWander = 0.006
        sp.noiseLevel = 0.03
        sp.noiseCutoffHz = 1500
        sp.cutoffHz = 3500
        sp.gain = 0
        saberSynth.params = sp
        observeRoute()
        updateRouteText()
    }

    // MARK: Control

    func start() {
        guard !isRunning else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setPreferredIOBufferDuration(0.005)
            try session.setActive(true)

            buildGraphIfNeeded()
            try engine.start()
            for player in [boltPlayer, clashPlayer, stunPlayer] { player.play() }
            isRunning = true
            statusText = describeRendering()
        } catch {
            statusText = "Audio start failed: \(error.localizedDescription)"
        }
    }

    func stop() {
        guard isRunning else { return }
        for player in [boltPlayer, clashPlayer, stunPlayer] { player.stop() }
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isRunning = false
        statusText = "Stopped"
    }

    // MARK: Positions (meters, aligned listener frame)

    func setInsectPosition(_ p: SIMD3<Double>) { insectSource?.position = point(p) }
    func setRemotePosition(_ p: SIMD3<Double>) { remoteSource?.position = point(p) }
    func setSaberPosition(_ p: SIMD3<Double>) { saberSource?.position = point(p) }
    func setSaberTipPosition(_ p: SIMD3<Double>) { tipSource?.position = point(p) }

    /// Turn the listener. Identity is forward (0, 0, -1), up (0, 1, 0).
    func setListenerOrientation(forward: SIMD3<Double>, up: SIMD3<Double>) {
        environment.listenerVectorOrientation = AVAudio3DVectorOrientation(
            forward: AVAudio3DVector(x: Float(forward.x), y: Float(forward.y), z: Float(forward.z)),
            up: AVAudio3DVector(x: Float(up.x), y: Float(up.y), z: Float(up.z))
        )
    }

    func resetListenerOrientation() {
        setListenerOrientation(forward: SIMD3(0, 0, -1), up: SIMD3(0, 1, 0))
    }

    // MARK: One-shots

    func playBolt(at p: SIMD3<Double>) { play(boltPlayer, boltBuffer, at: p) }
    func playClash(at p: SIMD3<Double>) { play(clashPlayer, clashBuffer, at: p) }
    func playStun(at p: SIMD3<Double>) { play(stunPlayer, stunBuffer, at: p) }

    private func play(_ player: AVAudioPlayerNode, _ buffer: AVAudioPCMBuffer?, at p: SIMD3<Double>) {
        guard isRunning, let buffer else { return }
        player.position = point(p)
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !player.isPlaying { player.play() }
    }

    // MARK: Renderer and tuning

    var renderer: SpatialRenderer = .hrtfHQ {
        didSet { applyRenderer() }
    }

    private func applyRenderer() {
        guard graphBuilt else { return }
        environment.outputType = .headphones
        for node in spatialNodes {
            (node as? AVAudioMixing)?.renderingAlgorithm = renderer.algorithm
        }
        if isRunning { statusText = describeRendering() }
    }

    var tuning = TuningConfig.defaults {
        didSet { applyTuning() }
    }

    private func applyTuning() {
        let distance = environment.distanceAttenuationParameters
        distance.distanceAttenuationModel = .inverse
        distance.referenceDistance = Float(tuning.distance.referenceDistance)
        distance.maximumDistance = Float(tuning.distance.maximumDistance)
        distance.rolloffFactor = Float(tuning.distance.rolloffFactor)
        environment.reverbParameters.level = Float(tuning.reverbLevelDb)
        for node in spatialNodes {
            (node as? AVAudioMixing)?.reverbBlend = Float(tuning.reverbBlend)
        }
        let t = tuning.training
        var rp = remoteSynth.params
        rp.gain = t.remoteGain
        rp.f0 = t.remoteF0
        rp.hissLevel = t.remoteHissLevel
        rp.hissLowHz = t.remoteHissLowHz
        rp.hissCutoffHz = t.remoteHissCutoffHz
        remoteSynth.params = rp
        remoteSynth.setHarmonics(count: t.remoteHarmonicCount, rolloff: t.remoteHarmonicRolloff)
        var tp = tipSynth.params
        tp.fizzLevel = t.saberFizzLevel
        tp.swingLevel = t.saberSwingLevel
        tipSynth.params = tp   // gain is set by the controller with the mode
    }

    // MARK: Graph

    private func buildGraphIfNeeded() {
        guard !graphBuilt else { return }

        let insect = synth.makeSourceNode()
        let remote = remoteSynth.makeSourceNode()
        let saber = saberSynth.makeSourceNode()
        let tip = tipSynth.makeSourceNode()
        insectSource = insect
        remoteSource = remote
        saberSource = saber
        tipSource = tip

        let hardwareRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let mono = AVAudioFormat(standardFormatWithSampleRate: hardwareRate, channels: 1)!
        let stereo = AVAudioFormat(standardFormatWithSampleRate: hardwareRate, channels: 2)!

        boltBuffer = OneShots.bolt(sampleRate: hardwareRate)
        clashBuffer = OneShots.clash(sampleRate: hardwareRate)
        stunBuffer = OneShots.stun(sampleRate: hardwareRate)

        engine.attach(environment)
        for node in [insect, remote, saber, tip] as [AVAudioNode] + [boltPlayer, clashPlayer, stunPlayer] {
            engine.attach(node)
            engine.connect(node, to: environment, format: mono)
        }
        engine.connect(environment, to: engine.mainMixerNode, format: stereo)

        environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        resetListenerOrientation()
        environment.reverbParameters.enable = true
        environment.reverbParameters.loadFactoryReverbPreset(.smallRoom)

        for node in spatialNodes {
            (node as? AVAudioMixing)?.sourceMode = .pointSource
            (node as? AVAudioMixing)?.position = AVAudio3DPoint(x: 0, y: 0, z: -1)
        }

        graphBuilt = true
        applyTuning()
        applyRenderer()
        engine.prepare()
    }

    private func point(_ p: SIMD3<Double>) -> AVAudio3DPoint {
        AVAudio3DPoint(x: Float(p.x), y: Float(p.y), z: Float(p.z))
    }

    private func describeRendering() -> String {
        guard let insectSource else { return "No source" }
        let algorithm: String
        switch insectSource.renderingAlgorithm {
        case .HRTFHQ: algorithm = "HRTF-HQ"
        case .HRTF: algorithm = "HRTF"
        case .sphericalHead: algorithm = "Spherical head"
        case .equalPowerPanning: algorithm = "Equal-power panning"
        case .stereoPassThrough: algorithm = "Stereo pass-through"
        case .soundField: algorithm = "Sound field"
        case .auto: algorithm = "Apple spatial (auto, headphones)"
        @unknown default: algorithm = "Unknown"
        }
        let rate = Int(engine.outputNode.outputFormat(forBus: 0).sampleRate)
        return "Running · \(algorithm) · \(rate) Hz"
    }

    // MARK: Output route

    private func observeRoute() {
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateRouteText() }
        }
    }

    private func updateRouteText() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        guard let primary = outputs.first else {
            outputRouteText = "No output"
            outputIsHeadphones = false
            return
        }
        let headphoneTypes: Set<AVAudioSession.Port> = [
            .headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .usbAudio
        ]
        outputIsHeadphones = headphoneTypes.contains(primary.portType)
        outputRouteText = primary.portName
    }
}
