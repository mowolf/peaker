import Foundation

/// 3D vector in the world frame used throughout Peaker: x = north, y = west, z = up.
/// This is Core Motion's `xTrueNorthZVertical` reference frame, so device attitudes can be used directly.
public struct Vec3: Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x; self.y = y; self.z = z
    }

    public static let north = Vec3(1, 0, 0)
    public static let west = Vec3(0, 1, 0)
    public static let up = Vec3(0, 0, 1)

    /// Unit vector towards azimuth (degrees clockwise from north) and altitude (degrees above horizontal).
    public static func direction(azimuth: Double, altitude: Double) -> Vec3 {
        let az = radians(azimuth), alt = radians(altitude)
        return Vec3(cos(alt) * cos(az), -cos(alt) * sin(az), sin(alt))
    }

    /// Azimuth (degrees, 0..<360) and altitude (degrees) of this direction.
    public var azimuthAltitude: (azimuth: Double, altitude: Double) {
        let n = normalized
        return (Geo.normalizedDegrees(degrees(atan2(-n.y, n.x))), degrees(asin(max(-1, min(1, n.z)))))
    }

    public static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x + b.x, a.y + b.y, a.z + b.z) }
    public static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x - b.x, a.y - b.y, a.z - b.z) }
    public static func * (a: Vec3, s: Double) -> Vec3 { Vec3(a.x * s, a.y * s, a.z * s) }
    public static prefix func - (a: Vec3) -> Vec3 { Vec3(-a.x, -a.y, -a.z) }

    public func dot(_ b: Vec3) -> Double { x * b.x + y * b.y + z * b.z }
    public func cross(_ b: Vec3) -> Vec3 { Vec3(y * b.z - z * b.y, z * b.x - x * b.z, x * b.y - y * b.x) }
    public var length: Double { sqrt(dot(self)) }
    public var normalized: Vec3 {
        let l = length
        return l > 0 ? self * (1 / l) : self
    }

    /// Rodrigues rotation around a unit `axis` by `angle` degrees (right-hand rule).
    public func rotated(around axis: Vec3, by angle: Double) -> Vec3 {
        let a = radians(angle), k = axis.normalized
        return self * cos(a) + k.cross(self) * sin(a) + k * (k.dot(self) * (1 - cos(a)))
    }
}

/// Unit quaternion (x, y, z, w) as delivered by Core Motion (`CMQuaternion`).
public struct Quaternion: Sendable, Hashable {
    public var x: Double, y: Double, z: Double, w: Double

    public init(x: Double, y: Double, z: Double, w: Double) {
        self.x = x; self.y = y; self.z = z; self.w = w
    }

    /// Rotate `v` by this quaternion (q v q*).
    public func act(_ v: Vec3) -> Vec3 {
        let u = Vec3(x, y, z)
        let t = u.cross(v) * 2
        return v + t * w + u.cross(t)
    }
}
