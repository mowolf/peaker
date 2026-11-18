import Foundation
import Testing
@testable import PeakerKit

struct CountryOutlinesTests {
    /// The file the app ships (written by the pipeline's `outlines` command).
    static let shipped = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Peaker/Resources/CountryOutlines.bin")

    @Test func shippedFileDecodes() throws {
        let outlines = try CountryOutlines(data: Data(contentsOf: Self.shipped))
        #expect(outlines.countries.count > 200)
        let ch = try #require(outlines.countries.first { $0.code == "CH" })
        #expect(ch.west > 5.8 && ch.east < 10.6 && ch.south > 45.7 && ch.north < 47.9)
        // Zermatt is in Switzerland, Milan in Italy, the middle of the Mediterranean is sea.
        let bounds = (west: 5.0, south: 38.0, east: 12.0, north: 48.0)
        let mask = outlines.mask(width: 700, height: 1000, bounds: bounds) { lon, lat in
            ((lon - 5) * 100, (48 - lat) * 100)
        }
        func country(_ lon: Double, _ lat: Double) -> String? {
            let v = mask[Int((48 - lat) * 100) * 700 + Int((lon - 5) * 100)]
            return v == 0 ? nil : outlines.countries[Int(v) - 1].code
        }
        #expect(country(7.75, 46.02) == "CH")
        #expect(country(9.19, 45.46) == "IT")
        #expect(country(6.0, 39.0) == nil)
        #expect(outlines.country(at: GeoCoordinate(latitude: 46.02, longitude: 7.75)) == "CH")  // Zermatt
        #expect(outlines.country(at: GeoCoordinate(latitude: 27.99, longitude: 86.83)) == "NP")  // Kala Patthar
        #expect(outlines.country(at: GeoCoordinate(latitude: 41.9, longitude: 12.45)) == "IT" ||
                outlines.country(at: GeoCoordinate(latitude: 41.9, longitude: 12.45)) == "VA")  // Rome
        #expect(outlines.country(at: GeoCoordinate(latitude: 39, longitude: 6)) == nil)  // sea
        // Lake Geneva and Lake Constance are lakes; Zurich's lake too.
        #expect(!outlines.lakes.isEmpty)
        func value(_ lon: Double, _ lat: Double) -> UInt16 { mask[Int((48 - lat) * 100) * 700 + Int((lon - 5) * 100)] }
        #expect(value(6.55, 46.45) == CountryOutlines.lake)
        #expect(value(9.40, 47.60) == CountryOutlines.lake)
        #expect(value(8.60, 47.30) == CountryOutlines.lake)
    }

    @Test func holesStayEmpty() {
        // A 10×10 square with a 2×2 hole, filled at pixel centres.
        let outer: [(x: Double, y: Double)] = [(0, 0), (10, 0), (10, 10), (0, 10)]
        let hole: [(x: Double, y: Double)] = [(4, 4), (6, 4), (6, 6), (4, 6)]
        var mask = [UInt16](repeating: 0, count: 100)
        CountryOutlines.fill([outer, hole], value: 7, into: &mask, width: 10, height: 10)
        #expect(mask[0] == 7 && mask[99] == 7)
        #expect(mask[4 * 10 + 4] == 0 && mask[5 * 10 + 5] == 0)
        #expect(mask[3 * 10 + 4] == 7)
        #expect(mask.filter { $0 == 7 }.count == 96)
    }

    @Test func worldAroundTheData() {
        // 3×1: data (1000 m), no data on land (country 1), no data at sea; country 2 next to 1 → border.
        let grid = HeightGrid(width: 3, height: 1, cellSize: 1000, center: GeoCoordinate(latitude: 46, longitude: 7),
                              heights: [1000, .nan, .nan])
        var style = MapStyle.dusk
        style.shading = 0
        let px = style.render(grid, countries: [2, 1, 0])
        #expect(Array(px[4..<7]) != Array(px[8..<11]))  // land and sea differ
        #expect(Array(px[8..<11]) == [114, 242, 255])  // sea next to land: the coastline (0.45, 0.95, 1.0)
        let plain = style.render(grid)
        #expect(Array(px[0..<3]) != Array(plain[0..<3]))  // border drawn between countries 2 and 1
    }

    @Test func downsampling() {
        let tile = ElevationTile(id: TileID(lat: 46, lon: 7), rows: 5, cols: 5, heights: (0..<25).map { Int16($0) })
        let small = tile.downsampled(step: 2)
        #expect(small.rows == 3 && small.cols == 3)
        #expect(small.heights == [0, 2, 4, 10, 12, 14, 20, 22, 24])
        #expect(small.height(latitude: 47, longitude: 8) == tile.height(latitude: 47, longitude: 8))
    }

    @Test func meshLayersShareAFrame() {
        let frame = MapFrame(center: GeoCoordinate(latitude: 46, longitude: 7), exaggeration: 1)
        let east = GeoCoordinate(latitude: 46, longitude: 7 + 10_000 / (111_320 * cos(46 * Double.pi / 180)))
        let grid = HeightGrid(width: 3, height: 3, cellSize: 1000, center: east, heights: [Float](repeating: 0, count: 9))
        let mesh = TerrainMesh(grid: grid, frame: frame, lowered: 0.1)
        #expect(abs(mesh.positions[4].x - 10) < 1e-3 && abs(mesh.positions[4].z) < 1e-3)
        #expect(abs(mesh.positions[4].y + 0.1) < 1e-6)
    }
}
