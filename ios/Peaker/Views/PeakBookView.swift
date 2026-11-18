import PeakerKit
import SwiftUI

/// The peak book: climbed peaks by year with statistics, and the wishlist. Entries open in the editor.
struct PeakBookView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    enum Tab: Hashable { case climbed, wishlist }

    @State private var tab = Tab.climbed
    @State private var query = ""
    @State private var path: [String] = []
    @State private var pendingDelete: StoredEntry?
    @State private var error: String?

    var body: some View {
        NavigationStack(path: $path) {
            list
                .overlay { emptyState(isEmpty: shownEntries.isEmpty) }
                .navigationTitle("Peak book")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $query, prompt: "Peaks, notes, companions")
                .safeAreaInset(edge: .top) { tabPicker }
                .toolbar { toolbar }
                .navigationDestination(for: String.self) { editor(for: $0) }
                .modifier(DeleteConfirmation(pendingDelete: $pendingDelete, error: $error))
                .task { await model.peakBook.reload() }  // pick up edits made in the Files app
        }
    }

    // Parts of `body`, kept apart: as one expression it took Xcode over a second to type-check.

    private var shownEntries: [StoredEntry] { filtered(model.peakBook.entries) }

    private var list: some View {
        let book = model.peakBook
        return List {
            if tab == .climbed && query.isEmpty && !book.entries.isEmpty {
                Section {
                    StatsCard(stats: PeakBookStats(book.entries.map { ($0.entry, $0.resolvedIDs) }))
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
            ForEach(sections(shownEntries), id: \.title) { section in
                Section(section.title) {
                    ForEach(section.entries) { stored in
                        NavigationLink(value: stored.fileName) { BookRow(stored: stored) }
                            .swipeActions {
                                Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = stored }
                            }
                    }
                }
            }
        }
    }

    private var tabPicker: some View {
        Picker("Show", selection: $tab) {
            Text("Climbed").tag(Tab.climbed)
            Text("Wishlist").tag(Tab.wishlist)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Close", systemImage: "xmark") { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
            Button("New Entry", systemImage: "square.and.pencil", action: newEntry)
        }
    }

    @ViewBuilder
    private func editor(for fileName: String) -> some View {
        if let stored = model.peakBook.entries.first(where: { $0.fileName == fileName }) {
            EntryEditorView(stored: stored)
        } else {
            ContentUnavailableView("Entry not found", systemImage: "doc.questionmark",
                                   description: Text("It was deleted or renamed in the Files app."))
        }
    }

    // MARK: Content

    private struct BookSection {
        var title: String
        var entries: [StoredEntry]
    }

    /// Wishlist: linked entries marked planned. Climbed: everything else, by year (newest first).
    private func filtered(_ entries: [StoredEntry]) -> [StoredEntry] {
        entries.filter { stored in
            let wish = stored.entry.status == .planned && stored.entry.isLinked
            guard (tab == .wishlist) == wish else { return false }
            return query.isEmpty || matches(stored, query)
        }
    }

    private func sections(_ entries: [StoredEntry]) -> [BookSection] {
        if tab == .wishlist {
            return entries.isEmpty ? [] : [BookSection(title: "To climb", entries: entries)]
        }
        var byYear: [Int: [StoredEntry]] = [:]
        var undated: [StoredEntry] = []
        for stored in entries {
            if let year = stored.entry.date?.year { byYear[year, default: []].append(stored) } else { undated.append(stored) }
        }
        var out = byYear.keys.sorted(by: >).map { BookSection(title: String($0), entries: byYear[$0] ?? []) }
        if !undated.isEmpty { out.append(BookSection(title: "Other notes", entries: undated)) }
        return out
    }

    private func matches(_ stored: StoredEntry, _ query: String) -> Bool {
        let e = stored.entry
        let haystack = ([stored.fileName, e.body] + e.peaks.map(\.displayName) + e.companions).joined(separator: "\n")
        return haystack.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    @ViewBuilder
    private func emptyState(isEmpty: Bool) -> some View {
        if isEmpty {
            if !query.isEmpty {
                ContentUnavailableView.search(text: query)
            } else if tab == .climbed {
                ContentUnavailableView("No climbs yet", systemImage: "mountain.2",
                                       description: Text("Tap a peak in the view and choose “Mark as climbed”, or write a new entry."))
            } else {
                ContentUnavailableView("Wishlist is empty", systemImage: "star",
                                       description: Text("Tap a peak in the view and add it to your wishlist."))
            }
        }
    }

    private func newEntry() {
        let entry = tab == .wishlist
            ? PeakEntry(date: nil, status: .planned, peaks: [])
            : PeakEntry(date: DayDate(Date()), status: .summited, peaks: [])
        do {
            let stored = try model.peakBook.create(entry, resolvedIDs: [])
            path.append(stored.fileName)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Asks before deleting an entry (swipe action); shows write errors.
private struct DeleteConfirmation: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var pendingDelete: StoredEntry?
    @Binding var error: String?

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Delete this entry?", isPresented: Binding(get: { pendingDelete != nil },
                                                                           set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible, presenting: pendingDelete) { stored in
                Button("Delete", role: .destructive) { delete(stored) }
            } message: { stored in
                Text("\(stored.fileName) will be deleted, with all its notes.")
            }
            .alert("Couldn't save", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(error ?? "")
            }
    }

    private func delete(_ stored: StoredEntry) {
        do {
            try withAnimation { try model.peakBook.delete(stored) }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// One entry in the list: status, peaks, date or title, companions.
private struct BookRow: View {
    @Environment(AppModel.self) private var model
    let stored: StoredEntry

    var body: some View {
        let entry = stored.entry
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(peaksText).font(.body.weight(.semibold)).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if !entry.companions.isEmpty {
                    Label(entry.companions.joined(separator: ", "), systemImage: "person.2")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let e = entry.peaks.compactMap(\.elevation).max() {
                Text(model.settings.elevation(e))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var peaksText: String {
        let names = stored.entry.peaks.map(\.displayName)
        if names.isEmpty { return stored.entry.title ?? stored.fileName.replacingOccurrences(of: ".md", with: "") }
        return names.joined(separator: " · ")
    }

    private var subtitle: String {
        var parts: [String] = []
        if let date = stored.entry.date?.noon { parts.append(date.formatted(date: .abbreviated, time: .omitted)) }
        if stored.entry.status == .attempted { parts.append("Attempted") }
        if let title = stored.entry.title, title != peaksText { parts.append(title) }
        return parts.isEmpty ? (stored.entry.isLinked ? "No notes yet" : "Not linked to a peak") : parts.joined(separator: " · ")
    }

    private var icon: String {
        switch stored.entry.status {
        case .summited: "checkmark.circle.fill"
        case .attempted: "arrow.uturn.down.circle"
        case .planned: stored.entry.isLinked ? "star.fill" : "doc.text"
        }
    }

    private var color: Color {
        switch stored.entry.status {
        case .summited: .green
        case .attempted: .orange
        case .planned: stored.entry.isLinked ? .yellow : .secondary
        }
    }
}

/// Peaks climbed, summits, highest peak, this year.
private struct StatsCard: View {
    @Environment(AppModel.self) private var model
    let stats: PeakBookStats

    var body: some View {
        let year = Calendar.current.component(.year, from: Date())
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            tile("Peaks climbed", "\(stats.peaksClimbed)", icon: "mountain.2.fill")
            tile("In \(String(year))", "\(stats.peaksPerYear[year] ?? 0)", icon: "calendar")
            tile("Summits", "\(stats.summits)", icon: "flag.fill")
            if let highest = stats.highest, let e = highest.elevation {
                tile("Highest", model.settings.elevation(e), icon: "arrow.up.to.line", detail: highest.displayName)
            } else {
                tile("Wishlist", "\(stats.wishlist)", icon: "star.fill")
            }
        }
        .padding(.vertical, 4)
    }

    private func tile(_ title: String, _ value: String, icon: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold).monospacedDigit())
            if let detail {
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}
