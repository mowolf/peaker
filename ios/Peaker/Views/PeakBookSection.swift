import PeakerKit
import SwiftUI

/// Peak detail: mark as climbed, wishlist, and this peak's entries.
struct PeakBookSection: View {
    @Environment(AppModel.self) private var model
    let peak: PeakInfo
    @State private var error: String?
    @State private var pendingRemoval: StoredEntry?

    var body: some View {
        let book = model.peakBook
        let entries = book.entries(forPeak: peak.id)
        let planned = entries.first { $0.entry.status == .planned }
        let climbedToday = entries.contains { $0.entry.status == .summited && $0.entry.date == DayDate(Date()) }
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button { perform { try book.markClimbed(peak, on: DayDate(Date()), language: language) } } label: {
                    Label(climbedToday ? "Climbed today" : "Mark as climbed",
                          systemImage: climbedToday ? "checkmark.circle.fill" : "checkmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .disabled(climbedToday)

                Button { toggleWishlist(planned) } label: {
                    Label(planned == nil ? "Wishlist" : "On wishlist", systemImage: planned == nil ? "star" : "star.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .tint(planned == nil ? nil : .yellow)
            }
            .controlSize(.large)
            .sensoryFeedback(.success, trigger: entries.count)

            ForEach(entries) { stored in
                EntryRow(stored: stored) { day in
                    var entry = stored.entry
                    entry.date = day
                    perform { try book.save(stored, as: entry) }
                } onDelete: {
                    pendingRemoval = stored
                }
            }
        }
        .alert("Couldn't save", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
        .confirmationDialog(removalTitle, isPresented: Binding(get: { pendingRemoval != nil },
                                                               set: { if !$0 { pendingRemoval = nil } }),
                            titleVisibility: .visible, presenting: pendingRemoval) { stored in
            Button("Delete", role: .destructive) { perform { try book.delete(stored) } }
        } message: { stored in
            Text("\(stored.fileName) will be deleted, with any notes in it.")
        }
    }

    private var language: String? { model.settings.peakLanguage }

    private var removalTitle: String {
        pendingRemoval?.entry.status == .planned ? "Remove from wishlist?" : "Delete this entry?"
    }

    /// Off the wishlist: an entry without notes goes right away, one with notes asks first.
    private func toggleWishlist(_ planned: StoredEntry?) {
        guard let planned else {
            perform { try model.peakBook.addToWishlist(peak, language: language) }
            return
        }
        if planned.entry.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            perform { try model.peakBook.delete(planned) }
        } else {
            pendingRemoval = planned
        }
    }

    private func perform(_ change: () throws -> Void) {
        do {
            try withAnimation(.smooth) { try change() }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// One entry of this peak: status, date (changeable), title or first line, companions.
private struct EntryRow: View {
    let stored: StoredEntry
    let onDateChange: (DayDate) -> Void
    let onDelete: () -> Void

    var body: some View {
        let entry = stored.entry
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(statusText).font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    if entry.status != .planned {
                        DatePicker("Date", selection: dateBinding, in: ...Date(), displayedComponents: .date)
                            .labelsHidden()
                            .datePickerStyle(.compact)
                    }
                }
                if let line = summary {
                    Text(line).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
                NavigationLink {
                    EntryEditorView(stored: stored)
                } label: {
                    Label(summary == nil ? "Write about it" : "Open notes", systemImage: "square.and.pencil")
                        .font(.footnote.weight(.semibold))
                }
                if !entry.companions.isEmpty {
                    Label(entry.companions.joined(separator: ", "), systemImage: "person.2")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .contextMenu {
            Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
        }
    }

    private var icon: String {
        switch stored.entry.status {
        case .summited: "checkmark.circle.fill"
        case .attempted: "arrow.uturn.down.circle"
        case .planned: "star.fill"
        }
    }

    private var color: Color {
        switch stored.entry.status {
        case .summited: .green
        case .attempted: .orange
        case .planned: .yellow
        }
    }

    private var statusText: String {
        switch stored.entry.status {
        case .summited: "Climbed"
        case .attempted: "Attempted"
        case .planned: "On your wishlist"
        }
    }

    /// The entry's heading, else its first line of text.
    private var summary: String? {
        if let title = stored.entry.title { return title }
        return stored.entry.body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    private var dateBinding: Binding<Date> {
        Binding(get: { stored.entry.date?.noon ?? Date() },
                set: { onDateChange(DayDate($0)) })
    }
}

extension DayDate {
    /// Noon on this day in the current time zone (a safe `Date` for pickers around DST changes).
    var noon: Date? {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12))
    }
}
