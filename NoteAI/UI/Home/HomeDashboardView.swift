import SwiftUI
import UniformTypeIdentifiers

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

    var nextTodo: TodoItem? {
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
    let sidebarBrandLeadingInset: CGFloat
    let sidebarBrandHeaderHeight: CGFloat
    let sidebarBrandHeaderTopPadding: CGFloat
    let sidebarBrandHeaderBottomPadding: CGFloat
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
        let sidebarWidth = min(280, max(228, width * 0.155))
        let contentMaxWidth = max(780, width - sidebarWidth - 80)
        let sidebarBrandLeadingInset: CGFloat = 14

        return CommandCenterLayout(
            scale: scale,
            sidebarWidth: sidebarWidth,
            minimumSidebarWidth: max(218, sidebarWidth - 44),
            maximumSidebarWidth: min(320, sidebarWidth + 60),
            contentMaxWidth: contentMaxWidth,
            commandSearchMaxWidth: min(520, max(360, width * 0.30)),
            sidebarBrandLeadingInset: sidebarBrandLeadingInset,
            sidebarBrandHeaderHeight: round(78 * scale),
            sidebarBrandHeaderTopPadding: round(28 * scale),
            sidebarBrandHeaderBottomPadding: round(16 * scale),
            controlHeight: min(39, max(36, round(38 * scale))),
            actionButtonHeight: min(42, max(38, round(41 * scale))),
            panelPadding: round(16 * scale),
            dashboardSpacing: round(14 * scale),
            onboardingMinimumCardWidth: round(236 * scale),
            metricMinimumCardWidth: round(112 * scale),
            titleFontSize: min(32, max(31, round(32 * typeScale))),
            metricValueFontSize: min(24, max(23, round(24 * typeScale))),
            sectionTitleFontSize: min(16, max(15, round(16 * typeScale))),
            bodyFontSize: min(14, max(13, round(14 * typeScale))),
            smallFontSize: 12,
            tinyFontSize: 11
        )
    }
}

enum DashboardPanelID: String, CaseIterable, Hashable {
    case operationalSnapshot
    case suggestedNextMove
    case setupChecklist
    case focusQueue
    case upcoming
    case recentlyCompleted

    static let defaultOrder: [DashboardPanelID] = [
        .operationalSnapshot,
        .suggestedNextMove,
        .focusQueue,
        .upcoming,
        .recentlyCompleted,
        .setupChecklist,
    ]
}

struct DashboardPanelColumns: Equatable {
    let leading: [DashboardPanelID]
    let trailing: [DashboardPanelID]
}

enum CommandCenterPanelOrder {
    static func orderedIDs(availableIDs: [DashboardPanelID], rawValue: String) -> [DashboardPanelID] {
        let validIDs = Set(availableIDs)
        var seen: Set<DashboardPanelID> = []
        var result: [DashboardPanelID] = []

        for rawID in rawValue.split(separator: ",") {
            guard let id = DashboardPanelID(rawValue: String(rawID)),
                  validIDs.contains(id),
                  !seen.contains(id) else {
                continue
            }
            seen.insert(id)
            result.append(id)
        }

        for id in availableIDs where !seen.contains(id) {
            result.append(id)
        }

        return result
    }

    static func moveForDrop(
        _ movingID: DashboardPanelID,
        onto targetID: DashboardPanelID,
        in ids: [DashboardPanelID]
    ) -> [DashboardPanelID] {
        guard movingID != targetID,
              let movingIndex = ids.firstIndex(of: movingID),
              let originalTargetIndex = ids.firstIndex(of: targetID) else {
            return ids
        }

        var result = ids
        result.remove(at: movingIndex)
        guard let targetIndex = result.firstIndex(of: targetID) else {
            return ids
        }
        let insertIndex = movingIndex < originalTargetIndex ? targetIndex + 1 : targetIndex
        result.insert(movingID, at: insertIndex)
        return result
    }

    static func columns(for ids: [DashboardPanelID]) -> DashboardPanelColumns {
        var leading: [DashboardPanelID] = []
        var trailing: [DashboardPanelID] = []

        for (index, id) in ids.enumerated() {
            if index.isMultiple(of: 2) {
                leading.append(id)
            } else {
                trailing.append(id)
            }
        }

        return DashboardPanelColumns(leading: leading, trailing: trailing)
    }

