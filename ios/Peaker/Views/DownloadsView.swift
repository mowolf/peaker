import PeakerKit
import SwiftUI

/// Offline maps: installed packs and the catalog of downloadable countries.
struct DownloadsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    // Sections are separate properties: one big body took Xcode > 300 ms to type-check.
    var body: some View {
        NavigationStack {
            List {
                if let here = suggestion {
                    Section("Where you are") {
                        CountryRow(entry: here)
                    }
                }
                installedSection
                catalogSection
            }
            .searchable(text: $search, prompt: "Search countries")
            .refreshable { await model.packs.refreshCatalog() }
            .navigationTitle("Offline maps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", systemImage: "checkmark", role: .confirm) { dismiss() }
                }
            }
        }
    }

    private var installedSection: some View {
        let packs = model.packs
        return Section {
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
    }

    @ViewBuilder
    private var catalogSection: some View {
        let packs = model.packs
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

    private var summary: String {
        var parts: [String] = ["\(entry.peaks.formatted()) peaks", formattedSize(entry.downloadSize)]
        if entry.tiles["30"] != nil { parts.append("high detail") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let state = model.packs.downloads[entry.code]
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
            CountryRowAction(entry: entry, state: state)
        }
    }
}

/// Checkmark, progress with cancel, or the download button with its confirmation.
private struct CountryRowAction: View {
    @Environment(AppModel.self) private var model
    let entry: Catalog.CountryEntry
    let state: DownloadState?
    @State private var confirming = false

    var body: some View {
        let packs = model.packs
        if packs.isDownloaded(entry.code) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else if let state, state.error == nil {
            Text(state.fraction, format: .percent.precision(.fractionLength(0)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            RoundButton(icon: "xmark", label: "Cancel download of \(entry.name)") {
                packs.cancelInstall(entry.code)
            }
        } else {
            RoundButton(icon: state?.error == nil ? "arrow.down" : "arrow.clockwise",
                        label: "Download \(entry.name)") {
                confirming = true
            }
            .confirmationDialog("Download \(entry.name)?", isPresented: $confirming, titleVisibility: .visible) {
                DownloadChoices(entry: entry)
            } message: {
                Text(confirmationMessage)
            }
        }
    }

    /// Size first, then what the current connection means for this download.
    private var confirmationMessage: String {
        let size = "Up to \(formattedSize(entry.downloadSize)) (parts already on this iPhone are skipped)."
        let network = model.network
        let note: String
        if !network.isConnected {
            note = "You're offline right now."
        } else if network.isUnmetered {
            note = "Downloads over Wi-Fi."
        } else if model.settings.allowsMobileDataDownloads {
            note = "This uses mobile data."
        } else {
            note = "You're on mobile data or in Low Data Mode, and downloads over mobile data are off in Settings."
        }
        return size + "\n" + note
    }
}

/// Buttons of the download confirmation.
private struct DownloadChoices: View {
    @Environment(AppModel.self) private var model
    let entry: Catalog.CountryEntry

    var body: some View {
        let packs = model.packs
        let onMobileData = model.network.isConnected && !model.network.isUnmetered
        if onMobileData && !model.settings.allowsMobileDataDownloads {
            // Wi-Fi only, but not on Wi-Fi: offer a one-time exception instead of a button that would just fail.
            Button("Download Using Mobile Data") {
                packs.clearError(entry.code)
                packs.startInstall(entry, allowsMobileData: true)
            }
        } else {
            Button("Download") {
                packs.clearError(entry.code)
                packs.startInstall(entry, allowsMobileData: model.settings.allowsMobileDataDownloads)
            }
        }
        Button("Cancel", role: .cancel) {}
    }
}

private struct RoundButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel(label)
    }
}

private func formattedSize(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}

private extension Catalog.CountryEntry {
    /// 90 m + 30 m tiles. Each catalog size includes the peak database, so this slightly over-counts:
    /// fine for an "up to" estimate.
    var downloadSize: Int { (bytes["90"] ?? 0) + (bytes["30"] ?? 0) }
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
