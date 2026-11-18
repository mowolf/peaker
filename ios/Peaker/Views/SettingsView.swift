import PeakerKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showsOfflineData = false

    var body: some View {
        @Bindable var settings = model.settings
        NavigationStack {
            Form {
                Section {
                    Button { showsOfflineData = true } label: {
                        OfflineDataRow()
                    }
                    .foregroundStyle(.primary)
                }

                Section {
                    VStack(alignment: .leading) {
                        LabeledContent("View distance", value: model.settings.distance(settings.maxDistanceKm * 1000))
                        Slider(value: $settings.maxDistanceKm, in: 50...300, step: 25)
                    }
                    Picker("Labels", selection: $settings.labelDensity) {
                        ForEach(LabelDensity.allCases) { Text($0.title).tag($0) }
                    }
                    Stepper(value: $settings.eyeHeight, in: 0...50, step: 0.5) {
                        LabeledContent("Eye height", value: model.settings.elevation(settings.eyeHeight))
                    }
                } header: {
                    Text("View")
                } footer: {
                    Text("Ridges further away than the view distance aren't drawn. Longer distances take a little longer to compute.")
                }

                Section {
                    Toggle("Use mobile data", isOn: $settings.allowsMobileDataDownloads)
                } header: {
                    Text("Downloads")
                } footer: {
                    Text("Off: countries download only over Wi-Fi (not over mobile data, a personal hotspot or in Low Data Mode). Countries are often several hundred MB. You can still allow mobile data for a single download.")
                }

                Section {
                    Picker("Style", selection: $settings.mapStyle) {
                        ForEach(MapStyleChoice.allCases) { Text($0.title).tag($0) }
                    }
                    VStack(alignment: .leading) {
                        LabeledContent("Height exaggeration", value: String(format: "%.1f×", settings.mapExaggeration))
                        Slider(value: $settings.mapExaggeration, in: 1...2, step: 0.1)
                    }
                } header: {
                    Text("Map")
                } footer: {
                    Text("Exaggerated heights make the relief easier to read from far away; 1× is true to scale.")
                }

                Section("Units") {
                    Picker("Units", selection: $settings.units) {
                        ForEach(UnitSystem.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section {
                    // Through `choose`, like the viewpoint menu: turns the view towards the famous view, or
                    // starts GPS for "My location".
                    Picker("Viewpoint", selection: Binding(get: { model.settings.fixedViewpointID },
                                                           set: { model.choose(Viewpoint.with(id: $0)) })) {
                        Text("My location (GPS)").tag("")
                        ForEach(Viewpoint.all) { v in
                            Text("\(v.name) · \(v.region)").tag(v.id)
                        }
                    }
                } header: {
                    Text("Viewpoint")
                } footer: {
                    Text("Famous viewpoints to try Peaker from anywhere. They need the country's offline data: Switzerland for Gornergrat, Nepal for Kala Patthar and Poon Hill.")
                }

                Section("About") {
                    LabeledContent("Version", value: appVersion)
                    LabeledContent("Data server", value: model.packs.baseURL?.host() ?? "Not configured")
                    NavigationLink("Data sources & licences") { LicensesView() }
                }
            }
            .sheet(isPresented: $showsOfflineData) {
                DownloadsView()
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", systemImage: "checkmark", role: .confirm) { dismiss() }
                }
            }
        }
    }

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }
}

/// "Manage offline data" with what's on the iPhone; opens the offline maps card.
private struct OfflineDataRow: View {
    @Environment(AppModel.self) private var model

    private var summary: String {
        let packs = model.packs
        let downloaded = packs.installed.count
        guard downloaded > 0 else { return "No countries downloaded yet" }
        let size = ByteCountFormatter.string(fromByteCount: Int64(packs.downloadedBytes), countStyle: .file)
        return "\(downloaded) \(downloaded == 1 ? "country" : "countries") · \(size)"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Manage offline data")
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(.rect)
    }
}

struct LicensesView: View {
    @Environment(AppModel.self) private var model

    private static let builtIn: [Catalog.Attribution] = [
        .init(name: "Copernicus DEM",
              text: "© DLR e.V. 2010-2014 and © Airbus Defence and Space GmbH 2014-2018 provided under COPERNICUS by the European Union and ESA; all rights reserved",
              url: "https://spacedata.copernicus.eu/collections/copernicus-digital-elevation-model"),
        .init(name: "OpenStreetMap", text: "© OpenStreetMap contributors, ODbL 1.0", url: "https://www.openstreetmap.org/copyright"),
        .init(name: "Wikidata", text: "Wikidata, CC0", url: "https://www.wikidata.org"),
        .init(name: "GeoNames", text: "GeoNames, CC BY 4.0", url: "https://www.geonames.org"),
        .init(name: "Natural Earth", text: "Made with Natural Earth (public domain)", url: "https://www.naturalearthdata.com"),
    ]

    var body: some View {
        List(model.packs.catalog?.attribution ?? Self.builtIn, id: \.name) { a in
            VStack(alignment: .leading, spacing: 6) {
                Text(a.name).font(.headline)
                Text(a.text).font(.footnote).foregroundStyle(.secondary)
                if let url = URL(string: a.url) {
                    Link(a.url, destination: url).font(.footnote)
                }
            }
            .padding(.vertical, 4)
        }
        .navigationTitle("Data sources")
    }
}
