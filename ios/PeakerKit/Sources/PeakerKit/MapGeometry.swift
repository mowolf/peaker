import Foundation

/// Map scene units: 1 unit = 1 km. x east, y up, z south (row 0 of a grid, the north edge, has the smallest z),
/// centred on the grid's centre. Heights are multiplied by the exaggeration.
public struct MapFrame: Sendable, Equatable {
    public var center: GeoCoordinate
    public var exaggeration: Float

    public init(center: GeoCoordinate, exaggeration: Float) {
        self.center = center; self.exaggeration = exaggeration
    }

    static let metresPerDegreeLat = 111_320.0

    /// Scene position of a coordinate at a height (metres).
    public func point(_ c: GeoCoordinate, height: Double) -> SIMD3<Float> {
        let east = (c.longitude - center.longitude) * Self.metresPerDegreeLat * cos(center.latitude * .pi / 180)
        let north = (c.latitude - center.latitude) * Self.metresPerDegreeLat
        return SIMD3(Float(east / 1000), Float(height / 1000) * exaggeration, Float(-north / 1000))
    }

    /// Coordinate under a scene position (x, z).
    public func coordinate(x: Float, z: Float) -> GeoCoordinate {
        let north = Double(-z) * 1000, east = Double(x) * 1000
        return GeoCoordinate(latitude: center.latitude + north / Self.metresPerDegreeLat,
                             longitude: center.longitude + east / (Self.metresPerDegreeLat * cos(center.latitude * .pi / 180)))
    }
}

/// Vertex and index data of the terrain: one vertex per grid sample.
public struct TerrainMesh: Sendable {
    public var positions: [SIMD3<Float>]
    public var normals: [SIMD3<Float>]
    /// Texture coordinates: (0, 0) top-left (north-west), as the style texture is drawn.
    public var uvs: [SIMD2<Float>]
    public var indices: [UInt32]

    /// - Parameters:
    ///   - frame: the scene's frame; the grid may be centred elsewhere in it (map layers share one frame).
    ///   - lowered: scene units to move the whole mesh down (a coarse layer under a detailed one).
    public init(grid: HeightGrid, frame: MapFrame, lowered: Float = 0) {
        let w = grid.width, h = grid.height
        let cellKm = Float(grid.cellSize / 1000)
        let origin = frame.point(grid.center, height: 0)
        let halfW = Float(w - 1) / 2 - origin.x / cellKm, halfH = Float(h - 1) / 2 - origin.z / cellKm
        let ex = frame.exaggeration
        func height(_ r: Int, _ c: Int) -> Float {
            let v = grid[r, c]
            return (v.isNaN ? 0 : v / 1000 * ex) - lowered
        }
        positions = []
        normals = []
        uvs = []
        positions.reserveCapacity(w * h)
        normals.reserveCapacity(w * h)
        uvs.reserveCapacity(w * h)
        for r in 0..<h {
            for c in 0..<w {
                positions.append(SIMD3((Float(c) - halfW) * cellKm, height(r, c), (Float(r) - halfH) * cellKm))
                // Central differences: slope east (x) and south (z).
                let dx = (height(r, c + 1) - height(r, c - 1)) / (2 * cellKm)
                let dz = (height(r + 1, c) - height(r - 1, c)) / (2 * cellKm)
                let n = SIMD3<Float>(-dx, 1, -dz)
                normals.append(n / (n * n).sum().squareRoot())
                uvs.append(SIMD2(Float(c) / Float(w - 1), Float(r) / Float(h - 1)))
            }
        }
        indices = []
        indices.reserveCapacity((w - 1) * (h - 1) * 6)
        for r in 0..<(h - 1) {
            for c in 0..<(w - 1) {
                let i = UInt32(r * w + c), right = i + 1, below = i + UInt32(w), diagonal = below + 1
                // Counter-clockwise seen from above (+y), so the faces point up.
                indices += [i, below, right, right, below, diagonal]
            }
        }
    }
}

/// The map's camera: looks at a target on the ground from a distance, turned by `heading` (degrees clockwise
/// from north; 0 = north up) and tilted by `pitch` (degrees below the horizontal; 90 = straight down, the flat map).
public struct MapCamera: Sendable, Equatable {
    public var target: SIMD3<Float>
    /// Kilometres from the target.
    public var distance: Float
    public var heading: Float
    public var pitch: Float
    /// Vertical field of view (degrees).
    public var fieldOfView: Float

    public static let pitchRange: ClosedRange<Float> = 25...90
    public static let distanceRange: ClosedRange<Float> = 1.5...120

