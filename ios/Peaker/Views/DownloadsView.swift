import PeakerKit
import SwiftUI

/// Offline maps: installed packs and the catalog of downloadable countries.
struct DownloadsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        let packs = model.packs
        NavigationStack {
            List {
                if let here = suggestion {
                    Section("Where you are") {
                        CountryRow(entry: here)
                    }
                }

                Section {
                    ForEach(packs.installed) { pack in
                        InstalledRow(pack: pack)
                            .swipeActions {
                                if !pack.isBundled {
                                    Button("Delete", systemImage: "trash", role: .destructive) {
                                        withAnimation { packs.remove(pack.code) }
                                    }
                                }
                            }
                    }
                } header: {
                    Text("On this iPhone")
                } footer: {
                    if packs.downloadedBytes > 0 {
                        Text("\(ByteCountFormatter.string(fromByteCount: Int64(packs.downloadedBytes), countStyle: .file)) used")
                    }
                }

                if packs.baseURL == nil {
                    Section {
                        ContentUnavailableView("Downloads aren't set up",
                                               systemImage: "icloud.slash",
                                               description: Text("This build has no data server configured. The regions marked \"Included\" work offline."))
                    }
                } else if let error = packs.catalogError, packs.catalog == nil {
                    Section {
                        ContentUnavailableView {
                            Label("Couldn't load countries", systemImage: "wifi.exclamationmark")
                        } description: {
                            Text(error)
                        } actions: {
                            Button("Try again") { Task { await packs.refreshCatalog() } }
                                .buttonStyle(.glassProminent)
                        }
                    }
                } else if packs.catalog == nil {
                    Section { HStack { Spacer(); ProgressView(); Spacer() } }
                } else {
                    Section("Countries") {
                        ForEach(filtered) { entry in
                            CountryRow(entry: entry)
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Search countries")
            .refreshable { await packs.refreshCatalog() }
            .navigationTitle("Offline maps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", systemImage: "checkmark", role: .confirm) { dismiss() }
                }
            }
        }
    }

    private var filtered: [Catalog.CountryEntry] {
        let all = (model.packs.catalog?.countries ?? []).sorted { $0.name < $1.name }
        guard !search.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.code.localizedCaseInsensitiveContains(search) }
    }

    private var suggestion: Catalog.CountryEntry? {
        guard search.isEmpty, !model.isUsingDemoViewpoint, let c = model.horizonStore.observer else { return nil }
        return model.packs.suggestedCountries(near: c).first { !model.packs.isDownloaded($0.code) }
    }
}

private struct InstalledRow: View {
    @Environment(AppModel.self) private var model
    let pack: InstalledPack

    var body: some View {
        HStack(spacing: 12) {
            Text(pack.isBundled && pack.code.count != 2 ? "🏔️" : flag(pack.code))
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(pack.name)
                    .font(.body.weight(.medium))
                Text("\(pack.peakCount.formatted()) peaks · \(ByteCountFormatter.string(fromByteCount: Int64(pack.bytes), countStyle: .file))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if pack.isBundled {
                Text("Included")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }
}

private struct CountryRow: View {
    @Environment(AppModel.self) private var model
    let entry: Catalog.CountryEntry

    /// 90 m + 30 m tiles (each catalog size includes the peak DB once; good enough as an estimate).
    private var downloadSize: Int { (entry.bytes["90"] ?? 0) + (entry.bytes["30"] ?? 0) }

    private var summary: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(downloadSize), countStyle: .file)
        var parts: [String] = ["\(entry.peaks.formatted()) peaks", size]
        if entry.tiles["30"] != nil { parts.append("high detail") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let packs = model.packs
        let state = packs.downloads[entry.code]
        HStack(spacing: 12) {
            Text(flag(entry.code))
                .font(.title2)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.name)
                    .font(.body.weight(.medium))
                if let state, state.error == nil {
                    ProgressView(value: state.fraction)
                        .tint(.accentColor)
                } else if let error = state?.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if packs.isDownloaded(entry.code) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if let state, state.error == nil {
                Text(state.fraction, format: .percent.precision(.fractionLength(0)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    packs.clearError(entry.code)
                    Task { await packs.install(entry) }
                } label: {
                    Image(systemName: state?.error == nil ? "arrow.down" : "arrow.clockwise")
                        .font(.body.weight(.semibold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Download \(entry.name)")
            }
        }
    }
}

/// Regional indicator emoji for an ISO 3166-1 alpha-2 code.
func flag(_ code: String) -> String {
    var result = ""
    for scalar in code.uppercased().unicodeScalars {
        let value: UInt32 = 127_397 + scalar.value
        if let flagScalar = Unicode.Scalar(value) {
            result.unicodeScalars.append(flagScalar)
        }
    }
    return result
}
