import Foundation
import Testing
@testable import PeakerKit

private func entry(_ code: String, _ bbox: [Double]) -> Catalog.CountryEntry {
    Catalog.CountryEntry(code: code, name: code, bbox: bbox, manifest: "countries/\(code).json", builtAt: "",
                         bytes: [:], tiles: [:], peaks: 0, neighbours: nil)
}

// Rough catalog boxes (west, south, east, north).
private let ch = entry("CH", [5.96, 45.82, 10.49, 47.81])
private let at = entry("AT", [9.53, 46.37, 17.16, 49.02])
private let li = entry("LI", [9.47, 47.05, 9.64, 47.27])
private let it = entry("IT", [6.63, 35.49, 18.52, 47.09])
private let de = entry("DE", [5.87, 47.27, 15.04, 55.06])
private let np = entry("NP", [80.06, 26.35, 88.20, 30.45])
private let all = [ch, at, li, it, de, np]

@Test func geocodedCountryWins() {
    // Zermatt: inside the Swiss and Italian boxes; the geocoder says CH.
    let r = CountrySuggestions.suggest(at: GeoCoordinate(latitude: 46.02, longitude: 7.75), countryCode: "ch",
                                       in: all, viewDistance: 200_000)
    #expect(r.here?.code == "CH")
    #expect(r.nearby.first?.code == "IT")  // inside its box: distance 0
    #expect(!r.nearby.contains { $0.code == "NP" || $0.code == "CH" })
}

@Test func offlineFallsBackToTheSmallestBox() {
    // Vaduz: inside the boxes of LI, CH and AT.
    let vaduz = CountrySuggestions.suggest(at: GeoCoordinate(latitude: 47.14, longitude: 9.52), countryCode: nil,
                                           in: all, viewDistance: 100_000)
    #expect(vaduz.here?.code == "LI")
    // Innsbruck: inside AT and the northern tip of IT's box; Austria's is smaller.
    let innsbruck = CountrySuggestions.suggest(at: GeoCoordinate(latitude: 47.0, longitude: 11.4), countryCode: nil,
                                               in: all, viewDistance: 50_000)
    #expect(innsbruck.here?.code == "AT")
}

@Test func nearbyIsLimitedAndSortedByDistance() {
    let r = CountrySuggestions.suggest(at: GeoCoordinate(latitude: 47.14, longitude: 9.52), countryCode: "LI",
                                       in: all, viewDistance: 300_000, maxNearby: 2)
    #expect(r.nearby.count == 2)
    #expect(r.nearby.allSatisfy { $0.code != "LI" })
    let unknown = CountrySuggestions.suggest(at: GeoCoordinate(latitude: 0, longitude: 0), countryCode: "XX",
                                             in: all, viewDistance: 100_000)
    #expect(unknown.here == nil && unknown.nearby.isEmpty)
}
