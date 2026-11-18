import PeakerKit
import SwiftUI

struct PeakDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let visible: VisiblePeak

    var body: some View {
        let peak = visible.peak
        let settings = model.settings
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(peak.displayName(language: model.settings.peakLanguage))
                            .font(.largeTitle.bold())
                        if !otherNames.isEmpty {
                            Text(otherNames.joined(separator: " · "))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Text(String(format: "%.5f°, %.5f°", peak.coordinate.latitude, peak.coordinate.longitude))
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    PeakBookSection(peak: peak)

                    if peak.elevation != nil || (peak.prominence ?? 0) > 0 {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                            if let e = peak.elevation {
                                Stat(title: "Elevation", value: settings.elevation(e), icon: "mountain.2")
                            }
                            if let p = peak.prominence, p > 0 {
                                Stat(title: "Prominence", value: settings.elevation(p), icon: "chart.line.uptrend.xyaxis")
                            }
                        }
                    }

                    FinderRow(visible: visible) {
                        model.findInPeakFinder(visible)
                        dismiss()
                    }

                    if let url = wikipediaURL {
                        Link(destination: url) {
                            Label("Wikipedia", systemImage: "book")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                    }
                }
                .padding(20)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close", systemImage: "xmark", role: .close) { dismiss() }
                }
            }
        }
    }

    private var otherNames: [String] {
        let shown: String = visible.peak.displayName(language: model.settings.peakLanguage)
        var seen: Set<String> = [shown]
        var candidates: [String] = [visible.peak.name]
        for language in ["local", "de", "fr", "it", "en"] {
            if let n = visible.peak.names[language] { candidates.append(n) }
        }
        var result: [String] = []
        for name in candidates where seen.insert(name).inserted {
            result.append(name)
        }
        return result
    }

    private var wikipediaURL: URL? {
        guard let w = visible.peak.wikipedia, let colon = w.firstIndex(of: ":") else { return nil }
        let lang = w[..<colon], title = w[w.index(after: colon)...].replacingOccurrences(of: " ", with: "_")
        return URL(string: "https://\(lang).wikipedia.org/wiki/\(title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? title)")
    }
}

private struct Stat: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}

/// Distance and bearing from where you are, and a button to find the peak in the peak finder.
private struct FinderRow: View {
    @Environment(AppModel.self) private var model
    let visible: VisiblePeak
    let onFind: () -> Void

    var body: some View {
        let bearing = Int(visible.azimuth.rounded()) % 360
        HStack(spacing: 16) {
            Label(model.settings.distance(visible.distance), systemImage: "point.topleft.down.to.point.bottomright.curvepath")
            Label("\(bearing)° \(CompassRibbon.cardinal(bearing))", systemImage: "location.north.line")
            Spacer(minLength: 8)
            Button(action: onFind) {
                Image(systemName: "binoculars.fill")
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                    .glassEffect(.regular, in: .circle)
            }
            .buttonStyle(PressScaleStyle())
            .accessibilityLabel("Find in the peak finder")
        }
        .font(.subheadline.monospacedDigit())
        .foregroundStyle(.secondary)
    }
}
