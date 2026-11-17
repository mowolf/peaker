import CoreMotion
import Foundation
import Observation
import PeakerKit

/// Device attitude relative to true north (Core Motion `xTrueNorthZVertical`), smoothed.
///
/// Updates arrive at 60 Hz on the main queue. Observation notifies on every assignment, even of an equal
/// value, so only values that actually changed are assigned: otherwise every view reading
/// `isCompassUncertain` would redraw 60 times a second.
@MainActor
@Observable
final class MotionService {
    @ObservationIgnored private let manager = CMMotionManager()
    private(set) var attitude: Quaternion?
    /// Compass calibration quality; low values mean the heading may be off by 10°+.
    private(set) var isCompassUncertain = false
    private(set) var isRunning = false

    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        let frames = CMMotionManager.availableAttitudeReferenceFrames()
        let frame: CMAttitudeReferenceFrame = frames.contains(.xTrueNorthZVertical) ? .xTrueNorthZVertical
            : .xMagneticNorthZVertical
        manager.deviceMotionUpdateInterval = 1.0 / 60.0
        manager.showsDeviceMovementDisplay = true
        isRunning = true
        manager.startDeviceMotionUpdates(using: frame, to: .main) { [weak self] motion, _ in
            guard let motion else { return }
            // Plain values out of the (non-Sendable) CMDeviceMotion; the handler runs on the main queue.
            let q = motion.attitude.quaternion
            let attitude = Quaternion(x: q.x, y: q.y, z: q.z, w: q.w)
            let accuracy = motion.magneticField.accuracy
            let uncertain = accuracy == .uncalibrated || accuracy == .low
            MainActor.assumeIsolated { self?.update(attitude, compassUncertain: uncertain) }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        if isRunning { isRunning = false }
    }

    private func update(_ q: Quaternion, compassUncertain: Bool) {
        attitude = smooth(q)
        if isCompassUncertain != compassUncertain { isCompassUncertain = compassUncertain }
    }

    /// Exponential smoothing on the quaternion (normalised lerp) to calm sensor jitter.
    private func smooth(_ q: Quaternion) -> Quaternion {
        guard let p = attitude else { return q }
        let alpha = 0.3
        // q and -q are the same rotation: interpolate towards the closer one.
        let sign: Double = (p.x * q.x + p.y * q.y + p.z * q.z + p.w * q.w) < 0 ? -1 : 1
        var r = Quaternion(x: p.x + alpha * (sign * q.x - p.x), y: p.y + alpha * (sign * q.y - p.y),
                           z: p.z + alpha * (sign * q.z - p.z), w: p.w + alpha * (sign * q.w - p.w))
        let n = (r.x * r.x + r.y * r.y + r.z * r.z + r.w * r.w).squareRoot()
        r = Quaternion(x: r.x / n, y: r.y / n, z: r.z / n, w: r.w / n)
        return r
    }
}
