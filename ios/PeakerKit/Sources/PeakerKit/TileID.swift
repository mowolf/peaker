import Foundation

/// 1°×1° tile named after its south-west corner, e.g. `N45E007` (see docs/tile-format.md).
public struct TileID: Sendable, Hashable, Codable, Comparable, CustomStringConvertible {
    public let lat: Int  // south edge, -90...89
    public let lon: Int  // west edge, -180...179

    public init(lat: Int, lon: Int) {
        self.lat = lat
        self.lon = lon
    }

    public init?(name: String) {
        let c = Array(name.utf8)
        guard c.count == 7,
              let la = Int(String(decoding: c[1..<3], as: UTF8.self)),
              let lo = Int(String(decoding: c[4..<7], as: UTF8.self)) else { return nil }
        let ns = c[0], ew = c[3]
        guard ns == UInt8(ascii: "N") || ns == UInt8(ascii: "S"),
              ew == UInt8(ascii: "E") || ew == UInt8(ascii: "W") else { return nil }
        lat = ns == UInt8(ascii: "N") ? la : -la
        lon = ew == UInt8(ascii: "E") ? lo : -lo
    }

    public static func containing(latitude: Double, longitude: Double) -> TileID {
        let lon = Geo.normalizedLongitude(longitude)
        return TileID(lat: min(89, Int(floor(latitude))), lon: min(179, Int(floor(lon))))
    }

    public var name: String {
        let ns = lat >= 0 ? "N" : "S", ew = lon >= 0 ? "E" : "W"
        let la = String(abs(lat)), lo = String(abs(lon))
        return ns + String(repeating: "0", count: 2 - la.count) + la
            + ew + String(repeating: "0", count: 3 - lo.count) + lo
    }

    public var description: String { name }

    /// Bit index in the catalog's land bitset.
    public var bitIndex: Int { (lat + 90) * 360 + (lon + 180) }

    public static func < (a: TileID, b: TileID) -> Bool { (a.lat, a.lon) < (b.lat, b.lon) }

    /// All tiles touching a circle of `radius` metres around `center`.
    public static func covering(center: GeoCoordinate, radius: Double) -> [TileID] {
        let dLat = radius / 111_320
        let latMin = max(-90, Int(floor(center.latitude - dLat)))
        let latMax = min(89, Int(floor(center.latitude + dLat)))
        let maxAbsLat = min(89.9, max(abs(center.latitude - dLat), abs(center.latitude + dLat)))
        let dLon = min(180, radius / (111_320 * max(cos(radians(maxAbsLat)), 0.01)))
        let lonStart = Int(floor(center.longitude - dLon))
        let lonEnd = Int(floor(center.longitude + dLon))
        var out: [TileID] = []
        var seen = Set<TileID>()
        for la in latMin...latMax {
            for lo in lonStart...lonEnd {
                let t = TileID(lat: la, lon: Int(Geo.normalizedLongitude(Double(lo))))
                if seen.insert(t).inserted { out.append(t) }
            }
        }
        return out
    }
}
