import SwiftUI

/// Note checkbox picker for T5T composer — mirrors MeetingSelectorView pattern.
struct NoteSelectorView: View {
    let notes: [Note]
    @Binding var selectedIDs: Set<UUID>
    let periodStart: Date
    let periodEnd: Date

    var notesInRange: [Note] {
        notes.filter { $0.modifiedDate >= periodStart && $0.modifiedDate <= periodEnd }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(notesInRange.count) notes in period")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button(notesInRange.count == selectedIDs.count ? "Deselect All" : "Select All") {
                    if notesInRange.count == selectedIDs.count {
                        selectedIDs.removeAll()
                    } else {
                        selectedIDs = Set(notesInRange.map(\.id))
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .buttonStyle(.plain)
            }

            if notesInRange.isEmpty {
                Text("No notes in this date range")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.vertical, 4)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(notesInRange) { note in
                            noteRow(note)
                        }
                    }
                }
                .frame(maxHeight: 150)
            }
        }
    }

    private func noteRow(_ note: Note) -> some View {
        Button {
            if selectedIDs.contains(note.id) {
                selectedIDs.remove(note.id)
            } else {
                selectedIDs.insert(note.id)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selectedIDs.contains(note.id) ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(selectedIDs.contains(note.id) ? Color.accentColor : Theme.textTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.title)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Text(note.formattedModifiedDate)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                        if !note.tags.isEmpty {
                            Text(note.tags.prefix(3).joined(separator: ", "))
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                        }
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                selectedIDs.contains(note.id) ? Theme.selectedBG : Color.clear,
                in: RoundedRectangle(cornerRadius: 4)
            )
        }
        .buttonStyle(.plain)
    }
}