    static func rawValue(for ids: [DashboardPanelID]) -> String {
        ids.map(\.rawValue).joined(separator: ",")
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
    @AppStorage("noteai.commandCenterPanelOrder.v2") private var commandCenterPanelOrderRaw = ""
    @AppStorage("noteai.setupChecklistCollapsed") private var setupChecklistCollapsed = false
    @State private var draggedDashboardPanelID: DashboardPanelID?
    @State private var dashboardDropTargetID: DashboardPanelID?
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
                dashboardPanels
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
                Text("Keep meetings, notes, todos, and T5T follow-ups moving from one place.")
                    .font(.system(size: layout.bodyFontSize + 1))
                    .foregroundStyle(Theme.textTertiary)
            }

            Spacer()

            Button {
                let todo = meetingManager.createTodo()
                onSelectTodo(todo.id)
            } label: {
                Label("New Todo", systemImage: "plus")
                    .font(.system(size: layout.bodyFontSize, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, round(14 * layout.scale))
                    .frame(height: layout.actionButtonHeight)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
    }

    private var dashboardPanels: some View {
        let snapshot = snapshot
        let orderedIDs = orderedDashboardPanelIDs(for: snapshot)
        let columns = CommandCenterPanelOrder.columns(for: orderedIDs)
        return HStack(alignment: .top, spacing: layout.dashboardSpacing) {
            dashboardPanelColumn(columns.leading, snapshot: snapshot, orderedIDs: orderedIDs)
                .frame(maxWidth: .infinity, alignment: .top)
            if !columns.trailing.isEmpty {
                dashboardPanelColumn(columns.trailing, snapshot: snapshot, orderedIDs: orderedIDs)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .animation(.easeInOut(duration: 0.16), value: commandCenterPanelOrderRaw)
    }

    private func dashboardPanelColumn(
        _ ids: [DashboardPanelID],
        snapshot: CommandCenterSnapshot,
        orderedIDs: [DashboardPanelID]
    ) -> some View {
        VStack(alignment: .leading, spacing: layout.dashboardSpacing) {
            ForEach(ids, id: \.self) { id in
                dashboardPanelCard(id, snapshot: snapshot, orderedIDs: orderedIDs)
            }
        }
    }

    private func availableDashboardPanelIDs(for snapshot: CommandCenterSnapshot) -> [DashboardPanelID] {
        DashboardPanelID.defaultOrder.filter { id in
            id != .recentlyCompleted || !snapshot.completed.isEmpty
        }
    }

    private func orderedDashboardPanelIDs(for snapshot: CommandCenterSnapshot) -> [DashboardPanelID] {
        CommandCenterPanelOrder.orderedIDs(
            availableIDs: availableDashboardPanelIDs(for: snapshot),
            rawValue: commandCenterPanelOrderRaw
        )
    }

    @ViewBuilder
    private func dashboardPanelCard(
        _ id: DashboardPanelID,
        snapshot: CommandCenterSnapshot,
        orderedIDs: [DashboardPanelID]
    ) -> some View {
        dashboardPanelContent(id, snapshot: snapshot)
            .contentShape(Rectangle())
            .frame(minHeight: dashboardPanelMinimumHeight(for: id), alignment: .topLeading)
            .opacity(draggedDashboardPanelID == id ? 0.65 : 1)
            .overlay {
                if dashboardDropTargetID == id {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Theme.accent, lineWidth: 2)
                        .padding(-3)
                }
            }
            .onDrop(
                of: [UTType.plainText],
                delegate: DashboardPanelDropDelegate(
                    targetID: id,
                    orderedIDs: orderedIDs,
                    orderRawValue: $commandCenterPanelOrderRaw,
                    draggedID: $draggedDashboardPanelID,
                    activeTargetID: $dashboardDropTargetID
                )
            )
    }

    private func dashboardPanelMinimumHeight(for id: DashboardPanelID) -> CGFloat {
        switch id {
        case .operationalSnapshot, .suggestedNextMove:
            return round(126 * layout.scale)
        case .focusQueue, .upcoming:
            return round(124 * layout.scale)
        case .recentlyCompleted:
            return round(196 * layout.scale)
        case .setupChecklist:
            return round(96 * layout.scale)
        }
    }

    @ViewBuilder
    private func dashboardPanelContent(_ id: DashboardPanelID, snapshot: CommandCenterSnapshot) -> some View {
        switch id {
        case .operationalSnapshot:
            operationalSnapshotPanel(snapshot, id: id)
        case .suggestedNextMove:
            suggestedNextMovePanel(snapshot, id: id)
        case .setupChecklist:
            onboardingPanel(for: id)
        case .focusQueue:
            focusQueuePanel(snapshot, id: id)
        case .upcoming:
            upcomingPanel(snapshot, id: id)
        case .recentlyCompleted:
            recentlyCompletedPanel(snapshot, id: id)
        }
    }

    private func operationalSnapshotPanel(_ snapshot: CommandCenterSnapshot, id: DashboardPanelID) -> some View {
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
                dashboardPanelDragHandle(for: id)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: layout.metricMinimumCardWidth), spacing: 10)], spacing: 10) {
                MetricTile(icon: "waveform.path.ecg", label: "Focus queue", value: snapshot.focusCount)
                MetricTile(icon: "checklist", label: "Open todos", value: snapshot.pendingCount)
                MetricTile(icon: "checkmark.square", label: "Completed", value: snapshot.completed.count)
                MetricTile(icon: "clock", label: "Upcoming", value: snapshot.upcoming.count)
            }
            .padding(.top, 14)
        }
    }

    private func suggestedNextMovePanel(_ snapshot: CommandCenterSnapshot, id: DashboardPanelID) -> some View {
        CommandCenterPanel {
            HStack {
                Text("Suggested next move")
                    .font(.system(size: layout.sectionTitleFontSize, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 10, height: 10)
                dashboardPanelDragHandle(for: id)
            }

            if let nextTodo = snapshot.nextTodo {
                Button {
                    onSelectTodo(nextTodo.id)
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(nextTodo.title.isEmpty ? "Untitled todo" : nextTodo.title)
                            .font(.system(size: layout.bodyFontSize + 1, weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(2)
                        Text(nextTodo.dueDateLabel ?? "No due date")
                            .font(.system(size: layout.smallFontSize))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Theme.contentBG.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .padding(.top, 10)
            } else {
                Text("No pending todos. The workspace is clear.")
                    .font(.system(size: layout.bodyFontSize + 1))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 14)
            }
        }
    }

    private func onboardingPanel(for id: DashboardPanelID) -> some View {
        let checklist = meetingManager.onboardingChecklist
        let isCollapsed = setupChecklistCollapsed && checklist.canCollapse
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
                dashboardPanelDragHandle(for: id)
                if checklist.canCollapse {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            setupChecklistCollapsed.toggle()
                        }
                    } label: {
                        Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                            .font(.system(size: layout.smallFontSize, weight: .bold))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 26, height: 26)
                            .background(Theme.rowBG, in: Circle())
                            .overlay(Circle().stroke(Theme.rowBorder, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help(isCollapsed ? "Expand setup checklist" : "Collapse setup checklist")
                }
            }

            if !isCollapsed {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: layout.onboardingMinimumCardWidth), spacing: 8)], spacing: 8) {
                    ForEach(checklist.items) { item in
                        onboardingRow(item)
                    }
                }
                .padding(.top, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onAppear {
            meetingManager.refreshOnboardingChecklistState()
            if !checklist.canCollapse {
                setupChecklistCollapsed = false
            }
        }
        .onChange(of: checklist.canCollapse) { _, canCollapse in
            if !canCollapse {
                setupChecklistCollapsed = false
            }
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
                       item.actionTarget != nil,
                       item.status != .complete {
                        Label(actionLabel, systemImage: "gearshape")
                            .font(.system(size: layout.tinyFontSize + 1, weight: .bold))
                            .foregroundStyle(Theme.accent)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: max(72, round(82 * layout.scale)), alignment: .topLeading)
            .background(Theme.rowBG, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.rowBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(item.status == .complete || item.actionTarget == nil)
        .help(item.status == .complete || item.actionTarget == nil ? "" : "Open setup action")
    }

    private func focusQueuePanel(_ snapshot: CommandCenterSnapshot, id: DashboardPanelID) -> some View {
        TodoColumn(title: "Focus Queue", subtitle: "Overdue and due today", tone: .danger) {
            dashboardPanelDragHandle(for: id)
        } content: {
            ForEach(snapshot.overdue + snapshot.today) { todo in
                commandCenterTodoRow(todo)
            }
            if snapshot.focusCount == 0 {
                EmptyColumn(text: "No urgent todos")
            }
        }
    }

    private func upcomingPanel(_ snapshot: CommandCenterSnapshot, id: DashboardPanelID) -> some View {
        TodoColumn(title: "Upcoming", subtitle: "Next work to prepare", tone: .accent) {
            dashboardPanelDragHandle(for: id)
        } content: {
            ForEach(Array((snapshot.upcoming.prefix(8) + snapshot.noDueDate.prefix(4)))) { todo in
                commandCenterTodoRow(todo)
            }
            if snapshot.upcoming.isEmpty && snapshot.noDueDate.isEmpty {
                EmptyColumn(text: "No upcoming todos")
            }
        }
    }

    private func recentlyCompletedPanel(_ snapshot: CommandCenterSnapshot, id: DashboardPanelID) -> some View {
        TodoColumn(title: "Recently Completed", subtitle: "Latest closed loops", tone: .done) {
            dashboardPanelDragHandle(for: id)
        } content: {
            ForEach(Array(snapshot.completed.prefix(6))) { todo in
                commandCenterTodoRow(todo)
            }
        }
    }

    private func dashboardPanelDragHandle(for id: DashboardPanelID) -> some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: layout.smallFontSize, weight: .bold))
            .foregroundStyle(Theme.textSecondary)
            .frame(width: 24, height: 24)
            .background(Theme.rowBG.opacity(0.85), in: Circle())
            .overlay(Circle().stroke(Theme.rowBorder.opacity(0.85), lineWidth: 1))
            .help("Drag panel")
            .onDrag {
                draggedDashboardPanelID = id
                return NSItemProvider(object: id.rawValue as NSString)
            }
    }

    private func commandCenterTodoRow(_ todo: TodoItem) -> some View {
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

                Text(todo.title.isEmpty ? "Untitled todo" : todo.title)
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
            .background(Theme.rowBG, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.rowBorder, lineWidth: 1))
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

