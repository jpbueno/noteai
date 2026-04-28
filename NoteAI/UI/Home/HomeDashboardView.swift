import SwiftUI

struct CommandCenterSnapshot {
    let overdue: [TodoItem]
    let today: [TodoItem]
    let upcoming: [TodoItem]
    let noDueDate: [TodoItem]
    let completed: [TodoItem]

    var pendingCount: Int {
        overdue.count + today.count + upcoming.count + noDueDate.count
    }

    var focusCount: Int {
        overdue.count + today.count
    }

    var nextTask: TodoItem? {
        overdue.first ?? today.first ?? upcoming.first ?? noDueDate.first
    }

    init(todos: [TodoItem]) {
        var overdue: [TodoItem] = []
        var today: [TodoItem] = []
        var upcoming: [TodoItem] = []
        var noDueDate: [TodoItem] = []
        var completed: [TodoItem] = []

        for todo in todos {
            switch todo.dueGroup {
            case .overdue:
                overdue.append(todo)
            case .today:
                today.append(todo)
            case .upcoming:
                upcoming.append(todo)
            case .noDueDate:
                noDueDate.append(todo)
            case .completed:
                completed.append(todo)
            }
        }

        self.overdue = overdue.sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
        self.today = today.sorted { $0.createdDate < $1.createdDate }
        self.upcoming = upcoming.sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
        self.noDueDate = noDueDate.sorted { $0.createdDate > $1.createdDate }
        self.completed = completed.sorted { $0.modifiedDate > $1.modifiedDate }
    }
}

struct CommandCenterLayout: Equatable {
    let scale: CGFloat
    let sidebarWidth: CGFloat
    let minimumSidebarWidth: CGFloat
    let maximumSidebarWidth: CGFloat
    let contentMaxWidth: CGFloat
    let commandSearchMaxWidth: CGFloat
    let controlHeight: CGFloat
    let actionButtonHeight: CGFloat
    let panelPadding: CGFloat
    let dashboardSpacing: CGFloat
    let onboardingMinimumCardWidth: CGFloat
    let metricMinimumCardWidth: CGFloat
    let titleFontSize: CGFloat
    let metricValueFontSize: CGFloat
    let sectionTitleFontSize: CGFloat
    let bodyFontSize: CGFloat
    let smallFontSize: CGFloat
    let tinyFontSize: CGFloat

    static func metrics(forWindowWidth windowWidth: CGFloat) -> CommandCenterLayout {
        let width = max(760, windowWidth)
        let scale = min(1.0, max(0.88, width / 1600))
        let typeScale = min(1.0, max(0.96, width / 1700))
        let sidebarWidth = min(244, max(196, width * 0.13))
        let contentMaxWidth = max(780, width - sidebarWidth - 80)

        return CommandCenterLayout(
            scale: scale,
            sidebarWidth: sidebarWidth,
            minimumSidebarWidth: max(196, sidebarWidth - 44),
            maximumSidebarWidth: min(288, sidebarWidth + 52),
            contentMaxWidth: contentMaxWidth,
            commandSearchMaxWidth: min(520, max(360, width * 0.30)),
            controlHeight: min(35, max(32, round(34 * scale))),
            actionButtonHeight: min(38, max(34, round(36 * scale))),
            panelPadding: round(16 * scale),
            dashboardSpacing: round(14 * scale),
            onboardingMinimumCardWidth: round(205 * scale),
            metricMinimumCardWidth: round(96 * scale),
            titleFontSize: min(28, max(26, round(28 * typeScale))),
            metricValueFontSize: min(20, max(18, round(20 * typeScale))),
            sectionTitleFontSize: min(13, max(12, round(13 * typeScale))),
            bodyFontSize: min(11, max(10, round(11 * typeScale))),
            smallFontSize: 10,
            tinyFontSize: 9
        )
    }
}

private struct CommandCenterLayoutKey: EnvironmentKey {
    static let defaultValue = CommandCenterLayout.metrics(forWindowWidth: 1100)
}

extension EnvironmentValues {
    var commandCenterLayout: CommandCenterLayout {
        get { self[CommandCenterLayoutKey.self] }
        set { self[CommandCenterLayoutKey.self] = newValue }
    }
}

/// Home dashboard showing todos grouped by due date. Mirrors
/// web/src/components/HomeDashboard.tsx.
struct HomeDashboardView: View {
    @Environment(\.commandCenterLayout) private var layout
    @ObservedObject var meetingManager: MeetingManager
    let onSelectTodo: (UUID) -> Void
    let onOnboardingAction: (OnboardingChecklistItem) -> Void

