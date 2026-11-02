import Foundation

/// Where the (real or virtual) camera looks, plus a pinhole projection to screen points.
///
/// Vectors are in the world frame (north, west, up). `right = forward × up`.
public struct CameraPose: Sendable, Hashable {
    public var forward: Vec3
    public var up: Vec3
    public var right: Vec3
    /// Focal length in screen points.
    public var focalLength: Double
    public var centerX: Double
    public var centerY: Double

    public init(forward: Vec3, up: Vec3, focalLength: Double, centerX: Double, centerY: Double) {
        let f = forward.normalized
        let r = f.cross(up).normalized
        self.forward = f
        self.right = r
        self.up = r.cross(f).normalized
        self.focalLength = focalLength
        self.centerX = centerX
        self.centerY = centerY
    }

    /// Virtual camera (touch mode): yaw = azimuth of the view centre, pitch = its altitude, roll around the view axis.
    public init(yaw: Double, pitch: Double, roll: Double = 0, focalLength: Double, centerX: Double, centerY: Double) {
        let f = Vec3.direction(azimuth: yaw, altitude: pitch)
        // Pick an "up" that works even when looking straight up or down.
        let reference = abs(pitch) > 89 ? Vec3.direction(azimuth: yaw, altitude: 0) * (pitch > 0 ? -1 : 1) : Vec3.up
        var pose = CameraPose(forward: f, up: reference, focalLength: focalLength, centerX: centerX, centerY: centerY)
        if roll != 0 {  // positive roll = clockwise, i.e. the right side of the screen goes down
            pose.up = pose.up.rotated(around: pose.forward, by: roll)
            pose.right = pose.right.rotated(around: pose.forward, by: roll)
        }
        self = pose
    }

    /// Device camera (sensor mode) from a Core Motion attitude quaternion in the `xTrueNorthZVertical` frame.
    /// The back camera looks along the device's -z axis. `screenUp` is the direction of the screen's top edge in
    /// device coordinates: +y in portrait, +x in landscape-right (home side right), -x in landscape-left.
    public init(deviceAttitude q: Quaternion, screenUp: Vec3 = Vec3(0, 1, 0), focalLength: Double,
                centerX: Double, centerY: Double) {
        self.init(forward: q.act(Vec3(0, 0, -1)), up: q.act(screenUp),
                  focalLength: focalLength, centerX: centerX, centerY: centerY)
    }

    public static func focalLength(fieldOfView degreesAcross: Double, pixelsAcross: Double) -> Double {
        (pixelsAcross / 2) / tan(radians(degreesAcross) / 2)
    }

    /// Screen point of a world direction, or nil if it is behind the camera.
    public func project(_ direction: Vec3) -> (x: Double, y: Double)? {
        let z = direction.dot(forward)
        guard z > 1e-3 else { return nil }
        return (centerX + direction.dot(right) / z * focalLength,
                centerY - direction.dot(up) / z * focalLength)
    }

    public func project(azimuth: Double, altitude: Double) -> (x: Double, y: Double)? {
        project(Vec3.direction(azimuth: azimuth, altitude: altitude))
    }

    /// World direction under a screen point (inverse of `project`).
    public func direction(x: Double, y: Double) -> Vec3 {
        (forward * focalLength + right * (x - centerX) - up * (y - centerY)).normalized
    }

    public var azimuth: Double { forward.azimuthAltitude.azimuth }
    public var pitch: Double { forward.azimuthAltitude.altitude }

    /// Roll in degrees, positive = clockwise (right side of the screen below the horizon).
    public var roll: Double {
        degrees(atan2(-right.z, sqrt(right.x * right.x + right.y * right.y)))
    }

    /// Rotate around the world's vertical axis: used for compass calibration (positive = clockwise).
    public func rotatedYaw(by degreesClockwise: Double) -> CameraPose {
        var p = self
        p.forward = forward.rotated(around: .up, by: -degreesClockwise)
        p.up = up.rotated(around: .up, by: -degreesClockwise)
        p.right = right.rotated(around: .up, by: -degreesClockwise)
        return p
    }

    /// Tilt up (positive) or down around the camera's horizontal axis.
    public func pitched(by degreesUp: Double) -> CameraPose {
        var p = self
        p.forward = forward.rotated(around: right, by: degreesUp)
        p.up = up.rotated(around: right, by: degreesUp)
        return p
    }

    /// Half of the screen diagonal as an angle: anything further off-axis can't be visible.
    public func maxVisibleAngle(width: Double, height: Double) -> Double {
        degrees(atan(sqrt(width * width + height * height) / 2 / focalLength))
    }
}
