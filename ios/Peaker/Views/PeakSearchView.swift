import PeakerKit
import SwiftUI

/// Search peaks by name: those visible from here first, then the others in the downloaded data ("too far away" /
/// "not visible from here"). Picking one makes it the target: highlighted, or its direction shown at the edge.
struct PeakSearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    /// Matches in the peak data that are not visible from here.
    @State private var others: [PeakInfo] = []
    @FocusState private var searchFocused: Bool

    var body: some View {
        let store = model.horizonStore
        let matches = PeakSearch.search(query, in: store.visiblePeaks, language: model.settings.peakLanguage)
        NavigationStack {
            List {
                if !matches.isEmpty {
                    Section {
                        ForEach(matches) { match in
                            Button { pick(match.visible) } label: { SearchRow(match: match) }
                        }
                    } header: {
                        Text(query.trimmingCharacters(in: .whitespaces).isEmpty ? "Most prominent in view" : "In view")
                    }
                }
                if !others.isEmpty {
                    Section("Not in view") {
                        ForEach(others, id: \.id) { peak in
                            Button { pick(hidden(peak)) } label: { HiddenRow(peak: peak, visible: hidden(peak)) }
                        }
                    }
                }
            }
            .overlay { emptyState(isEmpty: matches.isEmpty && others.isEmpty) }
            .task(id: query) { await searchOthers(excluding: Set(matches.map(\.id))) }
            .navigationTitle("Find a peak")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Peak name")
            .searchFocused($searchFocused)
            .autocorrectionDisabled()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
            }
            .onAppear { searchFocused = true }
        }
    }

    @ViewBuilder
    private func emptyState(isEmpty: Bool) -> some View {
        if isEmpty {
            if model.horizonStore.visiblePeaks.isEmpty {
                ContentUnavailableView("No peaks in view", systemImage: "mountain.2",
                                       description: Text("Peaks appear once the view is computed with offline data for this area."))
            } else {
                ContentUnavailableView.search(text: query)
            }
        }
    }

    /// Matches in all installed peak data that aren't in view (debounced while typing).
    private func searchOthers(excluding visible: Set<String>) async {
        let text = query
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { others = []; return }
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }
        let databases = model.packs.snapshot().peakDatabases
        let inView = Set(model.horizonStore.visiblePeaks.map(\.id)).union(visible)
        let found = await Task.detached(priority: .userInitiated) { PeakDatabase.search(text, in: databases, limit: 30) }.value
        guard !Task.isCancelled else { return }
        others = Array(found.filter { !inView.contains($0.id) }.prefix(15))
    }

    /// A peak that isn't visible, as seen from here (direction and distance; on the horizon).
    private func hidden(_ peak: PeakInfo) -> VisiblePeak {
        let here = model.currentViewpoint ?? peak.coordinate
        return VisiblePeak(peak: peak, azimuth: Geo.bearing(from: here, to: peak.coordinate), altitude: 0,
                           distance: Geo.distance(here, peak.coordinate))
    }

    private func pick(_ peak: VisiblePeak) {
        withAnimation(.smooth) { model.find(peak) }
        dismiss()
    }
}

private struct SearchRow: View {
    @Environment(AppModel.self) private var model
    let match: PeakSearch.Match

    var body: some View {
        let settings = model.settings
        let v = match.visible
        HStack(spacing: 12) {
            Image(systemName: "mountain.2.fill")
                .foregroundStyle(.primary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(match.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                if let alternative = match.matchedAlternative {
                    Text(alternative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(detail(settings: settings, v: v))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            let bearing = Int(v.azimuth.rounded()) % 360
            Text(CompassRibbon.cardinal(bearing))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    private func detail(settings: AppSettings, v: VisiblePeak) -> String {
        var parts: [String] = []
        if let e = v.peak.elevation { parts.append(settings.elevation(e)) }
        parts.append(settings.distance(v.distance))
        return parts.joined(separator: " · ")
    }
}

/// A match that is not in view: why (too far away, or hidden behind terrain), distance and direction.
private struct HiddenRow: View {
    @Environment(AppModel.self) private var model
    let peak: PeakInfo
    let visible: VisiblePeak

    var body: some View {
        let settings = model.settings
        let tooFar = visible.distance > settings.maxDistanceKm * 1000
        HStack(spacing: 12) {
            Image(systemName: "mountain.2")
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(peak.displayName(language: settings.peakLanguage))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text((tooFar ? "Too far away" : "Not visible from here") + " · " + settings.distance(visible.distance))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            let bearing = Int(visible.azimuth.rounded()) % 360
            Text(CompassRibbon.cardinal(bearing))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}
