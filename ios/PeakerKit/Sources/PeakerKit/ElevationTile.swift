import Foundation

/// A decoded elevation tile: point-registered grid, row 0 = northern edge, column 0 = western edge.
public struct ElevationTile: Sendable {
    public let id: TileID
    public let rows: Int
    public let cols: Int
    /// Metres, row-major.
    public let heights: [Int16]
    public let minHeight: Int16
    public let maxHeight: Int16

    public init(id: TileID, rows: Int, cols: Int, heights: [Int16]) {
        precondition(rows >= 2 && cols >= 2 && heights.count == rows * cols)
        self.id = id
        self.rows = rows
        self.cols = cols
        self.heights = heights
        self.minHeight = heights.min() ?? 0
        self.maxHeight = heights.max() ?? 0
    }

    /// Bilinear height at a coordinate inside this tile (clamped to the tile).
    @inline(__always)
    public func height(latitude: Double, longitude: Double) -> Float {
        let r = (Double(id.lat + 1) - latitude) * Double(rows - 1)
        let c = (longitude - Double(id.lon)) * Double(cols - 1)
        return height(row: r, col: c)
    }

    @inline(__always)
    public func height(row: Double, col: Double) -> Float {
        let r = min(max(row, 0), Double(rows - 1))
        let c = min(max(col, 0), Double(cols - 1))
        let r0 = min(Int(r), rows - 2), c0 = min(Int(c), cols - 2)
        let fr = Float(r - Double(r0)), fc = Float(c - Double(c0))
        return heights.withUnsafeBufferPointer { h in
            let i = r0 * cols + c0
            let top = Float(h[i]) * (1 - fc) + Float(h[i + 1]) * fc
            let bottom = Float(h[i + cols]) * (1 - fc) + Float(h[i + cols + 1]) * fc
            return top * (1 - fr) + bottom * fr
        }
    }
}

public enum TileDecodingError: Error, Equatable {
    case badMagic
    case truncated
    case unsupportedCodec(UInt8)
    case unsupportedLayout
    case sizeMismatch(expected: Int, got: Int)
}

/// Decoder for the `.pkt` format (docs/tile-format.md).
public enum TileCodec {
    /// Raw DEFLATE decompression: (compressed payload, expected output size) → bytes.
    public typealias Inflate = @Sendable (Data, Int) throws -> Data

    public struct Header: Sendable, Equatable {
        public var lat: Int, lon: Int, rows: Int, cols: Int
        public var scale: Float, offset: Float
        public var codec: UInt8, predictor: UInt8, layout: UInt8
        public var minHeight: Int, maxHeight: Int
        public var payloadLength: Int
    }

    public static let headerSize = 32

    public static func header(of data: Data) throws -> Header {
        guard data.count >= headerSize else { throw TileDecodingError.truncated }
        let b = [UInt8](data.prefix(headerSize))
        guard b[0] == 0x50, b[1] == 0x4B, b[2] == 0x54, b[3] == 0x31 else { throw TileDecodingError.badMagic }  // "PKT1"
        func u16(_ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
        func i16(_ i: Int) -> Int { Int(Int16(bitPattern: u16(i))) }
        func u32(_ i: Int) -> UInt32 { UInt32(u16(i)) | UInt32(u16(i + 2)) << 16 }
        func f32(_ i: Int) -> Float { Float(bitPattern: u32(i)) }
        return Header(lat: i16(4), lon: i16(6), rows: Int(u16(8)), cols: Int(u16(10)),
                      scale: f32(12), offset: f32(16), codec: b[20], predictor: b[21], layout: b[22],
                      minHeight: i16(24), maxHeight: i16(26), payloadLength: Int(u32(28)))
    }

    public static func decode(_ data: Data, inflate: Inflate = TileCodec.systemInflate) throws -> ElevationTile {
        let h = try header(of: data)
        guard h.codec == 1 else { throw TileDecodingError.unsupportedCodec(h.codec) }
        guard h.predictor == 1, h.layout == 1 else { throw TileDecodingError.unsupportedLayout }
        guard data.count >= headerSize + h.payloadLength else { throw TileDecodingError.truncated }
        let start = data.startIndex + headerSize
        let payload = data.subdata(in: start..<(start + h.payloadLength))
        let n = h.rows * h.cols
        let planes = try inflate(payload, 2 * n)
        guard planes.count == 2 * n else { throw TileDecodingError.sizeMismatch(expected: 2 * n, got: planes.count) }
        let heights = decodeResidualPlanes([UInt8](planes), rows: h.rows, cols: h.cols, scale: h.scale, offset: h.offset)
        return ElevationTile(id: TileID(lat: h.lat, lon: h.lon), rows: h.rows, cols: h.cols, heights: heights)
    }

    /// Undo byte planes + planar predictor (mod 2^16), then quantisation.
    public static func decodeResidualPlanes(_ p: [UInt8], rows: Int, cols: Int, scale: Float, offset: Float) -> [Int16] {
        let n = rows * cols
        precondition(p.count == 2 * n)
        var q = [UInt16](repeating: 0, count: n)
        q.withUnsafeMutableBufferPointer { q in
            p.withUnsafeBufferPointer { p in
                for r in 0..<rows {
                    let row = r * cols
                    for c in 0..<cols {
                        let i = row + c
                        let res = UInt16(p[i]) << 8 | UInt16(p[n + i])
                        let pred: UInt16
                        if r == 0 {
                            pred = c > 0 ? q[i - 1] : 0
                        } else if c == 0 {
                            pred = q[i - cols]
                        } else {
                            pred = q[i - 1] &+ q[i - cols] &- q[i - cols - 1]
                        }
                        q[i] = res &+ pred
                    }
                }
            }
        }
        if scale == 1, offset == offset.rounded() {
            let off = Int32(offset)
            return q.map { Int16(clamping: Int32($0) + off) }
        }
        return q.map { Int16(clamping: Int(( Float($0) * scale + offset).rounded())) }
    }

    /// Raw DEFLATE via Apple's Compression framework (NSData `.zlib` = RFC 1951 without header).
    public static let systemInflate: Inflate = { data, _ in
        #if canImport(Darwin)
        return try (data as NSData).decompressed(using: .zlib) as Data
        #else
        throw TileDecodingError.unsupportedCodec(1)
        #endif
    }
}
