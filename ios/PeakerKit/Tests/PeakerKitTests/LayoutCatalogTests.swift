import Foundation
import Testing
@testable import PeakerKit

@Test func labelsDontOverlap() {
    let candidates = (0..<10).map { i in
        LabelLayout.Candidate(id: "\(i)", x: 100 + Double(i) * 15, y: 400, width: 80, priority: Double(10 - i))
    }
    let placed = LabelLayout.place(candidates, rows: 4)
    #expect(placed.first?.id == "0" && placed.first?.row == 0)
    for (i, a) in placed.enumerated() {
        for b in placed[(i + 1)...] {
            let overlap = a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height
            #expect(!overlap)
        }
    }
    #expect(placed.count < 10 && placed.count >= 3)
    #expect(LabelLayout.place(candidates, maxLabels: 2).count == 2)
}

@Test func catalogDecoding() throws {
    var bits = [UInt8](repeating: 0, count: 8100)
    let land = TileID(lat: 45, lon: 7)
    bits[land.bitIndex / 8] |= 1 << UInt8(land.bitIndex % 8)
    let json = """
    {"format_version": 1, "generated_at": "2026-11-01T08:00:00Z",
     "attribution": [{"name": "Copernicus DEM", "text": "©", "url": "https://example.org"}],
     "land_tiles": {"90": "\(Data(bits).base64EncodedString())"},
     "countries": [{"code": "CH", "name": "Switzerland", "bbox": [5.9, 45.8, 10.5, 47.8],
       "manifest": "countries/CH.json", "built_at": "2026-11-01T08:11:00Z", "bytes": {"90": 28603318},
       "tiles": {"90": 23}, "peaks": 23986, "neighbours": ["AT", "DE"]}]}
    """
    let catalog = try Catalog.decode(Data(json.utf8))
    #expect(catalog.countries.first?.bytes["90"] == 28_603_318)
    let tiles = try #require(catalog.landTiles())
    #expect(tiles.contains(land))
    #expect(!tiles.contains(TileID(lat: 40, lon: -30)))
}

@Test func manifestDecoding() throws {
    let json = """
    {"format_version": 1, "code": "CH", "name": "Switzerland", "built_at": "2026-11-01T08:11:00Z",
     "buffer_km": 50, "bbox": [5.9, 45.8, 10.5, 47.8], "tile_codec": "pred2d-deflate@1m",
     "tiles": {"90": [{"name": "N45E007", "bytes": 1203394, "sha256": "ab"}]},
     "peaks": {"path": "peaks/CH.202611010811.sqlite.deflate", "bytes": 3457019, "uncompressed_bytes": 9031680,
               "sha256": "cd", "count": 23986, "schema_version": 1},
     "neighbours": ["AT"]}
    """
    let m = try PackManifest.decode(Data(json.utf8))
    #expect(m.tiles["90"]?.first?.name == "N45E007")
    #expect(m.peaks.uncompressedBytes == 9_031_680)
}
