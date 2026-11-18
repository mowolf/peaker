import PeakerKit
import SwiftUI

/// Search the peaks visible from here by name; picking one highlights it in the view.
struct PeakSearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
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
                        if query.trimmingCharacters(in: .whitespaces).isEmpty {
                            Text("Most prominent in view")
                        }
                    }
                }
            }
            .overlay { emptyState(isEmpty: matches.isEmpty) }
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
                .foregroundStyle(.tint)
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
