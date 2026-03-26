import SwiftUI

/// Date range picker + meeting checklist for T5T source selection.
struct MeetingSelectorView: View {
    let meetings: [Meeting]
    @Binding var selectedIDs: Set<UUID>
    @Binding var periodStart: Date
    @Binding var periodEnd: Date

    var meetingsInRange: [Meeting] {
        meetings.filter { $0.date >= periodStart && $0.date <= periodEnd }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Date range
            HStack(spacing: 16) {
                HStack(spacing: 6) {
                    Text("From")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                    DatePicker("", selection: $periodStart, displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.field)
                }
                HStack(spacing: 6) {
                    Text("To")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                    DatePicker("", selection: $periodEnd, displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.field)
                }
                Spacer()
            }

            // Quick select buttons
            HStack(spacing: 8) {
                quickButton("Last 2 weeks") {
                    periodEnd = Date()
                    periodStart = Calendar.current.date(byAdding: .day, value: -14, to: periodEnd)!
                }
                quickButton("This month") {
                    periodEnd = Date()
                    periodStart = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date()))!
                }
                Spacer()
                Button(meetingsInRange.count == selectedIDs.count ? "Deselect All" : "Select All") {
                    if meetingsInRange.count == selectedIDs.count {
                        selectedIDs.removeAll()
                    } else {
                        selectedIDs = Set(meetingsInRange.map(\.id))
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .buttonStyle(.plain)
            }

            Divider().foregroundStyle(Theme.border)

            // Meeting list
            if meetingsInRange.isEmpty {
                Text("No meetings in this date range")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(meetingsInRange) { meeting in
                            meetingRow(meeting)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
    }

    private func meetingRow(_ meeting: Meeting) -> some View {
        Button {
            if selectedIDs.contains(meeting.id) {
                selectedIDs.remove(meeting.id)
            } else {
                selectedIDs.insert(meeting.id)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selectedIDs.contains(meeting.id) ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(selectedIDs.contains(meeting.id) ? Color.accentColor : Theme.textTertiary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Text(meeting.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                        Text(meeting.formattedDuration)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                        if !meeting.summary.topics.isEmpty {
                            Text(meeting.summary.topics.prefix(2).joined(separator: ", "))
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
                selectedIDs.contains(meeting.id) ? Theme.selectedBG : Color.clear,
                in: RoundedRectangle(cornerRadius: 4)
            )
        }
        .buttonStyle(.plain)
    }

    private func quickButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: {
            action()
            selectedIDs = Set(meetingsInRange.map(\.id))
        }) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Theme.hoverBG, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }
}
