import Foundation
import Testing
@testable import PeakerKit

@Test func tileNames() {
    #expect(TileID(lat: 45, lon: 7).name == "N45E007")
    #expect(TileID(lat: -33, lon: -70).name == "S33W070")
    #expect(TileID(name: "S01W001") == TileID(lat: -1, lon: -1))
    #expect(TileID(name: "X45E007") == nil)
    #expect(TileID.containing(latitude: 45.97, longitude: 7.65) == TileID(lat: 45, lon: 7))
    #expect(TileID.containing(latitude: -0.5, longitude: 180) == TileID(lat: -1, lon: -180))
    let around = TileID.covering(center: matterhorn, radius: 100_000)
    #expect(around.contains(TileID(lat: 45, lon: 7)) && around.contains(TileID(lat: 46, lon: 8)))
    #expect(around.count == 6)  // lat 45–46 × lon 6–8
}

@Test func headerMatchesPythonEncoder() throws {
    let data = Data(base64Encoded: TileFixture.pktBase64)!
    let h = try TileCodec.header(of: data)
    #expect(h.lat == 45 && h.lon == 7 && h.rows == TileFixture.rows && h.cols == TileFixture.cols)
    #expect(h.scale == 1 && h.offset == -500 && h.codec == 1 && h.predictor == 1 && h.layout == 1)
    #expect(h.minHeight == -420 && h.maxHeight == 8849)
    #expect(h.payloadLength == data.count - TileCodec.headerSize)
}

@Test func predictorMatchesPythonEncoder() {
    let planes = [UInt8](Data(base64Encoded: TileFixture.planesBase64)!)
    let heights = TileCodec.decodeResidualPlanes(planes, rows: TileFixture.rows, cols: TileFixture.cols,
                                                 scale: 1, offset: -500)
    #expect(heights == TileFixture.heights)
}

@Test func decodeWithInjectedInflate() throws {
    let planes = Data(base64Encoded: TileFixture.planesBase64)!
    let tile = try TileCodec.decode(Data(base64Encoded: TileFixture.pktBase64)!) { _, size in
        #expect(size == planes.count)
        return planes
    }
    #expect(tile.heights == TileFixture.heights)
    #expect(tile.id == TileID(lat: 45, lon: 7))
    // Corners: row 0 = north edge, column 0 = west edge.
    #expect(tile.height(latitude: 46, longitude: 7) == Float(TileFixture.heights[0]))
    #expect(tile.height(latitude: 45, longitude: 8) == Float(TileFixture.heights.last!))
}

#if canImport(Darwin)
@Test func decodeWithSystemInflate() throws {
    let tile = try TileCodec.decode(Data(base64Encoded: TileFixture.pktBase64)!)
    #expect(tile.heights == TileFixture.heights)
}
#endif

@Test func rejectsGarbage() {
    #expect(throws: TileDecodingError.badMagic) { try TileCodec.header(of: Data(repeating: 0, count: 40)) }
    #expect(throws: TileDecodingError.truncated) { try TileCodec.header(of: Data([0x50, 0x4B])) }
}

@Test func bilinearSampling() {
    // 3×3 grid over N45E007 with heights = row*10 + col
    let tile = ElevationTile(id: TileID(lat: 45, lon: 7), rows: 3, cols: 3, heights: [0, 1, 2, 10, 11, 12, 20, 21, 22])
    #expect(tile.height(latitude: 45.5, longitude: 7.5) == 11)
    #expect(tile.height(latitude: 45.75, longitude: 7.25) == 5.5)
    #expect(tile.height(latitude: 47, longitude: 6) == 0)  // clamped
}

@Test func terrainModelOceanAndMissing() {
    let tile = ElevationTile(id: TileID(lat: 45, lon: 7), rows: 2, cols: 2, heights: [100, 100, 100, 100])
    let ids = [TileID(lat: 45, lon: 7), TileID(lat: 45, lon: 8), TileID(lat: 46, lon: 7)]
    let model = TerrainModel(covering: ids, tiles: [ids[0]: tile]) { id in id == TileID(lat: 45, lon: 8) ? false : true }
    #expect(model.height(latitude: 45.5, longitude: 7.5) == 100)
    #expect(model.height(latitude: 45.5, longitude: 8.5) == 0)  // ocean
    #expect(model.height(latitude: 46.5, longitude: 7.5) == nil)  // land, not downloaded
    #expect(model.height(latitude: 50, longitude: 7.5) == nil)  // outside
}

@Test func terrainModelAcrossAntimeridian() {
    let west = ElevationTile(id: TileID(lat: -17, lon: -180), rows: 2, cols: 2, heights: [5, 5, 5, 5])
    let east = ElevationTile(id: TileID(lat: -17, lon: 179), rows: 2, cols: 2, heights: [7, 7, 7, 7])
    let model = TerrainModel(covering: [west.id, east.id], tiles: [west.id: west, east.id: east]) { _ in true }
    #expect(model.height(latitude: -16.5, longitude: 179.5) == 7)
    #expect(model.height(latitude: -16.5, longitude: -179.5) == 5)
}
