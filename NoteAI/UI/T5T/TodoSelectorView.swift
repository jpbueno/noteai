import SwiftUI

/// Task checkbox picker for T5T composer. Uses durable TaskItem records as the
/// primary source input.
struct TaskSelectorView: View {
    let tasks: [TaskItem]
    @Binding var selectedIDs: Set<UUID>
    let periodStart: Date
    let periodEnd: Date

    var tasksInRange: [TaskItem] {
        tasks.filter { task in
            let activity = task.activityDate
            return activity >= periodStart && activity <= periodEnd
        }
        .sorted { $0.activityDate > $1.activityDate }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(tasksInRange.count) tasks in period")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Select the work records that should feed this T5T.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                }
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
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .background(Theme.rowBG, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Theme.rowBorder, lineWidth: 1)
                    )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(tasksInRange) { task in
                            taskRow(task)
                        }
                    }
                    .padding(10)
                }
                .frame(minHeight: 260, maxHeight: 420)
                .background(Theme.panelBG, in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Theme.border, lineWidth: 1)
                )
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
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selectedIDs.contains(task.id) ? "checkmark.square.fill" : "square")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(selectedIDs.contains(task.id) ? Color.accentColor : Theme.textTertiary)
                    .padding(.top, 2)
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(task.isCompleted ? Theme.success : Theme.textTertiary)
                    .padding(.top, 3)
                VStack(alignment: .leading, spacing: 6) {
                    Text(LibraryListPresentation.taskTitle(task))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .strikethrough(task.isCompleted)
                        .lineLimit(1)
                    if !task.description.isEmpty {
                        Text(task.description)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(2)
                    }
                    HStack(spacing: 12) {
                        Label(LibraryListPresentation.shortDateString(for: task.activityDate), systemImage: "calendar")
                            .labelStyle(.titleAndIcon)
                        Label(task.isCompleted ? "Completed" : "Open", systemImage: "text.alignleft")
                            .labelStyle(.titleAndIcon)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                selectedIDs.contains(task.id) ? Theme.selectedBG : Theme.rowBG,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selectedIDs.contains(task.id) ? Theme.accent.opacity(0.65) : Theme.rowBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

/// Todo checkbox picker for T5T composer. Uses the lightweight TodoItem model
/// as the primary T5T input in the web app.
struct TodoSelectorView: View {
    let todos: [TodoItem]
    @Binding var selectedIDs: Set<UUID>
    let periodStart: Date
    let periodEnd: Date

    var todosInRange: [TodoItem] {
        todos.filter { todo in
            // Include todos created in range OR completed/updated in range
            let createdInRange = todo.createdDate >= periodStart && todo.createdDate <= periodEnd
            let modifiedInRange = todo.modifiedDate >= periodStart && todo.modifiedDate <= periodEnd
            return createdInRange || modifiedInRange
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(todosInRange.count) todos in period")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button(todosInRange.count == selectedIDs.count ? "Deselect All" : "Select All") {
                    if todosInRange.count == selectedIDs.count {
                        selectedIDs.removeAll()
                    } else {
                        selectedIDs = Set(todosInRange.map(\.id))
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .buttonStyle(.plain)
            }

            if todosInRange.isEmpty {
                Text("No todos in this date range")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.vertical, 4)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(todosInRange) { todo in
                            todoRow(todo)
                        }
                    }
                }
                .frame(maxHeight: 150)
            }
        }
    }

    private func todoRow(_ todo: TodoItem) -> some View {
        Button {
            if selectedIDs.contains(todo.id) {
                selectedIDs.remove(todo.id)
            } else {
                selectedIDs.insert(todo.id)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selectedIDs.contains(todo.id) ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(selectedIDs.contains(todo.id) ? Color.accentColor : Theme.textTertiary)
                Image(systemName: todo.completed ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(todo.completed ? Color.green : Theme.textTertiary)
                Text(todo.title.isEmpty ? "Untitled todo" : todo.title)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary)
                    .strikethrough(todo.completed)
                    .lineLimit(1)
                if let label = todo.dueDateLabel {
                    Text(label)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                selectedIDs.contains(todo.id) ? Theme.selectedBG : Color.clear,
                in: RoundedRectangle(cornerRadius: 4)
            )
        }
        .buttonStyle(.plain)
    }
}
