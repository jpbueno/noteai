import SwiftUI

/// Home dashboard showing todos grouped by due date. Mirrors
/// web/src/components/HomeDashboard.tsx.
struct HomeDashboardView: View {
    @ObservedObject var meetingManager: MeetingManager
    let onSelectTodo: (UUID) -> Void

    private var grouped: (overdue: [TodoItem], today: [TodoItem], upcoming: [TodoItem], noDueDate: [TodoItem], completed: [TodoItem]) {
        var overdue: [TodoItem] = []
        var today: [TodoItem] = []
        var upcoming: [TodoItem] = []
        var noDueDate: [TodoItem] = []
        var completed: [TodoItem] = []

        for todo in meetingManager.todos {
            switch todo.dueGroup {
            case .overdue: overdue.append(todo)
            case .today: today.append(todo)
            case .upcoming: upcoming.append(todo)
            case .noDueDate: noDueDate.append(todo)
            case .completed: completed.append(todo)
            }
        }

        // Sort each group
        overdue.sort { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
        upcoming.sort { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
        today.sort { $0.createdDate < $1.createdDate }
        noDueDate.sort { $0.createdDate > $1.createdDate }
        completed.sort { $0.modifiedDate > $1.modifiedDate }

        return (overdue, today, upcoming, noDueDate, completed)
    }

    private var pendingCount: Int {
        meetingManager.todos.filter { !$0.completed }.count
    }

    private var completedCount: Int {
        meetingManager.todos.filter { $0.completed }.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                if meetingManager.todos.isEmpty {
                    emptyState
                } else {
                    groups
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.contentBG)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Home")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("\(pendingCount) pending · \(completedCount) completed")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                Button {
                    let todo = meetingManager.createTodo()
                    onSelectTodo(todo.id)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .semibold))
                        Text("New Task")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.hoverBG, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 28))
                .foregroundStyle(Theme.textTertiary.opacity(0.7))
            Text("No tasks yet")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            Text("Click “New Task” above to create your first one.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
    }

    @ViewBuilder
    private var groups: some View {
        let g = grouped
        VStack(alignment: .leading, spacing: 20) {
            if !g.overdue.isEmpty {
                todoGroup(title: "Overdue", color: Color(hex: "E03E3E"), items: g.overdue)
            }
            if !g.today.isEmpty {
                todoGroup(title: "Today", color: Color(hex: "E8974F"), items: g.today)
            }
            if !g.upcoming.isEmpty {
                todoGroup(title: "Upcoming", color: Color(hex: "4A90E2"), items: g.upcoming)
            }
            if !g.noDueDate.isEmpty {
                todoGroup(title: "No due date", color: Theme.textTertiary, items: g.noDueDate)
            }
            if !g.completed.isEmpty {
                todoGroup(title: "Completed", color: Color(hex: "3BB273"), items: g.completed)
            }
        }
    }

    private func todoGroup(title: String, color: Color, items: [TodoItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .tracking(0.2)
                Text("\(items.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.bottom, 2)

            VStack(spacing: 1) {
                ForEach(items) { todo in
                    todoRow(todo, groupColor: color)
                }
            }
            .background(Theme.sidebarBG.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
        }
    }

    private func todoRow(_ todo: TodoItem, groupColor: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                meetingManager.toggleTodoCompletion(todo)
            } label: {
                Image(systemName: todo.completed ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(todo.completed ? Color(hex: "3BB273") : Theme.textTertiary)
            }
            .buttonStyle(.plain)

            Button {
                onSelectTodo(todo.id)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(todo.title.isEmpty ? "Untitled task" : todo.title)
                        .font(.system(size: 13))
                        .foregroundStyle(todo.completed ? Theme.textTertiary : Theme.textPrimary)
                        .strikethrough(todo.completed)
                        .lineLimit(1)
                    if !todo.description.isEmpty {
                        Text(todo.description)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            if let label = todo.dueDateLabel {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(groupColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(groupColor.opacity(0.12), in: Capsule())
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .contextMenu {
            Button(todo.completed ? "Mark pending" : "Mark complete") {
                meetingManager.toggleTodoCompletion(todo)
            }
            Divider()
            Button("Delete", role: .destructive) {
                meetingManager.deleteTodo(todo)
            }
        }
    }
}
