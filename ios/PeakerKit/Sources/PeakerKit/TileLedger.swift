import Foundation

/// Bookkeeping for the shared on-disk tile store (docs/pack-format.md): which tile files belong to which
/// installed pack, which must be (re)downloaded, and which can be deleted.
///
/// Tiles are shared between packs (neighbouring countries overlap at the border), so a file may only be
/// deleted when no installed pack and no download in progress still uses it. Pure logic, no file access.
public struct TileLedger: Sendable, Equatable {
    /// Tile names per resolution ("90", "30") of each installed pack, by pack code.
    public var installed: [String: [String: Set<String>]] = [:]
    /// Tile names per resolution that downloads in progress need (including ones already on disk).
    public var reserved: [String: [String: Set<String>]] = [:]

    public init() {}

    /// All tiles of a resolution still needed by an installed pack or a running download.
    public func inUse(_ resolution: String) -> Set<String> {
        var out = Set<String>()
        for tiles in installed.values { out.formUnion(tiles[resolution] ?? []) }
        for tiles in reserved.values { out.formUnion(tiles[resolution] ?? []) }
        return out
    }

    /// Tiles to delete when `code` is removed: its tiles that nothing else uses.
    public func removable(after code: String) -> [String: Set<String>] {
        var ledger = self
        let tiles = ledger.installed.removeValue(forKey: code) ?? [:]
        var out: [String: Set<String>] = [:]
        for (resolution, names) in tiles {
            let left = names.subtracting(ledger.inUse(resolution))
            if !left.isEmpty { out[resolution] = left }
        }
        return out
    }

    /// Files on disk that nothing uses, e.g. left behind by a failed download.
    public func orphans(onDisk: [String: Set<String>]) -> [String: Set<String>] {
        var out: [String: Set<String>] = [:]
        for (resolution, names) in onDisk {
            let left = names.subtracting(inUse(resolution))
            if !left.isEmpty { out[resolution] = left }
        }
        return out
    }

}
