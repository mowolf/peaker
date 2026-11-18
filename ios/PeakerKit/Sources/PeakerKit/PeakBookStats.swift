import Foundation

/// Numbers for the peak book: distinct peaks climbed, the highest, per year.
public struct PeakBookStats: Sendable, Equatable {
    /// Distinct peaks with at least one `summited` entry.
    public var peaksClimbed: Int
    /// Summits in total (a peak climbed twice counts twice).
    public var summits: Int
    /// The highest climbed peak with a known elevation.
    public var highest: PeakEntry.Peak?
    /// Distinct peaks climbed per year, for the years with any.
    public var peaksPerYear: [Int: Int]
    /// Distinct peaks on the wishlist and not climbed yet.
    public var wishlist: Int

    /// - Parameter entries: each entry with the resolved peak IDs of its peaks (same order, nil: not found).
    public init(_ entries: [(entry: PeakEntry, resolvedIDs: [String?])]) {
        var climbed = Set<String>()
        var perYear: [Int: Set<String>] = [:]
        var planned = Set<String>()
        var summits = 0
        var highest: PeakEntry.Peak?
        for (entry, resolved) in entries {
            for (i, peak) in entry.peaks.enumerated() {
                let key = Self.key(peak, resolved: i < resolved.count ? resolved[i] : nil)
                switch entry.status {
                case .summited:
                    climbed.insert(key)
                    summits += 1
                    if let year = entry.date?.year { perYear[year, default: []].insert(key) }
                    if let e = peak.elevation, e > (highest?.elevation ?? -.infinity) { highest = peak }
                case .planned:
                    planned.insert(key)
                case .attempted:
                    break
                }
            }
        }
        peaksClimbed = climbed.count
        self.summits = summits
        self.highest = highest
        peaksPerYear = perYear.mapValues(\.count)
        wishlist = planned.subtracting(climbed).count
    }

    /// The same peak in different entries: resolved ID, else the written ID, else the name.
    private static func key(_ peak: PeakEntry.Peak, resolved: String?) -> String {
        resolved ?? peak.id ?? "name:" + (peak.name ?? "").lowercased()
    }
}
