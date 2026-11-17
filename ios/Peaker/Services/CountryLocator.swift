import CoreLocation
import Foundation
import MapKit
import PeakerKit

/// ISO country code of a coordinate, from Apple's reverse geocoding. Needs the network: nil when offline,
/// and the caller falls back to the catalog's country boxes (`CountrySuggestions`).
@MainActor
final class CountryLocator {
    /// Answers by coordinate rounded to ~1 km (Apple rate-limits geocoding requests).
    private var cache: [String: String] = [:]

    func countryCode(at c: GeoCoordinate) async -> String? {
        let key = String(format: "%.2f,%.2f", c.latitude, c.longitude)
        if let code = cache[key] { return code }
        guard let code = await Self.lookUp(latitude: c.latitude, longitude: c.longitude) else { return nil }
        cache[key] = code
        return code
    }

    /// The request and its map items stay inside this nonisolated function; only the code leaves it.
    nonisolated private static func lookUp(latitude: Double, longitude: Double) async -> String? {
        guard let request = MKReverseGeocodingRequest(location: CLLocation(latitude: latitude, longitude: longitude)),
              let items = try? await request.mapItems else { return nil }
        return items.first?.addressRepresentations?.region?.identifier
    }
}
