import CoreMotion
import simd

/// Head orientation from AirPods (Pro, Max, 3rd gen and later) through
/// CMHeadphoneMotionManager.
///
/// The headphone reference frame has an arbitrary yaw that drifts slowly, and the
/// earbuds have no magnetometer, so absolute orientation is not useful. Instead `align()`
/// snapshots the current attitude and `relativeRotation` reports how the head has turned
/// since then, expressed in the aligned head frame. The controller calls `align()` from
/// Re-center, at the same moment it captures the phone's forward direction, so both
/// trackers share one frame.
///
/// Headphone device axes are taken as x right, y up, z backward (out the back of the
/// head), which matches the audio listener frame. The matrix convention follows what the
/// phone test established for CMAttitude: the raw matrix maps reference into device, so
/// relative = M_align * M_nowᵀ. Verified on AirPods Pro 2026-11-14.
@MainActor
final class HeadTracker: NSObject, ObservableObject, CMHeadphoneMotionManagerDelegate {

    @Published private(set) var isAvailable = false
    @Published private(set) var isRunning = false
    @Published private(set) var isConnected = false
    @Published private(set) var hasSample = false
    @Published private(set) var status = "Off"
    @Published private(set) var sampleRateHz: Double = 0

    private let manager = CMHeadphoneMotionManager()
    private var current = matrix_identity_double3x3     // reference -> device, as CoreMotion hands it over
    private var aligned = matrix_identity_double3x3
    private var sampleCount = 0
    private var sampleWindowStart: TimeInterval = 0

    override init() {
        super.init()
        isAvailable = manager.isDeviceMotionAvailable
        manager.delegate = self
        status = isAvailable ? "Off" : "Not available on this device"
    }

    func start() {
        guard isAvailable, !isRunning else { return }
        switch CMHeadphoneMotionManager.authorizationStatus() {
        case .denied, .restricted:
            status = "Motion access denied in Settings"
            return
        default:
            break
        }
        hasSample = false
        status = "Waiting for AirPods…"
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            guard let self else { return }
            if let error {
                self.status = "Error: \(error.localizedDescription)"
                return
            }
            guard let motion else { return }
            let m = motion.attitude.rotationMatrix
            self.current = simd_double3x3(rows: [
                SIMD3(m.m11, m.m12, m.m13),
                SIMD3(m.m21, m.m22, m.m23),
                SIMD3(m.m31, m.m32, m.m33),
            ])
            if !self.hasSample {
                self.hasSample = true
                self.aligned = self.current
                self.status = "Tracking"
                self.sampleWindowStart = motion.timestamp
                self.sampleCount = 0
            }
            self.sampleCount += 1
            let elapsed = motion.timestamp - self.sampleWindowStart
            if elapsed >= 1 {
                self.sampleRateHz = Double(self.sampleCount) / elapsed
                self.sampleCount = 0
                self.sampleWindowStart = motion.timestamp
            }
        }
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        manager.stopDeviceMotionUpdates()
        isRunning = false
        hasSample = false
        sampleRateHz = 0
        status = isAvailable ? "Off" : status
    }

    /// Make the current head pose the reference: "this way is straight ahead".
    func align() {
        guard hasSample else { return }
        aligned = current
    }

    /// Rotation of the head since `align()`, in the aligned head frame.
    /// Apply to (0, 0, -1) for the current forward vector and (0, 1, 0) for up.
    var relativeRotation: simd_double3x3 {
        aligned * current.transpose
    }

    // MARK: CMHeadphoneMotionManagerDelegate

    nonisolated func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        Task { @MainActor in
            self.isConnected = true
            if self.isRunning { self.status = "Connected, waiting for data…" }
        }
    }

    nonisolated func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        Task { @MainActor in
            self.isConnected = false
            self.hasSample = false
            self.sampleRateHz = 0
            if self.isRunning { self.status = "AirPods disconnected" }
        }
    }
}
