import SwiftUI

/// Task checkbox picker for T5T composer.
struct TaskSelectorView: View {
    let tasks: [TaskItem]
    @Binding var selectedIDs: Set<UUID>
    let periodStart: Date
    let periodEnd: Date

    var tasksInRange: [TaskItem] {
        tasks.filter { $0.createdDate >= periodStart && $0.createdDate <= periodEnd }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(tasksInRange.count) tasks in period")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button(tasksInRange.count == selectedIDs.count ? "Deselect All" : "Select All") {
                    if tasksInRange.count == selectedIDs.count {
                        selectedIDs.removeAll()
                    } else {
                        selectedIDs = Set(tasksInRange.map(\.id))
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .buttonStyle(.plain)
            }

            if tasksInRange.isEmpty {
                Text("No tasks in this date range")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.vertical, 4)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(tasksInRange) { task in
                            taskRow(task)
                        }
                    }
                }
                .frame(maxHeight: 150)
            }
        }
    }

    private func taskRow(_ task: TaskItem) -> some View {
        Button {
            if selectedIDs.contains(task.id) {
                selectedIDs.remove(task.id)
            } else {
                selectedIDs.insert(task.id)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selectedIDs.contains(task.id) ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(selectedIDs.contains(task.id) ? Color.accentColor : Theme.textTertiary)
                Image(systemName: task.status == .completed ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(task.status == .completed ? Color.green : Theme.textTertiary)
                Text(task.title.isEmpty ? "Untitled task" : task.title)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                selectedIDs.contains(task.id) ? Theme.selectedBG : Color.clear,
                in: RoundedRectangle(cornerRadius: 4)
            )
        }
        .buttonStyle(.plain)
    }
}
