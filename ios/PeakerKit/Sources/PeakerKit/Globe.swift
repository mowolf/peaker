import Foundation

/// The zoomed-out map: the whole Earth as a sphere (1 scene unit = 1 km, centre at the origin, +y = north pole,
/// longitude 0 towards +z, east towards +x). Its texture is an equirectangular world image: u = longitude,
/// v = latitude, north at the top.
public enum Globe {
    public static let radius: Float = 6371

    /// Unit vector from the centre to a latitude/longitude (degrees).
    public static func direction(latitude: Double, longitude: Double) -> SIMD3<Float> {
        let φ = latitude * .pi / 180, λ = longitude * .pi / 180
        return SIMD3(Float(cos(φ) * sin(λ)), Float(sin(φ)), Float(cos(φ) * cos(λ)))
    }

    public static func point(_ c: GeoCoordinate, height: Float = 0) -> SIMD3<Float> {
        direction(latitude: c.latitude, longitude: c.longitude) * (radius + height)
    }

    /// Sphere mesh: `columns` × `rows` cells, vertices duplicated along the date line so the texture wraps.
    public static func mesh(columns: Int = 256, rows: Int = 128) -> TerrainMesh {
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], uvs: [SIMD2<Float>] = []
        for r in 0...rows {
            let lat = 90 - 180 * Double(r) / Double(rows)
            for c in 0...columns {
                let lon = -180 + 360 * Double(c) / Double(columns)
                let n = direction(latitude: lat, longitude: lon)
                positions.append(n * radius)
                normals.append(n)
                uvs.append(SIMD2(Float(c) / Float(columns), Float(r) / Float(rows)))
            }
        }
        var indices: [UInt32] = []
        let w = UInt32(columns + 1)
        for r in 0..<UInt32(rows) {
            for c in 0..<UInt32(columns) {
                let i = r * w + c, right = i + 1, below = i + w, diagonal = below + 1
                // Counter-clockwise seen from outside.
                indices += [i, below, right, right, below, diagonal]
            }
        }
        return TerrainMesh(positions: positions, normals: normals, uvs: uvs, indices: indices)
    }
}

public extension TerrainMesh {
    init(positions: [SIMD3<Float>], normals: [SIMD3<Float>], uvs: [SIMD2<Float>], indices: [UInt32]) {
        self.positions = positions; self.normals = normals; self.uvs = uvs; self.indices = indices
    }
}

/// Camera over the globe: straight down onto `center` from `altitude` km, turned so `heading` is at the top.
public struct GlobeCamera: Sendable, Equatable {
    public var center: GeoCoordinate
    public var altitude: Float
    public var heading: Float
    /// Vertical field of view (degrees).
    public var fieldOfView: Float = 50

    public static let altitudeRange: ClosedRange<Float> = 300...25_000

    public init(center: GeoCoordinate, altitude: Float, heading: Float = 0) {
        self.center = center; self.altitude = altitude; self.heading = heading
    }

    private var normal: SIMD3<Float> { Globe.direction(latitude: center.latitude, longitude: center.longitude) }

    public var eye: SIMD3<Float> { normal * (Globe.radius + altitude) }
    public var target: SIMD3<Float> { .zero }
    public var forward: SIMD3<Float> { -normal }

    /// North along the surface, turned clockwise by the heading.
    public var up: SIMD3<Float> {
        let φ = Float(center.latitude * .pi / 180), λ = Float(center.longitude * .pi / 180)
        let north = SIMD3(-sin(φ) * sin(λ), cos(φ), -sin(φ) * cos(λ))
        let east = SIMD3(cos(λ), 0, -sin(λ))
        let h = heading * .pi / 180
        return north * cos(h) + east * sin(h)
    }

    public var right: SIMD3<Float> {
        let f = forward, u = up
        return SIMD3(f.y * u.z - f.z * u.y, f.z * u.x - f.x * u.z, f.x * u.y - f.y * u.x)
    }

    /// Screen position of a scene point; nil behind the camera or on the far side of the Earth.
    public func project(_ p: SIMD3<Float>, width: Float, height: Float) -> (x: Float, y: Float)? {
        let toEye = eye - p
        // The point faces the camera (with a little margin at the rim).
        guard (p * toEye).sum() > 0 else { return nil }
        let v = p - eye
        let z = (v * forward).sum()
        guard z > 0.01 else { return nil }
        let focal = height / 2 / tan(fieldOfView * .pi / 360)
        return (width / 2 + (v * right).sum() / z * focal, height / 2 - (v * up).sum() / z * focal)
    }

    /// Move the centre by a screen drag (points): the globe follows the finger.
    public func panned(dx: Float, dy: Float, height: Float) -> GlobeCamera {
        let focal = height / 2 / tan(fieldOfView * .pi / 360)
        let kmPerPoint = altitude / focal
        let h = heading * .pi / 180
        // Finger right → the view moves west (the globe turns with the finger); finger down → north.
        let north = (dy * cos(h) + dx * sin(h)) * kmPerPoint
        let east = (-dx * cos(h) + dy * sin(h)) * kmPerPoint
        var c = self
        let lat = center.latitude + Double(north) / 111.32
        c.center = GeoCoordinate(latitude: min(85, max(-85, lat)),
                                 longitude: wrap(center.longitude + Double(east) / (111.32 * max(0.05, cos(center.latitude * .pi / 180)))))
        return c
    }

    public func clamped() -> GlobeCamera {
        var c = self
        if !c.altitude.isFinite { c.altitude = 3000 }
        if !c.heading.isFinite { c.heading = 0 }
        if !c.center.latitude.isFinite || !c.center.longitude.isFinite { c.center = GeoCoordinate(latitude: 46, longitude: 8) }
        c.altitude = min(max(c.altitude, Self.altitudeRange.lowerBound), Self.altitudeRange.upperBound)
        c.center = GeoCoordinate(latitude: min(85, max(-85, c.center.latitude)), longitude: wrap(c.center.longitude))
        c.heading = c.heading.truncatingRemainder(dividingBy: 360)
        if c.heading < 0 { c.heading += 360 }
        return c
    }
}

private func wrap(_ lon: Double) -> Double {
    var l = lon.truncatingRemainder(dividingBy: 360)
    if l > 180 { l -= 360 }
    if l < -180 { l += 360 }
    return l
}

public extension MapStyle {
    /// The equirectangular world image for the globe: `width` × `width/2` pixels, heights where `heightAt`
    /// knows them (downloaded countries), the rest black land or sea from the outlines, with borders.
    func renderWorld(width: Int, outlines: CountryOutlines?, heights: [Float]) -> [UInt8] {
        let height = width / 2
        let grid = HeightGrid(width: width, height: height, cellSize: 40_075_000 / Double(width),
                              center: GeoCoordinate(latitude: 0, longitude: 0), heights: heights)
        guard let outlines else { return render(grid, exaggeration: 3) }
        let mask = outlines.mask(width: width, height: height, bounds: (-180, -90, 180, 90)) { lon, lat in
            ((lon + 180) / 360 * Double(width), (90 - lat) / 180 * Double(height))
        }
        // Shading is exaggerated: at ~10 km per pixel the Alps would look flat otherwise.
        return render(grid, countries: mask, exaggeration: 3)
    }
}
