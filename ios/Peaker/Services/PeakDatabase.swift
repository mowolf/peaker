import Foundation
import PeakerKit
import SQLite3

/// Read-only access to the peak databases of installed packs (docs/pack-format.md).
enum PeakDatabase {
    /// Peaks within `radius` metres (bounding box) from all databases, de-duplicated by stable ID.
    static func peaks(in databases: [URL], center: GeoCoordinate, radius: Double) -> [PeakInfo] {
        let dLat = radius / 111_320
        let dLon = radius / (111_320 * max(cos(center.latitude * Double.pi / 180.0), 0.05))
        return peaks(in: databases, south: center.latitude - dLat, north: center.latitude + dLat,
                     west: center.longitude - dLon, east: center.longitude + dLon)
    }

    /// Peaks inside a lat/lon box from all databases, de-duplicated by stable ID.
    static func peaks(in databases: [URL], south: Double, north: Double, west: Double, east: Double) -> [PeakInfo] {
        var seen = Set<String>()
        var out: [PeakInfo] = []
        for url in databases {
            for p in query(url, south: south, north: north, west: west, east: east) where seen.insert(p.id).inserted {
                out.append(p)
            }
        }
        return out
    }

    private static func query(_ url: URL, south: Double, north: Double, west: Double, east: Double) -> [PeakInfo] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }
        let sql = """
            SELECT p.id, p.name, p.names, p.lat, p.lon, p.ele, p.importance, p.kind, p.wikipedia, p.prominence
            FROM peaks_rtree r JOIN peaks p ON p.rowid = r.rowid
            WHERE r.min_lat <= ? AND r.max_lat >= ? AND r.min_lon <= ? AND r.max_lon >= ?
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, north)
        sqlite3_bind_double(stmt, 2, south)
        sqlite3_bind_double(stmt, 3, east)
        sqlite3_bind_double(stmt, 4, west)

        func text(_ i: Int32) -> String? {
            guard let c = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: c)
        }
        func double(_ i: Int32) -> Double? {
            sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, i)
        }

        var out: [PeakInfo] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let id = text(0), let name = text(1) else { continue }
            var names: [String: String] = [:]
            if let json = text(2), let data = json.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                names = dict
            }
            out.append(PeakInfo(id: id, name: name, names: names,
                                coordinate: GeoCoordinate(latitude: double(3) ?? 0, longitude: double(4) ?? 0),
                                elevation: double(5), importance: double(6) ?? 0, kind: text(7) ?? "peak",
                                wikipedia: text(8), prominence: double(9)))
        }
        return out
    }
}
