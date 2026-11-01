import Testing
@testable import PeakerKit

private func flatTile(_ h: Int16 = 1000, n: Int = 1201) -> ElevationTile {
    ElevationTile(id: TileID(lat: 45, lon: 7), rows: n, cols: n, heights: [Int16](repeating: h, count: n * n))
}

@Test func liftsSummitWithNarrowCone() {
    let tile = flatTile()
    let summit = GeoCoordinate(latitude: 45.5, longitude: 7.5)  // exactly on node (600, 600)
    let out = SummitBurnIn.apply(to: tile, summits: [.init(coordinate: summit, elevation: 1200)])
    #expect(out.heights[600 * 1201 + 600] == 1200)
    #expect(out.height(latitude: 45.5, longitude: 7.5) == 1200)
    // One row (~93 m) away the cone is ~107 m above the plain; three rows away it's untouched.
    let next = out.heights[601 * 1201 + 600]
    #expect(next > 1100 && next < 1115)
    #expect(out.heights[603 * 1201 + 600] == 1000)
    #expect(out.maxHeight == 1200)
}

@Test func usesHighestNearbyNodeAndNeverLowers() {
    var h = [Int16](repeating: 1000, count: 1201 * 1201)
    h[600 * 1201 + 601] = 1150  // DEM summit one node east of the given coordinate
    let tile = ElevationTile(id: TileID(lat: 45, lon: 7), rows: 1201, cols: 1201, heights: h)
    let out = SummitBurnIn.apply(to: tile, summits: [.init(coordinate: GeoCoordinate(latitude: 45.5, longitude: 7.5),
                                                          elevation: 1180)])
    #expect(out.heights[600 * 1201 + 601] == 1180)  // the DEM's top was lifted, not the coordinate's node
    #expect(out.heights.allSatisfy { $0 >= 1000 })
}

@Test func skipsTinyAndImplausibleLifts() {
    let tile = flatTile()
    let c = GeoCoordinate(latitude: 45.5, longitude: 7.5)
    #expect(SummitBurnIn.apply(to: tile, summits: [.init(coordinate: c, elevation: 1003)]).heights == tile.heights)
    #expect(SummitBurnIn.apply(to: tile, summits: [.init(coordinate: c, elevation: 2000)]).heights == tile.heights)
    #expect(SummitBurnIn.apply(to: tile, summits: [.init(coordinate: c, elevation: 900)]).heights == tile.heights)
    // Outside the tile: ignored.
    #expect(SummitBurnIn.apply(to: tile, summits: [.init(coordinate: GeoCoordinate(latitude: 47, longitude: 7.5),
                                                        elevation: 1200)]).heights == tile.heights)
}