    private var snapshot: CommandCenterSnapshot {
        CommandCenterSnapshot(todos: meetingManager.todos)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: layout.dashboardSpacing + 4) {
                header
                snapshotGrid
                onboardingPanel
                taskColumns
            }
            .padding(.horizontal, round(28 * layout.scale))
            .padding(.vertical, round(22 * layout.scale))
            .frame(maxWidth: layout.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.contentBG)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Command Center")
                    .font(.system(size: layout.tinyFontSize + 1, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .textCase(.uppercase)
                Text("Today's workspace")
                    .font(.system(size: layout.titleFontSize, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Keep meetings, notes, tasks, and T5T follow-ups moving from one place.")
                    .font(.system(size: layout.bodyFontSize + 1))
                    .foregroundStyle(Theme.textTertiary)
            }

            Spacer()

            Button {
                let todo = meetingManager.createTodo()
                onSelectTodo(todo.id)
            } label: {
                Label("New Task", systemImage: "plus")
                    .font(.system(size: layout.bodyFontSize, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, round(14 * layout.scale))
                    .frame(height: layout.actionButtonHeight)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        }
    }

    private var snapshotGrid: some View {
        let snapshot = snapshot
        return LazyVGrid(
            columns: [
                GridItem(.flexible(minimum: round(360 * layout.scale)), spacing: layout.dashboardSpacing),
                GridItem(.flexible(minimum: round(280 * layout.scale)), spacing: layout.dashboardSpacing),
            ],
            spacing: layout.dashboardSpacing
        ) {
            CommandCenterPanel {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Operational snapshot")
                            .font(.system(size: layout.sectionTitleFontSize + 2, weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("\(snapshot.pendingCount) pending\(snapshot.completed.isEmpty ? "" : " - \(snapshot.completed.count) completed")")
                            .font(.system(size: layout.bodyFontSize))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    Text("v4")
                        .font(.system(size: layout.smallFontSize, weight: .bold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Theme.accent.opacity(0.12), in: Capsule())
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: layout.metricMinimumCardWidth), spacing: 10)], spacing: 10) {
                    MetricTile(icon: "waveform.path.ecg", label: "Focus queue", value: snapshot.focusCount)
                    MetricTile(icon: "checklist", label: "Open tasks", value: snapshot.pendingCount)
                    MetricTile(icon: "checkmark.square", label: "Completed", value: snapshot.completed.count)
                    MetricTile(icon: "clock", label: "Upcoming", value: snapshot.upcoming.count)
                }
                .padding(.top, 14)
            }

            CommandCenterPanel {
                HStack {
                    Text("Suggested next move")
                        .font(.system(size: layout.sectionTitleFontSize, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 10, height: 10)
                }

                if let nextTask = snapshot.nextTask {
                    Button {
                        onSelectTodo(nextTask.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(nextTask.title.isEmpty ? "Untitled task" : nextTask.title)
                                .font(.system(size: layout.bodyFontSize + 1, weight: .bold))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(2)
                            Text(nextTask.dueDateLabel ?? "No due date")
                                .font(.system(size: layout.smallFontSize))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Theme.contentBG.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 10)
                } else {
                    Text("No pending tasks. The workspace is clear.")
                        .font(.system(size: layout.bodyFontSize + 1))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.top, 14)
                }
            }
        }
    }

    private var onboardingPanel: some View {
        let checklist = meetingManager.onboardingChecklist
        return CommandCenterPanel {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Setup checklist")
                        .font(.system(size: layout.sectionTitleFontSize, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("\(checklist.completedCount)/\(checklist.totalCount) complete\(checklist.requiredReady ? " - ready for capture" : " - finish required items before the first recording")")
                        .font(.system(size: layout.smallFontSize))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                Text(checklist.requiredReady ? "Ready" : "Setup needed")
                    .font(.system(size: layout.tinyFontSize + 1, weight: .bold))
                    .foregroundStyle(checklist.requiredReady ? Theme.success : Theme.warning)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        (checklist.requiredReady ? Theme.success : Theme.warning).opacity(0.13),
                        in: Capsule()
                    )
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: layout.onboardingMinimumCardWidth), spacing: 8)], spacing: 8) {
                ForEach(checklist.items) { item in
                    onboardingRow(item)
                }
            }
            .padding(.top, 12)
        }
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
                    .font(.system(size: layout.bodyFontSize + 2, weight: .semibold))
                    .foregroundStyle(onboardingColor(for: item.status))
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(item.label)
                            .font(.system(size: layout.bodyFontSize, weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        if item.required {
                            Text("Required")
                                .font(.system(size: layout.tinyFontSize - 1, weight: .bold))
                                .foregroundStyle(Theme.accent)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Theme.accent.opacity(0.12), in: Capsule())
                        }
                    }
                    Text(item.detail)
                        .font(.system(size: layout.smallFontSize))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(3)
                    if let actionLabel = item.actionLabel,
                       item.status != .complete,
                       item.status != .blocked,
                       item.status != .unsupported {
                        Label(actionLabel, systemImage: "gearshape")
                            .font(.system(size: layout.tinyFontSize + 1, weight: .bold))
                            .foregroundStyle(Theme.accent)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: max(72, round(82 * layout.scale)), alignment: .topLeading)
            .background(Theme.rowBG, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.rowBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(item.status == .complete || item.status == .blocked || item.status == .unsupported)
    }

    private var taskColumns: some View {
        let snapshot = snapshot
        return LazyVGrid(
            columns: [
                GridItem(.flexible(minimum: round(320 * layout.scale)), spacing: layout.dashboardSpacing),
                GridItem(.flexible(minimum: round(320 * layout.scale)), spacing: layout.dashboardSpacing),
            ],
            spacing: layout.dashboardSpacing
        ) {
            TaskColumn(title: "Focus Queue", subtitle: "Overdue and due today", tone: .danger) {
                ForEach(snapshot.overdue + snapshot.today) { todo in
                    commandCenterTaskRow(todo)
                }
                if snapshot.focusCount == 0 {
                    EmptyColumn(text: "No urgent tasks")
                }
            }

            TaskColumn(title: "Upcoming", subtitle: "Next work to prepare", tone: .accent) {
                ForEach(Array((snapshot.upcoming.prefix(8) + snapshot.noDueDate.prefix(4)))) { todo in
                    commandCenterTaskRow(todo)
                }
                if snapshot.upcoming.isEmpty && snapshot.noDueDate.isEmpty {
                    EmptyColumn(text: "No upcoming tasks")
                }
            }

            if !snapshot.completed.isEmpty {
                TaskColumn(title: "Recently Completed", subtitle: "Latest closed loops", tone: .done) {
                    ForEach(Array(snapshot.completed.prefix(6))) { todo in
                        commandCenterTaskRow(todo)
                    }
                }
            }
        }
    }

    private func commandCenterTaskRow(_ todo: TodoItem) -> some View {
        Button {
            onSelectTodo(todo.id)
        } label: {
            HStack(spacing: 12) {
                Button {
                    meetingManager.toggleTodoCompletion(todo)
                } label: {
                    Image(systemName: todo.completed ? "checkmark.square.fill" : "square")
                        .font(.system(size: layout.bodyFontSize + 5, weight: .medium))
                        .foregroundStyle(todo.completed ? Theme.success : Theme.textTertiary)
                }
                .buttonStyle(.plain)

                Text(todo.title.isEmpty ? "Untitled task" : todo.title)
                    .font(.system(size: layout.bodyFontSize + 1, weight: .semibold))
                    .foregroundStyle(todo.completed ? Theme.textTertiary : Theme.textPrimary)
                    .strikethrough(todo.completed)
                    .lineLimit(1)

                Spacer()

                if let label = todo.dueDateLabel {
                    Label(label, systemImage: "calendar")
                        .font(.system(size: layout.tinyFontSize + 1, weight: .medium))
                        .foregroundStyle(dueLabelColor(for: todo))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.rowBG, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.rowBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
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

    private func onboardingIcon(for status: OnboardingItemStatus) -> String {
        switch status {
        case .complete:
            return "checkmark.circle.fill"
        case .needsAction:
            return "circle"
        case .blocked, .unsupported:
            return "exclamationmark.triangle.fill"
        }
    }

    private func onboardingColor(for status: OnboardingItemStatus) -> Color {
        switch status {
        case .complete:
            return Theme.success
        case .needsAction:
            return Theme.textTertiary
        case .blocked, .unsupported:
            return Theme.warning
        }
    }

    private func dueLabelColor(for todo: TodoItem) -> Color {
        switch todo.dueGroup {
        case .overdue:
            return Theme.danger
        case .today:
            return Theme.warning
        case .upcoming:
            return Color(hex: "60A5FA")
        case .noDueDate, .completed:
            return Theme.textTertiary
        }
    }
}

private struct CommandCenterPanel<Content: View>: View {
    @Environment(\.commandCenterLayout) private var layout
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(layout.panelPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panelBG, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.22), radius: 28, y: 12)
    }
}

private struct MetricTile: View {
    @Environment(\.commandCenterLayout) private var layout
    let icon: String
    let label: String
    let value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: layout.bodyFontSize + 1, weight: .medium))
                Text(label)
                    .font(.system(size: layout.smallFontSize, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(Theme.textTertiary)

            Text("\(value)")
                .font(.system(size: layout.metricValueFontSize, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(round(12 * layout.scale))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.contentBG.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1))
    }
}

private struct TaskColumn<Content: View>: View {
    @Environment(\.commandCenterLayout) private var layout

    enum Tone {
        case danger
        case accent
        case done
    }

    let title: String
    let subtitle: String
    let tone: Tone
    @ViewBuilder var content: Content

    private var color: Color {
        switch tone {
        case .danger:
            return Theme.danger
        case .accent:
            return Theme.accent
        case .done:
            return Theme.success
        }
    }

    var body: some View {
        CommandCenterPanel {
            HStack(spacing: 8) {
                Circle()
                    .fill(color)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: layout.bodyFontSize + 1, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(subtitle)
                        .font(.system(size: layout.smallFontSize))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.bottom, 12)

            VStack(spacing: 8) {
                content
            }
        }
    }
}

private struct EmptyColumn: View {
    @Environment(\.commandCenterLayout) private var layout
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: layout.bodyFontSize + 1))
            .foregroundStyle(Theme.textTertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, round(28 * layout.scale))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            )
    }
}
