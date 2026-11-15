import AVFoundation
import Combine
import simd

/// Which binaural renderer the environment node uses. All three are Apple's; they differ
/// in HRTF data set and processing, so elevation cues differ audibly between them.
enum SpatialRenderer: String, CaseIterable, Identifiable {
    /// High-quality HRTF, the classic AVAudioEngine binaural renderer.
    case hrtfHQ
    /// The older, lighter HRTF variant.
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
///     InsectSynth (mono source) -> AVAudioEnvironmentNode (HRTF) -> main mixer -> output
///
/// The environment node renders the mono source binaurally for the listener at the
/// origin. The listener faces -z with +y up and +x to the right, the same frame
/// OpenAL and SceneKit use. Head tracking is not used in this prototype, so the
/// listener orientation stays at identity and only the source moves.
@MainActor
final class SpatialAudioEngine: ObservableObject {

    @Published private(set) var isRunning = false
    @Published private(set) var statusText = "Stopped"
    @Published private(set) var outputRouteText = "—"
    @Published private(set) var outputIsHeadphones = false

    let synth: InsectSynth

    private let engine = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()
    private var source: AVAudioSourceNode?
    private var routeObserver: NSObjectProtocol?

    init() {
        // Build the synth at the hardware rate so no resampling sits in the path.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        synth = InsectSynth(sampleRate: session.sampleRate > 0 ? session.sampleRate : 48_000)
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
            isRunning = true
            statusText = describeRendering()
        } catch {
            statusText = "Audio start failed: \(error.localizedDescription)"
        }
    }

    func stop() {
        guard isRunning else { return }
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isRunning = false
        statusText = "Stopped"
    }

    /// Place the insect. Coordinates are meters in the listener frame described above.
    func setSourcePosition(_ p: AVAudio3DPoint) {
        source?.position = p
    }

    /// Turn the listener. Vectors are in the same frame as source positions; identity
    /// is forward (0, 0, -1), up (0, 1, 0). Head tracking drives this.
    func setListenerOrientation(forward: SIMD3<Double>, up: SIMD3<Double>) {
        environment.listenerVectorOrientation = AVAudio3DVectorOrientation(
            forward: AVAudio3DVector(x: Float(forward.x), y: Float(forward.y), z: Float(forward.z)),
            up: AVAudio3DVector(x: Float(up.x), y: Float(up.y), z: Float(up.z))
        )
    }

    func resetListenerOrientation() {
        setListenerOrientation(forward: SIMD3(0, 0, -1), up: SIMD3(0, 1, 0))
    }

    var renderer: SpatialRenderer = .hrtfHQ {
        didSet { applyRenderer() }
    }

    /// Spatial parameters from the tuning config: distance model and reverb.
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
        source?.reverbBlend = Float(tuning.reverbBlend)
    }

    private func applyRenderer() {
        guard let source else { return }
        // Output type is consulted only by the Auto algorithm. Headphones is the truth
        // here; Bluetooth routes would otherwise be guessed at.
        environment.outputType = .headphones
        source.renderingAlgorithm = renderer.algorithm
        if isRunning { statusText = describeRendering() }
    }

    // MARK: Graph

    private func buildGraphIfNeeded() {
        guard source == nil else { return }

        let node = synth.makeSourceNode()
        source = node

        engine.attach(node)
        engine.attach(environment)

        let hardwareRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let mono = AVAudioFormat(standardFormatWithSampleRate: hardwareRate, channels: 1)!
        let stereo = AVAudioFormat(standardFormatWithSampleRate: hardwareRate, channels: 2)!

        // Source must be mono for the environment node to spatialize it.
        engine.connect(node, to: environment, format: mono)
        engine.connect(environment, to: engine.mainMixerNode, format: stereo)

        // Listener: origin, facing -z, head up +y.
        environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        environment.listenerVectorOrientation = AVAudio3DVectorOrientation(
            forward: AVAudio3DVector(x: 0, y: 0, z: -1),
            up: AVAudio3DVector(x: 0, y: 1, z: 0)
        )

        // A touch of small-room reverb helps the source sit outside the head.
        environment.reverbParameters.enable = true
        environment.reverbParameters.loadFactoryReverbPreset(.smallRoom)

        node.sourceMode = .pointSource
        node.position = AVAudio3DPoint(x: 0, y: 0, z: -1)
        applyTuning()
        applyRenderer()

        engine.prepare()
    }

    private func describeRendering() -> String {
        guard let source else { return "No source" }
        let algorithm: String
        switch source.renderingAlgorithm {
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
