import Foundation
import PeakerKit
import SQLite3

/// Read-only access to the peak databases of installed packs (docs/pack-format.md).
enum PeakDatabase {
    private static let columns = "p.id, p.name, p.names, p.lat, p.lon, p.ele, p.importance, p.kind, p.wikipedia, p.prominence"

    /// Peaks inside any of the boxes from all databases, de-duplicated by stable ID. One connection per
    /// database for all boxes (`GeoBox.covering` splits areas that cross ±180° into two boxes).
    static func peaks(in databases: [URL], boxes: [GeoBox]) -> [PeakInfo] {
        guard !boxes.isEmpty else { return [] }
        let sql = """
            SELECT \(columns) FROM peaks_rtree r JOIN peaks p ON p.rowid = r.rowid
            WHERE r.min_lat <= ? AND r.max_lat >= ? AND r.min_lon <= ? AND r.max_lon >= ?
            """
        var seen = Set<String>()
        var out: [PeakInfo] = []
        for url in databases {
            withStatement(sql, in: url) { stmt in
                for box in boxes {
                    sqlite3_reset(stmt)
                    sqlite3_bind_double(stmt, 1, box.north)
                    sqlite3_bind_double(stmt, 2, box.south)
                    sqlite3_bind_double(stmt, 3, box.east)
                    sqlite3_bind_double(stmt, 4, box.west)
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        if let p = peak(stmt), seen.insert(p.id).inserted { out.append(p) }
                    }
                }
            }
        }
        return out
    }

    /// Peaks within `radius` metres of a point (boxes are cheap to query; the distance filter is exact).
    static func peaks(near center: GeoCoordinate, radius: Double, in databases: [URL]) -> [PeakInfo] {
        let dLat = radius / 111_320
        let dLon = radius / (111_320 * max(0.01, cos(center.latitude * .pi / 180)))
        let box = GeoBox(south: center.latitude - dLat, north: center.latitude + dLat,
                         west: center.longitude - dLon, east: center.longitude + dLon)
        return peaks(in: databases, boxes: [box]).filter { Geo.distance(center, $0.coordinate) <= radius }
    }

    /// Peaks by stable ID, also found by an older ID (`peak_aliases`, e.g. the OSM ID of a peak that has a
    /// Wikidata item now). Keyed by the ID asked for. One connection per database for all IDs.
    static func peaks(ids: Set<String>, in databases: [URL]) -> [String: PeakInfo] {
        let sql = """
            SELECT \(columns) FROM peaks p
            WHERE p.id = ?1 OR p.id = (SELECT peak_id FROM peak_aliases WHERE alias = ?1) LIMIT 1
            """
        var found: [String: PeakInfo] = [:]
        for url in databases {
            let missing = ids.subtracting(found.keys)
            if missing.isEmpty { break }
            withStatement(sql, in: url) { stmt in
                for id in missing {
                    sqlite3_reset(stmt)
                    sqlite3_bind_text(stmt, 1, id, -1, sqliteTransient)
                    if sqlite3_step(stmt) == SQLITE_ROW, let p = peak(stmt) { found[id] = p }
                }
            }
        }
        return found
    }

    /// Peaks whose name (any language, alternate names) matches `query` word by word as prefixes, accents
    /// ignored; most important first, de-duplicated across databases.
    static func search(_ query: String, in databases: [URL], limit: Int = 40) -> [PeakInfo] {
        guard let match = PeakSearch.ftsQuery(query) else { return [] }
        let sql = """
            SELECT \(columns) FROM peaks_fts f JOIN peaks p ON p.rowid = f.rowid
            WHERE peaks_fts MATCH ? ORDER BY p.importance DESC LIMIT ?
            """
        var seen = Set<String>()
        var out: [PeakInfo] = []
        for url in databases {
            withStatement(sql, in: url) { stmt in
                sqlite3_bind_text(stmt, 1, match, -1, sqliteTransient)
                sqlite3_bind_int(stmt, 2, Int32(limit))
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let p = peak(stmt), seen.insert(p.id).inserted { out.append(p) }
                }
            }
        }
        return Array(out.sorted { $0.importance > $1.importance }.prefix(limit))
    }

    // MARK: - SQLite

    /// SQLite copies bound strings (Swift strings are temporary).
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func withStatement(_ sql: String, in url: URL, _ body: (OpaquePointer) -> Void) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        body(stmt)
    }

    /// The current row (selected with `columns`) as a peak.
    private static func peak(_ stmt: OpaquePointer) -> PeakInfo? {
        func text(_ i: Int32) -> String? {
            guard let c = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: c)
        }
        func double(_ i: Int32) -> Double? {
            sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, i)
        }
        guard let id = text(0), let name = text(1) else { return nil }
        var names: [String: String] = [:]
        if let json = text(2), let data = json.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            names = dict
        }
        return PeakInfo(id: id, name: name, names: names,
                        coordinate: GeoCoordinate(latitude: double(3) ?? 0, longitude: double(4) ?? 0),
                        elevation: double(5), importance: double(6) ?? 0, kind: text(7) ?? "peak",
                        wikipedia: text(8), prominence: double(9))
    }
}
