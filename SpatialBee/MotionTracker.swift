import CoreMotion
import simd

/// Which axis of the phone counts as "where I am pointing".
enum PointingAxis: String, CaseIterable, Identifiable {
    /// The top edge of the phone, like a wand or TV remote. Device +y.
    case topEdge
    /// Out of the back of the phone, like aiming a camera. Device -z.
    case backCamera

    var id: String { rawValue }

    var label: String {
        switch self {
        case .topEdge: return "Top edge (wand)"
        case .backCamera: return "Back (camera)"
        }
    }

    var deviceVector: SIMD3<Double> {
        switch self {
        case .topEdge: return SIMD3(0, 1, 0)
        case .backCamera: return SIMD3(0, 0, -1)
        }
    }
}

/// Reads the phone's attitude from CoreMotion and publishes a unit vector, in the
/// world frame, along the chosen pointing axis.
///
/// World frame: CoreMotion's xArbitraryZVertical. z is up, x is wherever the phone's
/// yaw happened to be at the first sample, y completes a right-handed set. No
/// magnetometer, so no compass glitches; the controller recenters on demand instead.
@MainActor
final class MotionTracker: ObservableObject {

    @Published private(set) var isAvailable = false
    @Published private(set) var isRunning = false
    /// Latest pointing direction, unit length, world frame.
    @Published private(set) var pointing = SIMD3<Double>(1, 0, 0)

    var axis: PointingAxis = .topEdge

    private let manager = CMMotionManager()
    private let queue = OperationQueue()

    init() {
        isAvailable = manager.isDeviceMotionAvailable
        queue.name = "SpatialBee.motion"
        queue.maxConcurrentOperationCount = 1
    }

    func start() {
        guard isAvailable, !isRunning else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 100.0
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let axis = self.axis
            let world = Self.rotateToWorld(axis.deviceVector, attitude: motion.attitude)
            Task { @MainActor in
                self.pointing = world
            }
        }
        isRunning = true
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        isRunning = false
    }

    /// Rotate a device-frame vector into the world frame using the attitude matrix.
    ///
    /// CMAttitude's rotation matrix maps device coordinates to reference-frame
    /// coordinates (the same convention SceneKit uses when it sets a camera transform
    /// straight from the attitude). If the insect ever moves opposite to the phone on
    /// a real device, this is the one place to transpose.
    nonisolated static func rotateToWorld(_ v: SIMD3<Double>, attitude: CMAttitude) -> SIMD3<Double> {
        let m = attitude.rotationMatrix
        let world = SIMD3<Double>(
            m.m11 * v.x + m.m12 * v.y + m.m13 * v.z,
            m.m21 * v.x + m.m22 * v.y + m.m23 * v.z,
            m.m31 * v.x + m.m32 * v.y + m.m33 * v.z
        )
        let length = simd_length(world)
        return length > 0 ? world / length : SIMD3(1, 0, 0)
    }
}