private struct DashboardPanelDropDelegate: DropDelegate {
    let targetID: DashboardPanelID
    let orderedIDs: [DashboardPanelID]
    @Binding var orderRawValue: String
    @Binding var draggedID: DashboardPanelID?
    @Binding var activeTargetID: DashboardPanelID?

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropEntered(info: DropInfo) {
        activeTargetID = targetID
        guard let draggedID,
              draggedID != targetID else {
            return
        }

        let movedIDs = CommandCenterPanelOrder.moveForDrop(draggedID, onto: targetID, in: orderedIDs)
        guard movedIDs != orderedIDs else {
            return
        }

        orderRawValue = CommandCenterPanelOrder.rawValue(for: movedIDs)
    }

    func dropExited(info: DropInfo) {
        if activeTargetID == targetID {
            activeTargetID = nil
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        activeTargetID = nil
        draggedID = nil
        return true
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
        .background(Theme.panelBG, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.10), radius: 14, y: 6)
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
        .background(Theme.contentBG.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
    }
}

private struct TodoColumn<Accessory: View, Content: View>: View {
    @Environment(\.commandCenterLayout) private var layout

    enum Tone {
        case danger
        case accent
        case done
    }

    let title: String
    let subtitle: String
    let tone: Tone
    let accessory: Accessory
    let content: Content

    init(
        title: String,
        subtitle: String,
        tone: Tone,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.tone = tone
        self.accessory = accessory()
        self.content = content()
    }

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
                Spacer(minLength: 0)
                accessory
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
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            )
    }
}
