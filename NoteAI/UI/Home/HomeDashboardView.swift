import SwiftUI

/// Home dashboard showing todos grouped by due date. Mirrors
/// web/src/components/HomeDashboard.tsx.
struct HomeDashboardView: View {
    @ObservedObject var meetingManager: MeetingManager
    let onSelectTodo: (UUID) -> Void
    let onOnboardingAction: (OnboardingChecklistItem) -> Void

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
                onboardingPanel

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

    private var onboardingPanel: some View {
        let checklist = meetingManager.onboardingChecklist
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Setup checklist")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("\(checklist.completedCount)/\(checklist.totalCount) complete · \(checklist.requiredReady ? "ready for capture" : "finish required items before the first recording")")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                Text(checklist.requiredReady ? "Ready" : "Setup needed")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(checklist.requiredReady ? Color(hex: "3BB273") : Color(hex: "E8974F"))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        (checklist.requiredReady ? Color(hex: "3BB273") : Color(hex: "E8974F")).opacity(0.13),
                        in: Capsule()
                    )
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 8)], spacing: 8) {
                ForEach(checklist.items) { item in
                    onboardingRow(item)
                }
            }
        }
        .padding(14)
        .background(Theme.sidebarBG.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
        .onAppear {
            meetingManager.refreshOnboardingChecklistState()
        }
    }

    private func onboardingRow(_ item: OnboardingChecklistItem) -> some View {
        Button {
            onOnboardingAction(item)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: onboardingIcon(for: item.status))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(onboardingColor(for: item.status))
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(item.label)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        if item.required {
                            Text("Required")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.12), in: Capsule())
                        }
                    }
                    Text(item.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(2)
                    if let actionLabel = item.actionLabel,
                       item.status != .complete,
                       item.status != .blocked,
                       item.status != .unsupported {
                        Text(actionLabel)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
            .background(Theme.contentBG.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(item.status == .complete || item.status == .blocked || item.status == .unsupported)
    }

    private func onboardingIcon(for status: OnboardingItemStatus) -> String {
        switch status {
        case .complete: return "checkmark.circle.fill"
        case .needsAction: return "circle"
        case .blocked, .unsupported: return "exclamationmark.triangle.fill"
        }
    }

    private func onboardingColor(for status: OnboardingItemStatus) -> Color {
        switch status {
        case .complete: return Color(hex: "3BB273")
        case .needsAction: return Theme.textTertiary
        case .blocked, .unsupported: return Color(hex: "E8974F")
        }
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
