import Foundation
import Observation

enum UnitSystem: String, CaseIterable, Identifiable {
    case metric, imperial
    var id: String { rawValue }
    var title: String { self == .metric ? "Metric (m, km)" : "Imperial (ft, mi)" }
}

enum LabelDensity: String, CaseIterable, Identifiable {
    case few, normal, many
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var maxLabels: Int { switch self { case .few: 12; case .normal: 25; case .many: 45 } }
    var minImportance: Double { switch self { case .few: 0.55; case .normal: 0.35; case .many: 0.0 } }
}

/// User settings, persisted in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    private let defaults = UserDefaults.standard

    var maxDistanceKm: Double { didSet { defaults.set(maxDistanceKm, forKey: "maxDistanceKm") } }
    var eyeHeight: Double { didSet { defaults.set(eyeHeight, forKey: "eyeHeight") } }
    var units: UnitSystem { didSet { defaults.set(units.rawValue, forKey: "units") } }
    var labelDensity: LabelDensity { didSet { defaults.set(labelDensity.rawValue, forKey: "labelDensity") } }
    /// ID of a fixed viewpoint (see `Viewpoint.all`); empty = use GPS.
    var fixedViewpointID: String { didSet { defaults.set(fixedViewpointID, forKey: "fixedViewpointID") } }
    /// Country downloads may use mobile data (and Low Data Mode); off = Wi-Fi only.
    var allowsMobileDataDownloads: Bool {
        didSet { defaults.set(allowsMobileDataDownloads, forKey: "allowsMobileDataDownloads") }
    }

    init() {
        maxDistanceKm = defaults.object(forKey: "maxDistanceKm") as? Double ?? 200
        eyeHeight = defaults.object(forKey: "eyeHeight") as? Double ?? 1.8
        units = UnitSystem(rawValue: defaults.string(forKey: "units") ?? "") ?? .metric
        labelDensity = LabelDensity(rawValue: defaults.string(forKey: "labelDensity") ?? "") ?? .normal
        fixedViewpointID = defaults.string(forKey: "fixedViewpointID") ?? ""
        allowsMobileDataDownloads = defaults.bool(forKey: "allowsMobileDataDownloads")  // default false
    }

    /// Language for peak names: the device's language (OSM/Wikidata `name:<code>`).
    var peakLanguage: String? { Locale.current.language.languageCode?.identifier }

    func elevation(_ metres: Double) -> String {
        units == .metric
            ? "\(Int(metres.rounded())) m"
            : "\(Int((metres / 0.3048).rounded())) ft"
    }

    func distance(_ metres: Double) -> String {
        if units == .metric {
            return metres < 10_000 ? String(format: "%.1f km", metres / 1000) : "\(Int((metres / 1000).rounded())) km"
        }
        let miles = metres / 1609.344
        return miles < 10 ? String(format: "%.1f mi", miles) : "\(Int(miles.rounded())) mi"
    }
}