    public init(target: SIMD3<Float>, distance: Float, heading: Float = 0, pitch: Float = 50, fieldOfView: Float = 50) {
        self.target = target; self.distance = distance; self.heading = heading; self.pitch = pitch
        self.fieldOfView = fieldOfView
    }

    /// Unit vector from the eye towards the target.
    public var forward: SIMD3<Float> {
        let h = heading * .pi / 180, p = pitch * .pi / 180
        // Heading 0 looks north (−z); pitch tilts it down.
        return SIMD3(sin(h) * cos(p), -sin(p), -cos(h) * cos(p))
    }

    public var eye: SIMD3<Float> { target - forward * distance }

    /// Screen "up" in the world; straight down still keeps north (rotated by heading) at the top.
    public var up: SIMD3<Float> {
        let h = heading * .pi / 180, p = pitch * .pi / 180
        return SIMD3(sin(h) * sin(p), cos(p), -cos(h) * sin(p))
    }

    public var right: SIMD3<Float> { cross(forward, up) }

    /// Screen position (points, origin top-left) of a scene point, and its distance along the view; nil behind
    /// the camera.
    public func project(_ p: SIMD3<Float>, width: Float, height: Float) -> (x: Float, y: Float, depth: Float)? {
        let v = p - eye
        let z = dot(v, forward)
        guard z > 0.01 else { return nil }
        let focal = height / 2 / tan(fieldOfView * .pi / 360)
        return (width / 2 + dot(v, right) / z * focal, height / 2 - dot(v, up) / z * focal, z)
    }

    /// Scene point on the ground plane y = `groundHeight` under a screen position, if the ray hits it.
    public func groundPoint(x: Float, y: Float, width: Float, height: Float, groundHeight: Float) -> SIMD3<Float>? {
        let focal = height / 2 / tan(fieldOfView * .pi / 360)
        let ray = forward + right * ((x - width / 2) / focal) + up * ((height / 2 - y) / focal)
        guard ray.y < -1e-4 else { return nil }
        let t = (groundHeight - eye.y) / ray.y
        return eye + ray * t
    }

    /// Move the target by a screen drag (points), keeping it on the ground plane at its height.
    public func panned(dx: Float, dy: Float, width: Float, height: Float) -> MapCamera {
        guard let a = groundPoint(x: width / 2, y: height / 2, width: width, height: height, groundHeight: target.y),
              let b = groundPoint(x: width / 2 - dx, y: height / 2 - dy, width: width, height: height, groundHeight: target.y)
        else { return self }
        var moved = self
        moved.target += SIMD3(b.x - a.x, 0, b.z - a.z)
        return moved
    }

    public func clamped() -> MapCamera {
        var c = self
        c.pitch = min(max(pitch, Self.pitchRange.lowerBound), Self.pitchRange.upperBound)
        c.distance = min(max(distance, Self.distanceRange.lowerBound), Self.distanceRange.upperBound)
        c.heading = heading.truncatingRemainder(dividingBy: 360)
        if c.heading < 0 { c.heading += 360 }
        return c
    }
}

private func cross(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
}

private func dot(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { (a * b).sum() }

public extension HeightGrid {
    /// Scene height (km, exaggerated) at a scene position (x, z), interpolated; nil outside the grid.
    func sceneHeight(x: Float, z: Float, exaggeration: Float) -> Float? {
        let cellKm = Float(cellSize / 1000)
        let col = x / cellKm + Float(width - 1) / 2, row = z / cellKm + Float(height - 1) / 2
        guard col >= 0, row >= 0, col <= Float(width - 1), row <= Float(height - 1) else { return nil }
        let c = Int(col), r = Int(row), fc = col - Float(c), fr = row - Float(r)
        let v = self[r, c] * (1 - fr) * (1 - fc) + self[r, c + 1] * (1 - fr) * fc
            + self[r + 1, c] * fr * (1 - fc) + self[r + 1, c + 1] * fr * fc
        return v.isNaN ? 0 : v / 1000 * exaggeration
    }

    /// True if nothing on the terrain blocks the straight line from `eye` to `point` (scene units). Points a
    /// little above the summit (`clearance`) so the peak's own slope doesn't hide it.
    func isVisible(_ point: SIMD3<Float>, from eye: SIMD3<Float>, exaggeration: Float,
                   clearance: Float = 0.03, steps: Int = 96) -> Bool {
        let target = point + SIMD3(0, clearance, 0)
        for i in 1..<steps {
            let t = Float(i) / Float(steps)
            let p = eye + (target - eye) * t
            if let ground = sceneHeight(x: p.x, z: p.z, exaggeration: exaggeration), ground > p.y { return false }
        }
        return true
    }
}
