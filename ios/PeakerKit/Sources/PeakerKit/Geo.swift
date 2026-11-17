import Foundation

/// A WGS84 coordinate in degrees.
public struct GeoCoordinate: Sendable, Hashable, Codable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

@inline(__always) func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
@inline(__always) func degrees(_ radians: Double) -> Double { radians * 180 / .pi }

/// Spherical-earth geodesy. Accurate to ~0.3 %, which is far below the DEM's own error.
public enum Geo {
    public static let earthRadius: Double = 6_371_008.8
    /// Standard terrestrial refraction coefficient: light bends slightly around the earth.
    public static let defaultRefraction: Double = 0.13

    public static func distance(_ a: GeoCoordinate, _ b: GeoCoordinate) -> Double {
        let p1 = radians(a.latitude), p2 = radians(b.latitude)
        let dp = p2 - p1, dl = radians(b.longitude - a.longitude)
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }

    /// Initial bearing in degrees, clockwise from true north, 0..<360.
    public static func bearing(from a: GeoCoordinate, to b: GeoCoordinate) -> Double {
        let p1 = radians(a.latitude), p2 = radians(b.latitude), dl = radians(b.longitude - a.longitude)
        let y = sin(dl) * cos(p2)
        let x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
        return normalizedDegrees(degrees(atan2(y, x)))
    }

    public static func destination(from a: GeoCoordinate, bearing: Double, distance: Double) -> GeoCoordinate {
        let d = distance / earthRadius, t = radians(bearing)
        let p1 = radians(a.latitude), l1 = radians(a.longitude)
        let p2 = asin(sin(p1) * cos(d) + cos(p1) * sin(d) * cos(t))
        let l2 = l1 + atan2(sin(t) * sin(d) * cos(p1), cos(d) - sin(p1) * sin(p2))
        return GeoCoordinate(latitude: degrees(p2), longitude: normalizedLongitude(degrees(l2)))
    }

    /// How far a point at `distance` sinks below the observer's horizontal plane because of
    /// earth curvature, reduced by atmospheric refraction.
    public static func curvatureDrop(distance: Double, refraction: Double = defaultRefraction) -> Double {
        distance * distance / (2 * earthRadius) * (1 - refraction)
    }

    /// Apparent elevation angle (degrees) of a point `height` metres high, seen from `observerHeight`.
    public static func elevationAngle(observerHeight: Double, targetHeight: Double, distance: Double,
                                      refraction: Double = defaultRefraction) -> Double {
        degrees(atan2(targetHeight - curvatureDrop(distance: distance, refraction: refraction) - observerHeight,
                      distance))
    }

    public static func normalizedDegrees(_ value: Double) -> Double {
        let r = value.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }

    public static func normalizedLongitude(_ lon: Double) -> Double {
        var l = (lon + 180).truncatingRemainder(dividingBy: 360)
        if l < 0 { l += 360 }
        return l - 180
    }

    /// Signed smallest difference a - b in degrees, -180..<180.
    public static func angleDifference(_ a: Double, _ b: Double) -> Double {
        var d = (a - b).truncatingRemainder(dividingBy: 360)
        if d >= 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }
}

/// A latitude/longitude box that does not cross the antimeridian (west <= east).
public struct GeoBox: Sendable, Hashable {
    public var south: Double, north: Double, west: Double, east: Double

    public init(south: Double, north: Double, west: Double, east: Double) {
        self.south = south; self.north = north; self.west = west; self.east = east
    }

    public func contains(_ c: GeoCoordinate) -> Bool {
        c.latitude >= south && c.latitude <= north && c.longitude >= west && c.longitude <= east
    }

    /// Boxes covering whole tiles plus `margin` degrees, split in two where the tiles wrap around ±180°.
    public static func covering(_ tiles: [TileID], margin: Double = 0) -> [GeoBox] {
        guard let minLat = tiles.map(\.lat).min(), let maxLat = tiles.map(\.lat).max() else { return [] }
        let south = max(-90, Double(minLat) - margin), north = min(90, Double(maxLat + 1) + margin)
        let lons = tiles.map(\.lon)
        let minLon = lons.min()!, maxLon = lons.max()!
        if maxLon - minLon > 180 {
            // Wrapped: eastern part from the westernmost positive tile to 180, western part from -180.
            let eastStart = lons.filter { $0 >= 0 }.min() ?? minLon
            let westEnd = lons.filter { $0 < 0 }.max() ?? maxLon
            return [GeoBox(south: south, north: north, west: Double(eastStart) - margin, east: 180),
                    GeoBox(south: south, north: north, west: -180, east: Double(westEnd + 1) + margin)]
        }
        return [GeoBox(south: south, north: north, west: max(-180, Double(minLon) - margin),
                       east: min(180, Double(maxLon + 1) + margin))]
    }
}
