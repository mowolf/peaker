import PeakerKit
import SwiftUI
import UIKit

/// Edit one peak book entry: status, date, peaks, companions and the Markdown text. Saves as you type.
///
/// While open, saves keep the file name (the list and navigation refer to the entry by it); the file is renamed
/// to match the entry, if the app named it, when the editor closes.
struct EntryEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// The entry as opened: its file name was given for this content.
    private let opened: StoredEntry
    @State private var stored: StoredEntry
    @State private var entry: PeakEntry
    @State private var companions: String
    @State private var selection: TextSelection?
    @State private var showsPreview = false
    @State private var showsPeakPicker = false
    @State private var confirmsDelete = false
    @State private var isDeleted = false
    @State private var error: String?

    init(stored: StoredEntry) {
        opened = stored
        _stored = State(initialValue: stored)
        _entry = State(initialValue: stored.entry)
        _companions = State(initialValue: stored.entry.companions.joined(separator: ", "))
    }

    var body: some View {
        Form {
            detailsSection
            peaksSection
            Section("Companions") {
                TextField("Names, separated by commas", text: $companions)
                    .textContentType(.name)
            }
            notesSection
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .sheet(isPresented: $showsPeakPicker) {
            PeakPickerView { peak in
                if !entry.peaks.contains(peak) { entry.peaks.append(peak) }
            }
        }
        .confirmationDialog("Delete this entry?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive, action: delete)
        } message: {
            Text("\(stored.fileName) will be deleted, with all its notes.")
        }
        .alert("Couldn't save", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
        .onChange(of: companions) {
            entry.companions = companions.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        // Save shortly after each change (typing goes on in the meantime), and when leaving.
        .task(id: entry) {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            save(rename: false)
        }
        .onDisappear { save(rename: true) }
    }

    private var navigationTitle: String {
        entry.peaks.first?.displayName ?? (entry.status == .planned ? "Wishlist" : "Entry")
    }

    // MARK: Sections

    private var detailsSection: some View {
        Section {
            Picker("Status", selection: statusBinding) {
                Text("Climbed").tag(PeakEntry.Status.summited)
                Text("Attempted").tag(PeakEntry.Status.attempted)
                Text("Wishlist").tag(PeakEntry.Status.planned)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            if entry.status == .planned {
                Toggle("Planned date", isOn: Binding(get: { entry.date != nil },
                                                     set: { entry.date = $0 ? DayDate(Date()) : nil }))
                if entry.date != nil {
                    DatePicker("Date", selection: dateBinding, displayedComponents: .date)
                }
            } else {
                DatePicker("Date", selection: dateBinding, in: ...Date(), displayedComponents: .date)
            }
        }
    }

    private var peaksSection: some View {
        Section {
            ForEach(Array(entry.peaks.enumerated()), id: \.offset) { _, peak in
                HStack {
                    Image(systemName: "mountain.2.fill").foregroundStyle(.tint)
                    Text(peak.displayName)
                    Spacer()
                    if let e = peak.elevation {
                        Text(model.settings.elevation(e)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            .onDelete { entry.peaks.remove(atOffsets: $0) }
            Button("Add peak", systemImage: "plus") { showsPeakPicker = true }
        } header: {
            Text("Peaks")
        } footer: {
            if entry.peaks.isEmpty {
                Text("Link the entry to the peaks of the outing; they get a mark in the view.")
            }
        }
    }

    private var notesSection: some View {
        Section {
            if showsPreview {
                if entry.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Nothing written yet.").foregroundStyle(.secondary)
                } else {
                    MarkdownPreview(text: entry.body)
                        .padding(.vertical, 6)
                }
            } else {
                TextEditor(text: $entry.body, selection: $selection)
                    .frame(minHeight: 260)
                    .font(.body)
            }
        } header: {
            HStack {
                Text("Notes")
                Spacer()
                Picker("Mode", selection: $showsPreview) {
                    Text("Edit").tag(false)
                    Text("Preview").tag(true)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
        } footer: {
            Text("Markdown: # heading, **bold**, *italic*, - list. Also editable in the Files app (\(stored.fileName)).")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Delete Entry", systemImage: "trash", role: .destructive) { confirmsDelete = true }
            } label: {
                Image(systemName: "ellipsis")
            }
        }
        ToolbarItemGroup(placement: .keyboard) {
            Button("Heading", systemImage: "number") { apply { Markdown.toggleLinePrefix($0, selection: $1, prefix: "# ") } }
            Button("Bold", systemImage: "bold") { apply { Markdown.toggleWrap($0, selection: $1, marker: "**") } }
            Button("Italic", systemImage: "italic") { apply { Markdown.toggleWrap($0, selection: $1, marker: "*") } }
            Button("List", systemImage: "list.bullet") { apply { Markdown.toggleLinePrefix($0, selection: $1, prefix: "- ") } }
            Spacer()
            Button("Done") { hideKeyboard() }
                .fontWeight(.semibold)
        }
    }

    // MARK: Bindings

    /// Switching to Climbed/Attempted needs a date (today if there was none).
    private var statusBinding: Binding<PeakEntry.Status> {
        Binding(get: { entry.status }, set: { status in
            entry.status = status
            if status != .planned, entry.date == nil { entry.date = DayDate(Date()) }
        })
    }

    private var dateBinding: Binding<Date> {
        Binding(get: { entry.date?.noon ?? Date() }, set: { entry.date = DayDate($0) })
    }

    // MARK: Text edits

    /// Run a toolbar edit on the text and selection (as character offsets).
    private func apply(_ edit: (String, Range<Int>) -> Markdown.Edit) {
        let text = entry.body
        var range = text.count..<text.count
        if let selection, case .selection(let r) = selection.indices,
           r.lowerBound >= text.startIndex, r.upperBound <= text.endIndex {
            range = text.distance(from: text.startIndex, to: r.lowerBound)..<text.distance(from: text.startIndex, to: r.upperBound)
        }
        let result = edit(text, range)
        entry.body = result.text
        let t = result.text
        let lower = t.index(t.startIndex, offsetBy: min(result.selection.lowerBound, t.count))
        let upper = t.index(t.startIndex, offsetBy: min(result.selection.upperBound, t.count))
        selection = TextSelection(range: lower..<upper)
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    // MARK: Saving

    private func save(rename: Bool) {
        guard !isDeleted else { return }
        // Nothing to write unless the entry changed or its app-given name no longer fits.
        let renames = rename && opened.entry.hasAutomaticName(stored.fileName) && !entry.hasAutomaticName(stored.fileName)
        guard entry != stored.entry || renames else { return }
        do {
            stored = try model.peakBook.save(stored, as: entry, rename: rename, namedAfter: opened.entry)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete() {
        do {
            try model.peakBook.delete(stored)
            isDeleted = true
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Renders the blocks the editor's Markdown uses; inline formatting via `AttributedString`.
struct MarkdownPreview: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Markdown.blocks(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, level <= 2 ? 4 : 0)
        case .paragraph(let text):
            Text(Self.inline(text))
        case .listItem(let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker).foregroundStyle(.secondary).monospacedDigit()
                Text(Self.inline(text))
            }
        case .quote(let text):
            Text(Self.inline(text))
                .italic()
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Capsule().fill(.tint).frame(width: 3)
                }
        case .rule:
            Divider()
        }
    }

    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// Pick a peak for an entry: visible from here, or searched in all installed peak data; or typed by hand.
struct PeakPickerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var title = "Add peak"
    /// Offer to add a peak by the typed name only (for entries; not when the peak must be found on the map).
    var allowsTypedName = true
    let onPick: (PeakEntry.Peak) -> Void
    @State private var query = ""
    @State private var results: [PeakInfo] = []

    var body: some View {
        NavigationStack {
            List {
                let trimmed = query.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    Section("Visible from here") {
                        ForEach(nearby, id: \.id) { row($0) }
                    }
                } else {
                    Section {
                        ForEach(results, id: \.id) { row($0) }
                    }
                    if allowsTypedName {
                    Section {
                        Button {
                            pick(PeakEntry.Peak(id: nil, name: trimmed))
                        } label: {
                            Label("Add “\(trimmed)” without peak data", systemImage: "text.cursor")
                        }
                    } footer: {
                        Text("For peaks outside the downloaded countries. It won't get a mark in the view.")
                    }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Peak name")
            .autocorrectionDisabled()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
            }
            .task(id: query) { await search() }
        }
    }

    private var nearby: [PeakInfo] {
        model.horizonStore.visiblePeaks.sorted { $0.peak.importance > $1.peak.importance }.prefix(25).map(\.peak)
    }

    private func row(_ peak: PeakInfo) -> some View {
        Button {
            pick(PeakEntry.Peak(peak, language: model.settings.peakLanguage))
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(peak.displayName(language: model.settings.peakLanguage)).foregroundStyle(.primary)
                    if let e = peak.elevation {
                        Text(model.settings.elevation(e)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if model.peakBook.mark(of: peak.id) == .climbed {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            .contentShape(Rectangle())
        }
    }

    private func search() async {
        let text = query
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { results = []; return }
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }
        let databases = model.packs.snapshot().peakDatabases
        let found = await Task.detached(priority: .userInitiated) {
            PeakDatabase.search(text, in: databases)
        }.value
        guard !Task.isCancelled else { return }
        results = found
    }

    private func pick(_ peak: PeakEntry.Peak) {
        onPick(peak)
        dismiss()
    }
}
