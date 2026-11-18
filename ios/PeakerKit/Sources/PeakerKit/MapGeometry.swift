import Foundation

/// Map scene units: 1 unit = 1 km. x east, y up, z south, around the frame's centre. Heights are multiplied by
/// the exaggeration. All map layers, peaks and markers are placed through one frame, so they line up.
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
    ///   - frame: the scene's frame; the grid may be centred elsewhere in it (map layers share one frame). Every
    ///     vertex goes through `frame.point`, like peaks and markers, so all layers line up.
    ///   - lowered: scene units to move the whole mesh down (a coarse layer under a detailed one).
    public init(grid: HeightGrid, frame: MapFrame, lowered: Float = 0) {
        let w = grid.width, h = grid.height
        positions = []
        uvs = []
        positions.reserveCapacity(w * h)
        uvs.reserveCapacity(w * h)
        for r in 0..<h {
            for c in 0..<w {
                let v = grid[r, c]
                var p = frame.point(grid.coordinate(row: Double(r), col: Double(c)), height: v.isNaN ? 0 : Double(v))
                p.y -= lowered
                positions.append(p)
                uvs.append(SIMD2(Float(c) / Float(w - 1), Float(r) / Float(h - 1)))
            }
        }
        // Normals from the neighbouring vertices (central differences, one-sided at the edges).
        normals = []
        normals.reserveCapacity(w * h)
        for r in 0..<h {
            for c in 0..<w {
                let east = positions[r * w + min(c + 1, w - 1)] - positions[r * w + max(c - 1, 0)]
                let south = positions[min(r + 1, h - 1) * w + c] - positions[max(r - 1, 0) * w + c]
                var n = SIMD3(south.y * east.z - south.z * east.y, south.z * east.x - south.x * east.z,
                              south.x * east.y - south.y * east.x)
                let length = (n * n).sum().squareRoot()
                n = length > 0 ? n / length : SIMD3(0, 1, 0)
                normals.append(n.y < 0 ? -n : n)
            }
        }
        indices = Self.indices(width: w, height: h)
    }

    /// Two upward-facing triangles per grid cell; cells for which `skip` (row, col of the cell's north-west
    /// corner) is true are left out.
    public static func indices(width w: Int, height h: Int, skip: ((Int, Int) -> Bool)? = nil) -> [UInt32] {
        var out: [UInt32] = []
        out.reserveCapacity((w - 1) * (h - 1) * 6)
        for r in 0..<(h - 1) {
            for c in 0..<(w - 1) {
                if let skip, skip(r, c) { continue }
                let i = UInt32(r * w + c), right = i + 1, below = i + UInt32(w), diagonal = below + 1
                // Counter-clockwise seen from above (+y), so the faces point up.
                out += [i, below, right, right, below, diagonal]
            }
        }
        return out
    }

    /// Indices without the cells lying entirely inside a scene rectangle (x, z): the hole a detailed layer fills.
    public func indices(width: Int, height: Int, excluding rect: (minX: Float, minZ: Float, maxX: Float, maxZ: Float)) -> [UInt32] {
        Self.indices(width: width, height: height) { r, c in
            for (dr, dc) in [(0, 0), (0, 1), (1, 0), (1, 1)] {
                let p = positions[(r + dr) * width + c + dc]
                if p.x < rect.minX || p.x > rect.maxX || p.z < rect.minZ || p.z > rect.maxZ { return false }
            }
            return true
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
    /// Beyond the farthest distance the map becomes the globe.
    public static let distanceRange: ClosedRange<Float> = 1.5...160

    /// Flattest allowed view at a distance: zoomed far out the view looks down more, so it shows the country
    /// rather than the horizon beyond the loaded area.
    public static func minimumPitch(distance: Float) -> Float {
        min(80, pitchRange.lowerBound + max(0, distance - 20) / 2.5)
    }

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

    /// Keeps the camera usable: limits distance and tilt, and repairs values that are not finite numbers (a
    /// single NaN would otherwise stay forever, since every gesture starts from the current camera).
    public func clamped() -> MapCamera {
        var c = self
        if !(c.target.x.isFinite && c.target.y.isFinite && c.target.z.isFinite) { c.target = .zero }
        if !c.distance.isFinite { c.distance = 16 }
        if !c.heading.isFinite { c.heading = 0 }
        if !c.pitch.isFinite { c.pitch = 55 }
        if !c.fieldOfView.isFinite || c.fieldOfView < 10 || c.fieldOfView > 120 { c.fieldOfView = 50 }
        c.distance = min(max(c.distance, Self.distanceRange.lowerBound), Self.distanceRange.upperBound)
        c.pitch = min(max(c.pitch, Self.minimumPitch(distance: c.distance)), Self.pitchRange.upperBound)
        c.heading = c.heading.truncatingRemainder(dividingBy: 360)
        if c.heading < 0 { c.heading += 360 }
        return c
    }
}

private func cross(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
}

private func dot(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { (a * b).sum() }

public extension HeightGrid {
    /// Coordinate of a (fractional) sample position: the inverse of `position(of:)`, as `sample` lays it out.
    func coordinate(row: Double, col: Double) -> GeoCoordinate {
        let half = Double(width - 1) * cellSize / 2
        let north = half - row * cellSize, east = col * cellSize - half
        return GeoCoordinate(latitude: center.latitude + north / 111_320,
                             longitude: center.longitude + east / (111_320 * cos(center.latitude * .pi / 180)))
    }

    /// Scene height (km, exaggerated) at a scene position (x, z), interpolated; nil outside the grid.
    func sceneHeight(x: Float, z: Float, frame: MapFrame) -> Float? {
        let p = position(of: frame.coordinate(x: x, z: z))
        guard p.col >= 0, p.row >= 0, p.col <= Double(width - 1), p.row <= Double(height - 1) else { return nil }
        let c = min(Int(p.col), width - 2), r = min(Int(p.row), height - 2)
        let fc = Float(p.col - Double(c)), fr = Float(p.row - Double(r))
        let v = self[r, c] * (1 - fr) * (1 - fc) + self[r, c + 1] * (1 - fr) * fc
            + self[r + 1, c] * fr * (1 - fc) + self[r + 1, c + 1] * fr * fc
        return v.isNaN ? 0 : v / 1000 * frame.exaggeration
    }

    /// True if nothing on the terrain blocks the straight line from `eye` to `point` (scene units). Aims a
    /// little above the summit (`clearance`) so the peak's own slope doesn't hide it.
    func isVisible(_ point: SIMD3<Float>, from eye: SIMD3<Float>, frame: MapFrame,
                   clearance: Float = 0.03, steps: Int = 96) -> Bool {
        let target = point + SIMD3(0, clearance, 0)
        for i in 1..<steps {
            let t = Float(i) / Float(steps)
            let p = eye + (target - eye) * t
            if let ground = sceneHeight(x: p.x, z: p.z, frame: frame), ground > p.y { return false }
        }
        return true
    }
}
