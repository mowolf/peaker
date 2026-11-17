import Foundation
import Testing
@testable import PeakerKit

/// One ridge point per ray at the same distance and angle: a ring all around the observer.
private func ring(rays: Int, skipping: Set<Int> = []) -> [[HorizonEngine.RawRidgePoint]] {
    (0..<rays).map { skipping.contains($0) ? [] : [HorizonEngine.RawRidgePoint(sample: 10, tan: 0.02, skyline: true)] }
}

@Test func ridgeContinuesAcrossNorth() {
    let distances = (0..<20).map { Double($0 + 1) * 1000 }
    // Gap in the middle (south), so the line starts at ray 0 and ends at the last ray: it must be one line.
    let perRay = ring(rays: 100, skipping: [50])
    let ridges = HorizonEngine.link(perRay: perRay, distances: distances, step: 3.6)
    #expect(ridges.count == 1)
    #expect(ridges.first?.points.count == 99)
    // The joined line runs from the eastern part (after the gap) through north into the western part.
    let azimuths = ridges.first?.points.map(\.azimuth) ?? []
    #expect(azimuths.first == 51 * 3.6 && azimuths.last == 49 * 3.6)
}

@Test func shortPiecesAtNorthSurviveWhenJoined() {
    let distances = (0..<20).map { Double($0 + 1) * 1000 }
    // Rays 0–1 and 98–99 only: two pieces of 2 points (non-skyline) would each be dropped, joined they're 4.
    var perRay = [[HorizonEngine.RawRidgePoint]](repeating: [], count: 100)
    for ray in [0, 1, 98, 99] { perRay[ray] = [.init(sample: 10, tan: 0.02, skyline: false)] }
    let ridges = HorizonEngine.link(perRay: perRay, distances: distances, step: 3.6)
    #expect(ridges.count == 1)
    #expect(ridges.first?.points.count == 4)
}

@Test func fullRingIsNotJoinedToItself() {
    let distances = (0..<20).map { Double($0 + 1) * 1000 }
    let ridges = HorizonEngine.link(perRay: ring(rays: 100), distances: distances, step: 3.6)
    #expect(ridges.count == 1)
    #expect(ridges.first?.points.count == 100)
}

@Test func ridgesComeFarFirst() {
    let distances = (0..<40).map { Double($0 + 1) * 1000 }
    let perRay: [[HorizonEngine.RawRidgePoint]] = (0..<10).map { _ in
        [.init(sample: 5, tan: 0.01, skyline: false), .init(sample: 30, tan: 0.03, skyline: true)]
    }
    let ridges = HorizonEngine.link(perRay: perRay, distances: distances, step: 1)
    #expect(ridges.count == 2)
    #expect(ridges[0].meanDistance > ridges[1].meanDistance)
    #expect(ridges.map(\.id) == [0, 1])
}

@Test func boxesSplitAtTheAntimeridian() {
    let plain = GeoBox.covering([TileID(lat: 45, lon: 7), TileID(lat: 46, lon: 8)], margin: 0.01)
    #expect(plain == [GeoBox(south: 44.99, north: 47.01, west: 6.99, east: 9.01)])

    let wrapped = GeoBox.covering([TileID(lat: -18, lon: 178), TileID(lat: -18, lon: 179), TileID(lat: -18, lon: -180)])
    #expect(wrapped.count == 2)
    #expect(wrapped.contains { $0.contains(GeoCoordinate(latitude: -17.5, longitude: 178.5)) })
    #expect(wrapped.contains { $0.contains(GeoCoordinate(latitude: -17.5, longitude: -179.5)) })
    #expect(!wrapped.contains { $0.contains(GeoCoordinate(latitude: -17.5, longitude: 0)) })
    #expect(GeoBox.covering([]).isEmpty)
}

