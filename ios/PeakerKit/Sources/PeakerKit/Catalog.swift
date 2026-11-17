import Foundation

/// `v1/catalog.json` (docs/pack-format.md).
public struct Catalog: Sendable, Codable {
    public var formatVersion: Int
    public var generatedAt: String
    public var attribution: [Attribution]
    public var landTiles: [String: String]
    public var countries: [CountryEntry]

    public struct Attribution: Sendable, Codable, Hashable {
        public var name: String
        public var text: String
        public var url: String
        public init(name: String, text: String, url: String) {
            self.name = name; self.text = text; self.url = url
        }
    }

    public struct CountryEntry: Sendable, Codable, Hashable, Identifiable {
        public var code: String
        public var name: String
        public var bbox: [Double]
        public var manifest: String
        public var builtAt: String
        public var bytes: [String: Int]
        public var tiles: [String: Int]
        public var peaks: Int
        /// Optional so an entry without it doesn't make the whole catalog unreadable.
        public var neighbours: [String]?
        public var id: String { code }
    }

    public static func decode(_ data: Data) throws -> Catalog {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(Catalog.self, from: data)
    }

    public func landTiles(resolution: String = "90") -> LandTiles? {
        landTiles[resolution].flatMap { Data(base64Encoded: $0) }.map(LandTiles.init)
    }
}

/// `v1/countries/<CC>.json`.
public struct PackManifest: Sendable, Codable, Hashable {
    public var formatVersion: Int
    public var code: String
    public var name: String
    public var builtAt: String
    public var bufferKm: Double
    public var bbox: [Double]
    public var tileCodec: String
    public var tiles: [String: [TileFile]]
    public var peaks: PeaksFile
    public var neighbours: [String]?

    public struct TileFile: Sendable, Codable, Hashable {
        public var name: String
        public var bytes: Int
        public var sha256: String
    }

    public struct PeaksFile: Sendable, Codable, Hashable {
        public var path: String
        public var bytes: Int
        public var uncompressedBytes: Int
        public var sha256: String
        public var count: Int
        public var schemaVersion: Int
    }

    public static func decode(_ data: Data) throws -> PackManifest {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(PackManifest.self, from: data)
    }
}

/// Which tiles have elevation data at all; everything else is sea.
public struct LandTiles: Sendable {
    let bits: [UInt8]
    public init(_ data: Data) { bits = [UInt8](data) }

    public func contains(_ tile: TileID) -> Bool {
        let i = tile.bitIndex
        guard i >= 0, i / 8 < bits.count else { return false }
        return bits[i / 8] >> UInt8(i % 8) & 1 == 1
    }
}
