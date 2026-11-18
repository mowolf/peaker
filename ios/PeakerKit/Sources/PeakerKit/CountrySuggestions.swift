import Foundation

/// Which catalog countries to suggest for a viewpoint: the country you're in, and the ones you can see into.
public enum CountrySuggestions {
    public struct Result: Sendable, Equatable {
        /// The country of the viewpoint.
        public var here: Catalog.CountryEntry?
        /// Other countries within the view distance, closest first. Each pack already includes ~50 km around
        /// its border, so these matter for views further across it.
        public var nearby: [Catalog.CountryEntry]
    }

    /// - Parameters:
    ///   - countryCode: ISO code from reverse geocoding; nil when unknown (offline): then the smallest catalog
    ///     bounding box containing the viewpoint wins (Liechtenstein over Switzerland, Austria over Italy).
    ///   - viewDistance: metres
    ///   - maxNearby: at most this many nearby countries
    public static func suggest(at viewpoint: GeoCoordinate, countryCode: String?, in entries: [Catalog.CountryEntry],
                               viewDistance: Double, maxNearby: Int = 4) -> Result {
        let valid = entries.filter { $0.bbox.count == 4 }
        let here = countryCode.flatMap { code in valid.first { $0.code.caseInsensitiveCompare(code) == .orderedSame } }
            ?? valid.filter { distance(from: viewpoint, toBox: $0.bbox) == 0 }.min { area($0.bbox) < area($1.bbox) }
        let distances: [(entry: Catalog.CountryEntry, metres: Double)] = valid
            .filter { $0.code != here?.code }
            .map { ($0, distance(from: viewpoint, toBox: $0.bbox)) }
        let nearby = distances.filter { $0.metres <= viewDistance }.sorted { $0.metres < $1.metres }
        return Result(here: here, nearby: nearby.prefix(maxNearby).map(\.entry))
    }

    /// Distance (metres) from a point to a [west, south, east, north] box; 0 inside.
    static func distance(from c: GeoCoordinate, toBox b: [Double]) -> Double {
        let lat = min(max(c.latitude, b[1]), b[3])
        let lon = min(max(c.longitude, b[0]), b[2])
        if lat == c.latitude && lon == c.longitude { return 0 }
        return Geo.distance(c, GeoCoordinate(latitude: lat, longitude: lon))
    }

    /// Box area in square degrees, scaled by latitude: good enough to compare countries.
    static func area(_ b: [Double]) -> Double {
        (b[2] - b[0]) * (b[3] - b[1]) * cos(radians((b[1] + b[3]) / 2))
    }
}
