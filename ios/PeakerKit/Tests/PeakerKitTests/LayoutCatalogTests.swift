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

@Test func labelsKeepTheirPreviousRow() {
    let a = LabelLayout.Candidate(id: "a", x: 100, y: 400, width: 80, priority: 0.9)
    let b = LabelLayout.Candidate(id: "b", x: 120, y: 400, width: 80, priority: 0.5)
    let first = LabelLayout.place([a, b])
    #expect(first.first { $0.id == "a" }?.row == 0)
    // Next frame b is slightly more important, but both stay where they were.
    let prev = Dictionary(uniqueKeysWithValues: first.map { ($0.id, $0.row) })
    let b2 = LabelLayout.Candidate(id: "b", x: 121, y: 400, width: 80, priority: 0.95)
    let second = LabelLayout.place([a, b2], previous: prev)
    #expect(Dictionary(uniqueKeysWithValues: second.map { ($0.id, $0.row) }) == prev)
}

@Test func labelsFlipLeftAtTheRightEdge() {
    let c = LabelLayout.Candidate(id: "edge", x: 380, y: 400, width: 120, priority: 1)
    let placed = LabelLayout.place([c], maxX: 400)
    let p = try! #require(placed.first)
    #expect(p.x + p.width <= 400 && p.x < 380)
}

@Test func stickinessKeepsShownLabelsOverSlightlyMoreImportantNewOnes() {
    let old = LabelLayout.Candidate(id: "old", x: 100, y: 400, width: 80, priority: 0.5)
    let new = LabelLayout.Candidate(id: "new", x: 100, y: 400, width: 80, priority: 0.6)
    let placed = LabelLayout.place([old, new], rows: 1, previous: ["old": 0])
    #expect(placed.map(\.id) == ["old"])
}

@Test func displayNamePrefersReadableNames() {
    let everest = PeakInfo(id: "e", name: "珠穆朗玛峰 ཇོ་མོ་གླང་མ། सगरमाथा", names: ["en": "Mount Everest", "ne": "सगरमाथा"],
                           coordinate: GeoCoordinate(latitude: 27.99, longitude: 86.93), elevation: 8849, importance: 1)
    #expect(everest.displayName(language: "de") == "Mount Everest")
    #expect(everest.displayName(language: "ne") == "सगरमाथा")
    let matterhorn = PeakInfo(id: "m", name: "Matterhorn", names: ["it": "Cervino", "en": "Matterhorn"],
                              coordinate: GeoCoordinate(latitude: 45.98, longitude: 7.66), elevation: 4478, importance: 1)
    #expect(matterhorn.displayName(language: "it") == "Cervino")
    #expect(matterhorn.displayName(language: "fr") == "Matterhorn")  // local Latin name beats English
    let onlyGerman = PeakInfo(id: "g", name: "मकालु", names: ["de": "Makalu"],
                              coordinate: GeoCoordinate(latitude: 27.89, longitude: 87.09), elevation: 8485, importance: 1)
    #expect(onlyGerman.displayName(language: "en") == "Makalu")
    let onlyLocal = PeakInfo(id: "l", name: "मनास्लु", coordinate: GeoCoordinate(latitude: 28.55, longitude: 84.56),
                             elevation: 8163, importance: 1)
    #expect(onlyLocal.displayName(language: "en") == "मनास्लु")
    #expect(PeakInfo.isLatinScript("Piz Palü – Ostgipfel") && !PeakInfo.isLatinScript("अन्नपूर्ण"))
}