@Test func ledgerKeepsSharedAndReservedTiles() {
    var ledger = TileLedger()
    ledger.installed["CH"] = ["90": ["N46E007", "N46E008"], "30": ["N46E007"]]
    ledger.installed["IT"] = ["90": ["N46E007", "N45E007"]]
    // Removing CH keeps N46E007 (90 m) for Italy, deletes the rest.
    #expect(ledger.removable(after: "CH") == ["90": ["N46E008"], "30": ["N46E007"]])

    // A running download of Austria needs N46E008 although it's already on disk: don't delete it.
    ledger.reserved["AT"] = ["90": ["N46E008", "N47E009"]]
    #expect(ledger.removable(after: "CH") == ["30": ["N46E007"]])

    // Files nobody uses (left by a failed download) are orphans.
    let disk: [String: Set<String>] = ["90": ["N46E007", "N46E008", "N50E010"], "30": ["N46E007", "N47E010"]]
    #expect(ledger.orphans(onDisk: disk) == ["90": ["N50E010"], "30": ["N47E010"]])
    #expect(ledger.removable(after: "XX").isEmpty)
}

@Test func catalogEntryWithoutNeighbours() throws {
    let json = """
    {"format_version": 1, "generated_at": "2026-11-01T08:00:00Z", "attribution": [], "land_tiles": {},
     "countries": [{"code": "NP", "name": "Nepal", "bbox": [80, 26, 88.2, 30.5], "manifest": "countries/NP.json",
       "built_at": "2026-11-01T08:11:00Z", "bytes": {"90": 1}, "tiles": {"90": 1}, "peaks": 1}]}
    """
    let catalog = try Catalog.decode(Data(json.utf8))
    #expect(catalog.countries.first?.neighbours == nil)
}

@Test func ridgeAzimuthRangeAcrossNorth() {
    let distances = (0..<20).map { Double($0 + 1) * 1000 }
    var perRay = [[HorizonEngine.RawRidgePoint]](repeating: [], count: 100)
    for ray in [97, 98, 99, 0, 1, 2] { perRay[ray] = [.init(sample: 10, tan: 0.02, skyline: false)] }
    let ridge = try! #require(HorizonEngine.link(perRay: perRay, distances: distances, step: 3.6).first)
    let range = ridge.azimuthRange
    #expect(abs(Geo.angleDifference(range.center, -1.8)) < 1e-9)  // 349.2° … 7.2°
    #expect(abs(range.halfWidth - 9) < 1e-9)
}

@Test func inPlaceBurnInMatchesCopy() {
    let tile = ElevationTile(id: TileID(lat: 46, lon: 7), rows: 1201, cols: 1201,
                             heights: [Int16](repeating: 1000, count: 1201 * 1201))
    let summits = [SummitBurnIn.Summit(coordinate: GeoCoordinate(latitude: 46.5, longitude: 7.5), elevation: 1200)]
    let copy = SummitBurnIn.apply(to: tile, summits: summits)
    var inPlace = tile
    SummitBurnIn.apply(summits, to: &inPlace)
    #expect(inPlace.heights == copy.heights && inPlace.maxHeight == 1200 && inPlace.minHeight == 1000)
    #expect(tile.heights.allSatisfy { $0 == 1000 })  // the original is untouched
}

@Test func decodesNonIntegerQuantisation() {
    // 2×2 tile, residual planes for q = [10, 12, 11, 15] with scale 0.5, offset 100.25.
    let q: [UInt16] = [10, 12, 11, 15]
    // Predictor: r0c0 = 0, r0c1 = q[0], r1c0 = q[0], r1c1 = q[2] + q[1] - q[0]
    let pred: [UInt16] = [0, 10, 10, 11 &+ 12 &- 10]
    let res = zip(q, pred).map { $0 &- $1 }
    let planes = res.map { UInt8($0 >> 8) } + res.map { UInt8($0 & 0xFF) }
    let h = TileCodec.decodeResidualPlanes(planes, rows: 2, cols: 2, scale: 0.5, offset: 100.25)
    #expect(h == q.map { Int16((Float($0) * 0.5 + 100.25).rounded()) })
}
