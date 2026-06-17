import AVFoundation
import AppKit
import CoreGraphics
import SwiftUI
import UniformTypeIdentifiers

enum SidebarSelection: Hashable {
    case home
    case t5tList
    case notesList
    case tasksList
    case todosList
    case meetingsList
    case meeting(UUID)
    case t5tReport(UUID)
    case newT5T
    case note(UUID)
    case task(UUID)
    case todo(UUID)
}

private enum SidebarSectionID: Hashable {
    case t5t
    case notes
    case tasks
    case todos
    case meetings
}

struct SidebarListSlice<Element> {
    let items: [Element]
    let hiddenCount: Int
    let canToggle: Bool
}

enum SidebarListLimiter {
    static func slice<Element>(
        _ items: [Element],
        expanded: Bool,
        searchActive: Bool,
        limit: Int
    ) -> SidebarListSlice<Element> {
        let visibleLimit = max(0, limit)
        let canToggle = !searchActive && items.count > visibleLimit

        guard canToggle, !expanded else {
            return SidebarListSlice(items: items, hiddenCount: 0, canToggle: canToggle)
        }

        return SidebarListSlice(
            items: Array(items.prefix(visibleLimit)),
            hiddenCount: max(0, items.count - visibleLimit),
            canToggle: true
        )
    }
}

struct MeetingLibraryView: View {
    @ObservedObject var meetingManager: MeetingManager
    @ObservedObject var authManager: GoogleAuthManager
    @ObservedObject var chatManager: ChatManager
    @ObservedObject var ttsService: TextToSpeechService
    @State private var selection: SidebarSelection? = .home
    @State private var settingsWindow: NSWindow?
    @State private var pulseAnimation = false
    @State private var showChatDrawer = false
    @State private var sidebarWidth: CGFloat = 0
    @State private var sidebarDragStartWidth: CGFloat?
    @State private var sidebarCollapsed = false
    @State private var collapsedSections: Set<SidebarSectionID> = []
    @State private var openTabs: [SidebarSelection] = [.home]
    @State private var sidebarSearchExpanded = false
    @State private var targetedNoteSpace: String?
    @State private var draggingNoteID: UUID?
    @FocusState private var searchFocused: Bool
    @AppStorage("noteai.commandCenterLayoutPreset") private var commandCenterLayoutPresetRaw = CommandCenterLayoutPreset.balanced.rawValue
    @AppStorage("noteai.sidebarExpandedLists.v1") private var sidebarExpandedListsRaw = ""

    private let sidebarDividerHitWidth: CGFloat = 8
    private let sidebarDefaultVisibleCount = 5

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM/dd/yy"
        return f
    }()

    private func datePrefix(_ date: Date) -> String {
        Self.dateFmt.string(from: date)
    }

    var body: some View {
        GeometryReader { proxy in
            let layoutPreset = CommandCenterLayoutPreset(rawValue: commandCenterLayoutPresetRaw) ?? .balanced
            let layout = CommandCenterLayout.metrics(forWindowWidth: proxy.size.width, preset: layoutPreset)
            let effectiveSidebarWidth = resolvedSidebarWidth(for: layout)

            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    if !sidebarCollapsed {
                        sidebar(layout: layout)
                            .frame(width: effectiveSidebarWidth)
                            .ignoresSafeArea(edges: .top)
                    }
                    ZStack {
                        VStack(spacing: 0) {
                            commandBar(layout: layout)
                            detail
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if showChatDrawer {
                        Rectangle().fill(Theme.border).frame(width: 1)
                        ChatPanelView(chatManager: chatManager, onClose: {
                            withAnimation(.easeInOut(duration: 0.2)) { showChatDrawer = false }
                        })
                        .frame(width: min(420, max(340, round(340 * layout.scale))))
                        .transition(.move(edge: .trailing))
                    }
                }

                if !sidebarCollapsed {
                    sidebarResizeDivider(layout: layout, effectiveSidebarWidth: effectiveSidebarWidth)
                        .ignoresSafeArea(edges: .top)
                }
            }
            .environment(\.commandCenterLayout, layout)
        }
        .background(Theme.notionWindowBG)
        .animation(.easeInOut(duration: 0.2), value: showChatDrawer)
        .onReceive(NotificationCenter.default.publisher(for: .navigateToNote)) { notification in
            if let noteID = notification.object as? UUID {
                selection = .note(noteID)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToSource)) { notification in
            guard let urlString = notification.object as? String,
                  let link = ChatSourceLink(urlString: urlString)
            else { return }
            switch link.kind {
            case .meeting:
                selection = .meeting(link.id)
            case .note:
                selection = .note(link.id)
            case .t5t:
                selection = .t5tReport(link.id)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleChatPanel)) { _ in
            showChatDrawer.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            meetingManager.refreshOnboardingChecklistState()
        }
        .onChange(of: selection) { _, newSelection in
            if let newSelection {
                registerOpenTab(newSelection)
            }
        }
        .sheet(isPresented: $meetingManager.showMeetingNamePrompt) {
            MeetingNamePromptView(
                suggestedName: $meetingManager.pendingMeetingName,
                onSave: { name in
                    meetingManager.finishRecording(name: name)
                },
                onCancel: {
                    meetingManager.finishRecording(name: meetingManager.pendingMeetingName)
                }
            )
        }
    }

    private func resolvedSidebarWidth(for layout: CommandCenterLayout) -> CGFloat {
        guard sidebarWidth > 0 else { return layout.sidebarWidth }
        return min(layout.maximumSidebarWidth, max(layout.minimumSidebarWidth, sidebarWidth))
    }

    private func sidebarResizeDivider(layout: CommandCenterLayout, effectiveSidebarWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: max(0, effectiveSidebarWidth - sidebarDividerHitWidth / 2))
                .allowsHitTesting(false)
            ZStack {
                Color.clear
                Rectangle()
                    .fill(Theme.border)
                    .frame(width: 1)
            }
            .frame(width: sidebarDividerHitWidth)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(sidebarResizeGesture(layout: layout, effectiveSidebarWidth: effectiveSidebarWidth))
            Spacer(minLength: 0)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func sidebarResizeGesture(layout: CommandCenterLayout, effectiveSidebarWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let startWidth = sidebarDragStartWidth ?? effectiveSidebarWidth
                sidebarDragStartWidth = startWidth
                sidebarWidth = min(
                    layout.maximumSidebarWidth,
                    max(layout.minimumSidebarWidth, startWidth + value.translation.width)
                )
            }
            .onEnded { _ in
                sidebarDragStartWidth = nil
            }
    }

    // MARK: - Command bar

    private func commandBar(layout: CommandCenterLayout) -> some View {
        HStack(spacing: 12) {
            if sidebarCollapsed {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { sidebarCollapsed = false }
                } label: {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: layout.sectionTitleFontSize + 2, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: layout.controlHeight, height: layout.controlHeight)
                        .background(Theme.notionSurfaceBG.opacity(0.95), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Show sidebar")
            }

            notionTabBar(layout: layout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

            topBarRecordingControl(layout: layout)

            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    showChatDrawer.toggle()
                }
            } label: {
                Image(systemName: "message")
                    .font(.system(size: layout.smallFontSize, weight: .bold))
                    .foregroundStyle(Theme.accent.opacity(showChatDrawer ? 1.0 : 0.95))
                    .frame(width: round(34 * layout.scale), height: round(34 * layout.scale))
                    .background(Color.clear, in: Capsule())
                    .overlay(Capsule().stroke(Theme.accent.opacity(0.42), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("AI copilot"))
            .help("AI copilot")
        }
        .padding(.leading, sidebarCollapsed ? round(10 * layout.scale) : round(18 * layout.scale))
        .padding(.trailing, round(18 * layout.scale))
        .frame(height: max(48, round(52 * layout.scale)))
        .background(Theme.notionTopBarBG)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.border)
                .frame(height: 1)
        }
    }

    private func notionTabBar(layout: CommandCenterLayout) -> some View {
        HStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { sidebarCollapsed.toggle() }
            } label: {
                Image(systemName: sidebarCollapsed ? "sidebar.left" : "sidebar.leading")
                    .font(.system(size: layout.bodyFontSize + 1, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: round(36 * layout.scale), height: max(34, layout.controlHeight))
            }
            .buttonStyle(.plain)
            .help(sidebarCollapsed ? "Show sidebar" : "Hide sidebar")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(openTabs, id: \.self) { tab in
                        notionTabButton(tab, layout: layout)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
        }
        .background(Theme.notionTopBarBG)
    }

    private func notionTabButton(_ tab: SidebarSelection, layout: CommandCenterLayout) -> some View {
        let isActive = selection == tab
        return HStack(spacing: 8) {
            Image(systemName: notionTabIcon(for: tab))
                .font(.system(size: layout.bodyFontSize + 1, weight: .semibold))
                .foregroundStyle(notionTabAccent(for: tab))
            Text(notionTabTitle(for: tab))
                .font(.system(size: layout.bodyFontSize + 1, weight: .semibold))
                .foregroundStyle(isActive ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Button {
                closeTab(tab)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: max(8, layout.tinyFontSize), weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: round(18 * layout.scale), height: round(18 * layout.scale))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close tab")
        }
        .padding(.horizontal, round(14 * layout.scale))
        .frame(minWidth: round(180 * layout.scale), maxWidth: round(280 * layout.scale), minHeight: max(34, layout.controlHeight))
        .background(isActive ? Theme.notionActiveTabBG : Theme.notionTopBarBG)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(isActive ? Theme.notionActiveTabBG : Theme.border)
                .frame(height: 1)
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Theme.border)
                .frame(width: 1)
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Theme.border)
                .frame(width: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            activateSelection(tab)
        }
        .help(notionTabTitle(for: tab))
    }

    private func notionTabTitle() -> String {
        notionTabTitle(for: selection)
    }

    private func notionTabTitle(for tab: SidebarSelection?) -> String {
        guard let tab else { return meetingManager.state == .recording ? "Live Recording" : "Today" }

        switch tab {
        case .home:
            return "Today"
        case .t5tList:
            return "T5T Reports"
        case .notesList:
            return "Notes"
        case .tasksList:
            return "Tasks"
        case .todosList:
            return "Todos"
        case .meetingsList:
            return "Meetings"
        case .meeting(let id):
            return meetingManager.meetings.first(where: { $0.id == id })?.title.replacingOccurrences(of: "Microsoft Teams", with: "Teams") ?? "Meeting"
        case .t5tReport(let id):
            return meetingManager.t5tReports.first(where: { $0.id == id })?.title ?? "T5T Report"
        case .newT5T:
            return "New T5T"
        case .note(let id):
            return meetingManager.notes.first(where: { $0.id == id })?.title ?? "Note"
        case .task(let id):
            return meetingManager.tasks.first(where: { $0.id == id })?.title ?? "Task"
        case .todo(let id):
            return meetingManager.todos.first(where: { $0.id == id })?.title ?? "Todo"
        }
    }

    private func notionTabIcon() -> String {
        notionTabIcon(for: selection)
    }

    private func notionTabIcon(for tab: SidebarSelection?) -> String {
        guard let tab else { return meetingManager.state == .recording ? "waveform" : "house" }

        switch tab {
        case .home:
            return "house"
        case .t5tList, .t5tReport, .newT5T:
            return "list.bullet.rectangle"
        case .notesList, .note:
            return "doc.text"
        case .tasksList, .task:
            return "checklist"
        case .todosList, .todo:
            return "checkmark.square"
        case .meetingsList, .meeting:
            return "waveform"
        }
    }

    private func notionTabAccent() -> Color {
        notionTabAccent(for: selection)
    }

    private func notionTabAccent(for tab: SidebarSelection?) -> Color {
        guard let tab else { return meetingManager.state == .recording ? Theme.danger : Theme.notionIconAccent }

        switch tab {
        case .home:
            return Theme.textTertiary
        case .t5tList, .t5tReport, .newT5T:
            return Theme.notionIconAccent
        case .notesList, .note:
            return Theme.textTertiary
        case .tasksList, .task:
            return Theme.success
        case .todosList, .todo:
            return Theme.accent
        case .meetingsList, .meeting:
            return Theme.notionIconAccent
        }
    }

    private func topBarRecordingControl(layout: CommandCenterLayout) -> some View {
        let readiness = meetingManager.recordingReadiness
        return Group {
            if meetingManager.state == .recording {
                HStack(spacing: round(8 * layout.scale)) {
                    Circle()
                        .fill(Theme.danger)
                        .frame(width: round(8 * layout.scale), height: round(8 * layout.scale))
                        .opacity(pulseAnimation ? 0.4 : 1.0)
                    Text(formattedDuration)
                        .font(.system(size: layout.tinyFontSize + 1, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.danger)
                    Button {
                        meetingManager.stopRecording()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: layout.tinyFontSize - 1, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: round(22 * layout.scale), height: round(22 * layout.scale))
                            .background(Theme.danger, in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, round(10 * layout.scale))
                .frame(height: layout.controlHeight)
                .background(Theme.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.danger.opacity(0.30), lineWidth: 1))
                .accessibilityLabel(Text("Recording \(formattedDuration)"))
                .help("Recording \(formattedDuration)")
                .onAppear { withAnimation(.easeInOut(duration: 1).repeatForever()) { pulseAnimation = true } }
                .onDisappear { pulseAnimation = false }
            } else {
                Button {
                    meetingManager.startRecording()
                    selection = nil
                } label: {
                    Image(systemName: readiness.systemImage)
                        .font(.system(size: layout.smallFontSize, weight: .bold))
                        .foregroundStyle(Theme.danger.opacity(0.95))
                        .frame(width: round(34 * layout.scale), height: round(34 * layout.scale))
                        .background(Theme.danger.opacity(0.08), in: Capsule())
                        .overlay(Capsule().stroke(Theme.danger.opacity(0.42), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(meetingManager.state == .processing)
                .opacity(meetingManager.state == .processing ? 0.55 : 1)
                .accessibilityLabel(Text(recordButtonLabel))
                .help(recordButtonLabel)
            }
        }
    }

    // MARK: - Sidebar

    private func sidebar(layout: CommandCenterLayout) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            brandHeader(layout: layout)
            searchAndFilters(layout: layout)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    homeSidebarRow(layout: layout)

                    sidebarSection(.t5t, title: "T5T Reports", icon: "list.bullet.rectangle", selectionTarget: .t5tList, action: createNewT5T, layout: layout) {
                        sidebarLimitedContent(
                            meetingManager.t5tReports,
                            expansionID: sidebarExpansionID(for: .t5t),
                            layout: layout
                        ) { report in
                            t5tSidebarRow(report: report, layout: layout)
                        }
                        if meetingManager.t5tReports.isEmpty {
                            emptyHint("No T5T reports yet", layout: layout)
                        }
                    }

                    notesSidebarSection(selectionTarget: .notesList, layout: layout) {
                        ForEach(
                            NoteSpaceOrganizer.groups(
                                for: visibleNotes,
                                explicitSpaces: meetingManager.noteSpaces,
                                includeEmptyUnassigned: !meetingManager.noteSpaces.isEmpty
                            )
                        ) { group in
                            VStack(alignment: .leading, spacing: 0) {
                                noteSpaceHeader(group: group, layout: layout)
                                sidebarLimitedContent(
                                    group.notes,
                                    expansionID: sidebarExpansionID(forNoteSpace: group.title),
                                    layout: layout
                                ) { note in
                                    noteSidebarRow(note: note, layout: layout)
                                }
                            }
                        }
                        if visibleNotes.isEmpty && meetingManager.searchQuery.isEmpty {
                            emptyHint("No notes yet", layout: layout)
                        }
                    }

                    sidebarSection(.tasks, title: "Tasks", icon: "checklist", selectionTarget: .tasksList, action: createNewTask, layout: layout) {
                        sidebarLimitedContent(
                            visibleTasks,
                            expansionID: sidebarExpansionID(for: .tasks),
                            layout: layout
                        ) { task in
                            taskSidebarRow(task: task, layout: layout)
                        }
                        if visibleTasks.isEmpty && meetingManager.searchQuery.isEmpty {
                            emptyHint("No tasks yet", layout: layout)
                        }
                    }

                    sidebarSection(.todos, title: "Todos", icon: "checkmark.square", selectionTarget: .todosList, action: createNewTodo, layout: layout) {
                        sidebarLimitedContent(
                            visibleTodos,
                            expansionID: sidebarExpansionID(for: .todos),
                            layout: layout
                        ) { todo in
                            todoSidebarRow(todo: todo, layout: layout)
                        }
                        if visibleTodos.isEmpty && meetingManager.searchQuery.isEmpty {
                            emptyHint("No todos yet", layout: layout)
                        }
                    }

                    sidebarSection(.meetings, title: "Meetings", icon: "waveform", selectionTarget: .meetingsList, action: nil, layout: layout) {
                        sidebarLimitedContent(
                            visibleMeetings,
                            expansionID: sidebarExpansionID(for: .meetings),
                            layout: layout
                        ) { meeting in
                            sidebarRow(meeting: meeting, layout: layout)
                        }
                        if visibleMeetings.isEmpty {
                            emptyHint(meetingManager.searchQuery.isEmpty ? "No meetings yet" : "No results", layout: layout)
                        }
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 8)
            }

            Spacer()
            Divider().foregroundStyle(Theme.border)

            VStack(spacing: 0) {
                sidebarAction(icon: "gear", label: "Settings", layout: layout) {
                    openSettings()
                }
                if authManager.isAuthenticated && !UserDefaults.standard.bool(forKey: "skippedAuth") {
                    sidebarAction(icon: "rectangle.portrait.and.arrow.right", label: "Sign Out", layout: layout) {
                        authManager.signOut()
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .background(Theme.notionSidebarBG)
    }

    private var searchIsActive: Bool {
        !meetingManager.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var expandedSidebarListIDs: Set<String> {
        Set(sidebarExpandedListsRaw.split(separator: "\n").map(String.init))
    }

    private func isSidebarListExpanded(_ id: String) -> Bool {
        expandedSidebarListIDs.contains(id)
    }

    private func toggleSidebarListExpansion(_ id: String) {
        var ids = expandedSidebarListIDs
        if ids.contains(id) {
            ids.remove(id)
        } else {
            ids.insert(id)
        }
        sidebarExpandedListsRaw = ids.sorted().joined(separator: "\n")
    }

    private func sidebarExpansionID(for section: SidebarSectionID) -> String {
        switch section {
        case .t5t: return "t5t"
        case .notes: return "notes"
        case .tasks: return "tasks"
        case .todos: return "todos"
        case .meetings: return "meetings"
        }
    }

    private func sidebarExpansionID(forNoteSpace title: String) -> String {
        "notespace:" + title.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: "-")
    }

    @ViewBuilder
    private func sidebarLimitedContent<Item: Identifiable, Row: View>(
        _ items: [Item],
        expansionID: String,
        layout: CommandCenterLayout,
        @ViewBuilder row: @escaping (Item) -> Row
    ) -> some View {
        let expanded = isSidebarListExpanded(expansionID)
        let slice = SidebarListLimiter.slice(
            items,
            expanded: expanded,
            searchActive: searchIsActive,
            limit: sidebarDefaultVisibleCount
        )

        ForEach(slice.items) { item in
            row(item)
        }

        if slice.canToggle {
            sidebarListToggleRow(
                expansionID: expansionID,
                isExpanded: expanded,
                hiddenCount: slice.hiddenCount,
                layout: layout
            )
        }
    }

    private func sidebarListToggleRow(
        expansionID: String,
        isExpanded: Bool,
        hiddenCount: Int,
        layout: CommandCenterLayout
    ) -> some View {
        Button {
            toggleSidebarListExpansion(expansionID)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: max(8, layout.tinyFontSize - 1), weight: .semibold))
                Text(isExpanded ? "Show less" : "Show more")
                    .font(.system(size: layout.tinyFontSize + 1, weight: .semibold))
                if !isExpanded {
                    Text("\(hiddenCount)")
                        .font(.system(size: max(8, layout.tinyFontSize), weight: .semibold))
                        .foregroundStyle(Theme.textTertiary.opacity(0.80))
                }
            }
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, round(14 * layout.scale))
            .padding(.vertical, round(5 * layout.scale))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .help(isExpanded ? "Hide older items" : "Show older items")
    }

    private func brandHeader(layout: CommandCenterLayout) -> some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) { sidebarCollapsed = true }
            } label: {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: layout.sectionTitleFontSize + 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Hide sidebar")

            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    sidebarSearchExpanded.toggle()
                }
                if sidebarSearchExpanded {
                    searchFocused = true
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: layout.bodyFontSize + 2, weight: .medium))
                    .foregroundStyle(searchIsActive || sidebarSearchExpanded ? Theme.textPrimary : Theme.textTertiary)
                    .frame(width: round(30 * layout.scale), height: round(30 * layout.scale))
                    .background(
                        searchIsActive || sidebarSearchExpanded ? Theme.notionHoverBG : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Search workspace")
        }
        .padding(.leading, layout.sidebarBrandLeadingInset)
        .padding(.trailing, layout.sidebarBrandLeadingInset)
        .padding(.top, layout.sidebarBrandHeaderTopPadding)
        .padding(.bottom, layout.sidebarBrandHeaderBottomPadding)
        .frame(height: layout.sidebarBrandHeaderHeight, alignment: .center)
    }

    @ViewBuilder
    private func searchAndFilters(layout: CommandCenterLayout) -> some View {
        if sidebarSearchExpanded || searchIsActive {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: layout.smallFontSize))
                    .foregroundStyle(Theme.textTertiary)
                TextField("Search workspace...", text: $meetingManager.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: layout.bodyFontSize))
                    .focused($searchFocused)
                if !meetingManager.searchQuery.isEmpty {
                    Button {
                        meetingManager.searchQuery = ""
                        sidebarSearchExpanded = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: layout.tinyFontSize, weight: .bold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, round(10 * layout.scale))
            .frame(height: max(32, layout.controlHeight - 2))
            .background(Theme.notionSurfaceBG.opacity(0.72), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
            .padding(.horizontal, round(10 * layout.scale))
            .padding(.bottom, round(8 * layout.scale))
        } else {
            EmptyView()
        }
    }

    private func sidebarSection<Content: View>(
        _ id: SidebarSectionID,
        title: String,
        icon: String,
        selectionTarget: SidebarSelection,
        action: (() -> Void)?,
        layout: CommandCenterLayout,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    toggleSection(id)
                } label: {
                    Image(systemName: collapsedSections.contains(id) ? "chevron.right" : "chevron.down")
                        .font(.system(size: layout.tinyFontSize - 1, weight: .bold))
                        .foregroundStyle(Theme.sectionHeader)
                        .frame(width: round(12 * layout.scale), height: round(18 * layout.scale))
                }
                .buttonStyle(.plain)
                .help(collapsedSections.contains(id) ? "Expand \(title)" : "Collapse \(title)")

                sidebarSectionHeaderButton(
                    title: title,
                    icon: icon,
                    selectionTarget: selectionTarget,
                    layout: layout
                )

                Spacer()

                if let action {
                    Button(action: action) {
                        Label("New", systemImage: "plus")
                            .font(.system(size: layout.tinyFontSize + 1, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, round(7 * layout.scale))
                            .padding(.vertical, round(4 * layout.scale))
                            .background(Theme.notionHoverBG, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, round(14 * layout.scale))
            .padding(.top, round(14 * layout.scale))
            .padding(.bottom, round(5 * layout.scale))

            if !collapsedSections.contains(id) {
                content()
            }
        }
    }

    private func notesSidebarSection<Content: View>(
        selectionTarget: SidebarSelection,
        layout: CommandCenterLayout,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    toggleSection(.notes)
                } label: {
                    Image(systemName: collapsedSections.contains(.notes) ? "chevron.right" : "chevron.down")
                        .font(.system(size: layout.tinyFontSize - 1, weight: .bold))
                        .foregroundStyle(Theme.sectionHeader)
                        .frame(width: round(12 * layout.scale), height: round(18 * layout.scale))
                }
                .buttonStyle(.plain)
                .help(collapsedSections.contains(.notes) ? "Expand Notes" : "Collapse Notes")

                sidebarSectionHeaderButton(
                    title: "Notes",
                    icon: "note.text",
                    selectionTarget: selectionTarget,
                    layout: layout
                )

                Spacer()

                Menu {
                    Button {
                        createNewNote()
                    } label: {
                        Label("New Note", systemImage: "note.text")
                    }
                    Button {
                        createNewSpace()
                    } label: {
                        Label("New Space", systemImage: "folder.badge.plus")
                    }
                } label: {
                    Label("New", systemImage: "plus")
                        .font(.system(size: layout.tinyFontSize + 1, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, round(7 * layout.scale))
                        .padding(.vertical, round(4 * layout.scale))
                        .background(Theme.notionHoverBG, in: RoundedRectangle(cornerRadius: 6))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Create a note or note space")
            }
            .padding(.horizontal, round(14 * layout.scale))
            .padding(.top, round(14 * layout.scale))
            .padding(.bottom, round(5 * layout.scale))

            if !collapsedSections.contains(.notes) {
                content()
            }
        }
    }

    private func sidebarSectionHeaderButton(
        title: String,
        icon: String,
        selectionTarget: SidebarSelection,
        layout: CommandCenterLayout
    ) -> some View {
        let isSelected = selection == selectionTarget

        return Button {
            selection = selectionTarget
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: layout.smallFontSize, weight: .medium))
                Text(title.uppercased())
                    .font(.system(size: layout.tinyFontSize + 1, weight: .bold))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? Theme.accent : Theme.sectionHeader)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show \(title)")
    }

    private func toggleSection(_ section: SidebarSectionID) {
        if collapsedSections.contains(section) {
            collapsedSections.remove(section)
        } else {
            collapsedSections.insert(section)
        }
    }

    private func emptyHint(_ text: String, layout: CommandCenterLayout) -> some View {
        Text(text)
            .font(.system(size: layout.smallFontSize))
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, round(18 * layout.scale))
            .padding(.vertical, round(5 * layout.scale))
    }

    private func noteSpaceHeader(group: NoteSpaceGroup, layout: CommandCenterLayout) -> some View {
        let dropTargetID = group.title
        let targetSpace = group.isUnassigned ? nil : group.title
        let isTargeted = targetedNoteSpace == dropTargetID

        return HStack(spacing: 8) {
            Text(group.title)
                .font(.system(size: max(9, layout.tinyFontSize), weight: .bold))
                .foregroundStyle(Theme.textTertiary)
                .textCase(.uppercase)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text("\(group.notes.count)")
                .font(.system(size: max(9, layout.tinyFontSize), weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, round(18 * layout.scale))
        .padding(.top, round(7 * layout.scale))
        .padding(.bottom, round(2 * layout.scale))
        .background(
            isTargeted ? Theme.accent.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .contentShape(Rectangle())
        .contextMenu {
            if !group.isUnassigned {
                Button {
                    renameNoteSpace(group.title)
                } label: {
                    Label("Rename Space", systemImage: "pencil")
                }

                Button(role: .destructive) {
                    deleteNoteSpace(group.title)
                } label: {
                    Label("Delete Space", systemImage: "trash")
                }
            }
        }
        .onDrop(
            of: [.text],
            isTargeted: Binding(
                get: { targetedNoteSpace == dropTargetID },
                set: { targetedNoteSpace = $0 ? dropTargetID : nil }
            )
        ) { providers in
            handleNoteDrop(providers, toSpace: targetSpace)
        }
        .help(group.isUnassigned ? "Drop a note here to remove it from a space" : "Drop a note here to move it to \(group.title)")
    }

    private func t5tSidebarRow(report: T5TReport, layout: CommandCenterLayout) -> some View {
        Button {
            selection = .t5tReport(report.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: layout.bodyFontSize))
                    .foregroundStyle(report.status == .draft ? Color.orange : Theme.textTertiary)
                Text("\(datePrefix(report.createdDate)) T5T - \(report.periodLabel)")
                    .font(.system(size: layout.bodyFontSize))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, round(14 * layout.scale))
            .padding(.vertical, round(6 * layout.scale))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selection == .t5tReport(report.id)
                    ? Theme.notionSelectedBG
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .contextMenu {
            Button("Delete", role: .destructive) {
                if selection == .t5tReport(report.id) { selection = nil }
                meetingManager.deleteT5TReport(report)
            }
        }
    }

    private func sidebarRow(meeting: Meeting, layout: CommandCenterLayout) -> some View {
        Button {
            selection = .meeting(meeting.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.system(size: layout.bodyFontSize))
                    .foregroundStyle(Theme.textTertiary)
                Text("\(datePrefix(meeting.date)) \(meeting.title.replacingOccurrences(of: "Microsoft Teams", with: "Teams"))")
                    .font(.system(size: layout.bodyFontSize))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, round(14 * layout.scale))
            .padding(.vertical, round(6 * layout.scale))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selection == .meeting(meeting.id)
                    ? Theme.notionSelectedBG
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .contextMenu {
            Button("Save to Note") {
                let note = meetingManager.createNoteFromMeeting(meeting)
                selection = .note(note.id)
            }
            Button("Export as Markdown") { exportMeeting(meeting) }
            Button("Export as PDF") { exportMeetingPDF(meeting) }
            Divider()
            Button("Delete", role: .destructive) {
                if selection == .meeting(meeting.id) { selection = nil }
                meetingManager.deleteMeeting(meeting)
            }
        }
    }

    private func noteSidebarRow(note: Note, layout: CommandCenterLayout) -> some View {
        Button {
            selection = .note(note.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "note.text")
                    .font(.system(size: layout.bodyFontSize))
                    .foregroundStyle(Theme.textTertiary)
                Text("\(datePrefix(note.createdDate)) \(note.title)")
                    .font(.system(size: layout.bodyFontSize))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, round(14 * layout.scale))
            .padding(.vertical, round(6 * layout.scale))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selection == .note(note.id)
                    ? Theme.notionSelectedBG
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .contextMenu {
            Button("Delete", role: .destructive) {
                if selection == .note(note.id) { selection = nil }
                meetingManager.deleteNote(note)
            }
        }
        .onDrag {
            draggingNoteID = note.id
            return NSItemProvider(object: note.id.uuidString as NSString)
        }
        .help("Drag into a note space")
    }

    // MARK: - Home + Todos sidebar

    private func homeSidebarRow(layout: CommandCenterLayout) -> some View {
        Button {
            selection = .home
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.grid.2x2")
                    .font(.system(size: layout.smallFontSize))
                    .foregroundStyle(Theme.textTertiary)
                Text("Today")
                    .font(.system(size: layout.bodyFontSize, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                let pending = meetingManager.todos.filter { !$0.completed }.count
                if pending > 0 {
                    Text("\(pending)")
                        .font(.system(size: layout.tinyFontSize, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Theme.notionHoverBG, in: Capsule())
                }
            }
            .padding(.horizontal, round(14 * layout.scale))
            .padding(.vertical, round(6 * layout.scale))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selection == .home ? Theme.notionSelectedBG : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .padding(.top, round(4 * layout.scale))
    }

    private var visibleTodos: [TodoItem] {
        let todos = meetingManager.filteredTodos
        let pending = todos.filter { !$0.completed }
        let completed = todos.filter { $0.completed }
        let sortedPending = pending.sorted { a, b in
            switch (a.dueDate, b.dueDate) {
            case (let x?, let y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.createdDate > b.createdDate
            }
        }
        let sortedCompleted = completed.sorted { $0.modifiedDate > $1.modifiedDate }
        return sortedPending + sortedCompleted
    }

    private var visibleTasks: [TaskItem] {
        let open = meetingManager.filteredTasks.filter { !$0.isCompleted }
        let completed = meetingManager.filteredTasks.filter { $0.isCompleted }
        let sortedOpen = open.sorted { $0.activityDate > $1.activityDate }
        let sortedCompleted = completed.sorted { $0.activityDate > $1.activityDate }
        return sortedOpen + sortedCompleted
    }

    private var visibleNotes: [Note] {
        meetingManager.filteredNotes
    }

    private var visibleMeetings: [Meeting] {
        meetingManager.filteredMeetings
    }

    private func todoSidebarRow(todo: TodoItem, layout: CommandCenterLayout) -> some View {
        Button {
            selection = .todo(todo.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: todo.completed ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: layout.bodyFontSize))
                    .foregroundStyle(todo.completed ? Theme.success : Theme.textTertiary)
                Text(todo.title.isEmpty ? "Untitled todo" : todo.title)
                    .font(.system(size: layout.bodyFontSize))
                    .foregroundStyle(todo.completed ? Theme.textTertiary : Theme.textPrimary)
                    .strikethrough(todo.completed)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                if let label = todo.dueDateLabel, !todo.completed {
                    Text(label)
                        .font(.system(size: layout.tinyFontSize - 1, weight: .medium))
                        .foregroundStyle(dueLabelColor(for: todo))
                }
            }
            .padding(.horizontal, round(14 * layout.scale))
            .padding(.vertical, round(6 * layout.scale))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selection == .todo(todo.id) ? Theme.notionSelectedBG : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .contextMenu {
            Button(todo.completed ? "Mark pending" : "Mark complete") {
                meetingManager.toggleTodoCompletion(todo)
            }
            Divider()
            Button("Delete", role: .destructive) {
                if selection == .todo(todo.id) { selection = nil }
                meetingManager.deleteTodo(todo)
            }
        }
    }

    private func taskSidebarRow(task: TaskItem, layout: CommandCenterLayout) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                meetingManager.toggleTaskCompletion(task)
            } label: {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: layout.bodyFontSize))
                    .foregroundStyle(task.isCompleted ? Theme.success : Theme.textTertiary)
                    .padding(.top, 1)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.isCompleted ? "Mark task open" : "Mark task complete")

            Button {
                selection = .task(task.id)
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.title.isEmpty ? "Untitled task" : task.title)
                            .font(.system(size: layout.bodyFontSize))
                            .foregroundStyle(task.isCompleted ? Theme.textTertiary : Theme.textPrimary)
                            .strikethrough(task.isCompleted)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if !task.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(task.description.replacingOccurrences(of: "\n", with: " "))
                                .font(.system(size: layout.tinyFontSize))
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(task.isCompleted ? "Done" : "Open")
                        .font(.system(size: layout.tinyFontSize - 1, weight: .medium))
                        .foregroundStyle(task.isCompleted ? Theme.success : Theme.textTertiary)
                        .padding(.top, 1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, round(14 * layout.scale))
        .padding(.vertical, round(6 * layout.scale))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            selection == .task(task.id) ? Theme.notionSelectedBG : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .padding(.horizontal, 4)
        .contextMenu {
            Button(task.isCompleted ? "Mark open" : "Mark complete") {
                meetingManager.toggleTaskCompletion(task)
            }
            Divider()
            Button("Delete", role: .destructive) {
                if selection == .task(task.id) { selection = nil }
                meetingManager.deleteTask(task)
            }
        }
    }

    private func dueLabelColor(for todo: TodoItem) -> Color {
        switch todo.dueGroup {
        case .overdue: return Theme.danger
        case .today: return Theme.warning
        case .upcoming: return Color(hex: "60A5FA")
        case .noDueDate, .completed: return Theme.textTertiary
        }
    }

    private func sidebarAction(icon: String, label: String, layout: CommandCenterLayout, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: layout.bodyFontSize))
                    .foregroundStyle(Theme.textTertiary)
                Text(label)
                    .font(.system(size: layout.bodyFontSize))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, round(14 * layout.scale))
            .padding(.vertical, round(6 * layout.scale))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if meetingManager.state == .processing {
            processingView
        } else if case .home = selection {
            HomeDashboardView(
                meetingManager: meetingManager,
                onSelectTodo: { id in selection = .todo(id) },
                onOnboardingAction: handleOnboardingAction
            )
        } else if case .t5tList = selection {
            t5tReportsListPage
        } else if case .notesList = selection {
            notesListPage
        } else if case .tasksList = selection {
            tasksListPage
        } else if case .todosList = selection {
            todosListPage
        } else if case .meetingsList = selection {
            meetingsListPage
        } else if case .todo(let id) = selection,
                  let index = meetingManager.todos.firstIndex(where: { $0.id == id }) {
            TodoDetailView(
                todo: $meetingManager.todos[index],
                meetingManager: meetingManager
            )
            .id(id)
        } else if case .task(let id) = selection,
                  let index = meetingManager.tasks.firstIndex(where: { $0.id == id }) {
            TaskDetailView(
                task: $meetingManager.tasks[index],
                meetingManager: meetingManager
            )
            .id(id)
        } else if case .t5tReport(let id) = selection,
                  let index = meetingManager.t5tReports.firstIndex(where: { $0.id == id }) {
            T5TComposerView(
                meetingManager: meetingManager,
                report: $meetingManager.t5tReports[index],
                ttsService: ttsService
            )
            .id(id)
        } else if case .newT5T = selection {
            newT5TPlaceholder
        } else if case .note(let id) = selection,
                  let index = meetingManager.notes.firstIndex(where: { $0.id == id }) {
            NotePageView(
                note: $meetingManager.notes[index],
                meetingManager: meetingManager,
                ttsService: ttsService
            )
            .id(id)
        } else if case .meeting(let id) = selection,
                  let meeting = meetingManager.meetings.first(where: { $0.id == id }) {
            NotionPageView(meeting: meeting, summarizationStatus: meetingManager.summarizationStatus, meetingManager: meetingManager, ttsService: ttsService)
                .id(meeting.id)
        } else if meetingManager.state == .recording && selection == nil {
            LiveTranscriptView(meetingManager: meetingManager)
                .background(Theme.notionWindowBG)
        } else {
            HomeDashboardView(
                meetingManager: meetingManager,
                onSelectTodo: { id in selection = .todo(id) },
                onOnboardingAction: handleOnboardingAction
            )
        }
    }

    private var tasksListPage: some View {
        collectionListPage(
            eyebrow: "Tasks",
            title: "Tasks",
            subtitle: "\(visibleTasks.filter { !$0.isCompleted }.count) open • \(visibleTasks.filter(\.isCompleted).count) completed",
            isEmpty: visibleTasks.isEmpty,
            emptyTitle: meetingManager.searchQuery.isEmpty ? "No tasks yet" : "No matching tasks",
            emptySubtitle: meetingManager.searchQuery.isEmpty
                ? "Create durable work records for T5T from the sidebar when a todo becomes report-worthy."
                : "Try a different search term or clear the workspace search."
        ) {
            ForEach(visibleTasks) { task in
                collectionListRow(
                    icon: task.isCompleted ? "checkmark.circle.fill" : "circle",
                    tint: task.isCompleted ? Theme.success : Theme.textTertiary,
                    title: task.title.isEmpty ? "Untitled task" : task.title,
                    metadata: taskStatusMetadata(task),
                    detail: task.description.isEmpty ? nil : task.description
                ) {
                    selection = .task(task.id)
                }
            }
        }
    }

    private var t5tReportsListPage: some View {
        collectionListPage(
            eyebrow: "T5T reports",
            title: "T5T Reports",
            subtitle: "\(meetingManager.t5tReports.count) reports",
            isEmpty: meetingManager.t5tReports.isEmpty,
            emptyTitle: "No T5T reports yet",
            emptySubtitle: "Create a T5T report from the sidebar when you are ready to prepare an update."
        ) {
            ForEach(meetingManager.t5tReports) { report in
                collectionListRow(
                    icon: "list.bullet.rectangle",
                    tint: report.status == .draft ? Color.orange : Theme.textTertiary,
                    title: "\(datePrefix(report.createdDate)) T5T - \(report.periodLabel)",
                    metadata: "\(report.status.rawValue.capitalized) • \(report.meetingIDs.count) meetings",
                    detail: report.title
                ) {
                    selection = .t5tReport(report.id)
                }
            }
        }
    }

    private var notesListPage: some View {
        let groups = NoteSpaceOrganizer.groups(
            for: visibleNotes,
            explicitSpaces: meetingManager.noteSpaces,
            includeEmptyUnassigned: !meetingManager.noteSpaces.isEmpty
        ).filter { !$0.notes.isEmpty }

        return collectionListPage(
            eyebrow: "Notes",
            title: "Notes",
            subtitle: "\(visibleNotes.count) notes",
            isEmpty: visibleNotes.isEmpty,
            emptyTitle: meetingManager.searchQuery.isEmpty ? "No notes yet" : "No matching notes",
            emptySubtitle: meetingManager.searchQuery.isEmpty
                ? "Create a note from the sidebar to start capturing reusable context."
                : "Try a different search term or clear the workspace search."
        ) {
            ForEach(groups) { group in
                if groups.count > 1 {
                    collectionGroupHeader(group.title, count: group.notes.count)
                }
                ForEach(group.notes) { note in
                    collectionListRow(
                        icon: "note.text",
                        tint: Theme.textTertiary,
                        title: "\(datePrefix(note.createdDate)) \(note.title)",
                        metadata: "Modified \(note.formattedModifiedDate)",
                        detail: notePreview(note)
                    ) {
                        selection = .note(note.id)
                    }
                }
            }
        }
    }

    private var todosListPage: some View {
        collectionListPage(
            eyebrow: "Todos",
            title: "Todos",
            subtitle: "\(visibleTodos.filter { !$0.completed }.count) open • \(visibleTodos.filter(\.completed).count) completed",
            isEmpty: visibleTodos.isEmpty,
            emptyTitle: meetingManager.searchQuery.isEmpty ? "No todos yet" : "No matching todos",
            emptySubtitle: meetingManager.searchQuery.isEmpty
                ? "Create a todo from the sidebar when work needs a clear next action."
                : "Try a different search term or clear the workspace search."
        ) {
            ForEach(visibleTodos) { todo in
                collectionListRow(
                    icon: todo.completed ? "checkmark.circle.fill" : "circle",
                    tint: todo.completed ? Theme.success : dueLabelColor(for: todo),
                    title: todo.title.isEmpty ? "Untitled todo" : todo.title,
                    metadata: todo.completed ? "Completed" : (todo.dueDateLabel ?? "No due date"),
                    detail: todo.description.isEmpty ? nil : todo.description
                ) {
                    selection = .todo(todo.id)
                }
            }
        }
    }

    private var meetingsListPage: some View {
        collectionListPage(
            eyebrow: "Meetings",
            title: "Meetings",
            subtitle: "\(visibleMeetings.count) meetings",
            isEmpty: visibleMeetings.isEmpty,
            emptyTitle: meetingManager.searchQuery.isEmpty ? "No meetings yet" : "No matching meetings",
            emptySubtitle: meetingManager.searchQuery.isEmpty
                ? "Record a meeting to start building your meeting library."
                : "Try a different search term or clear the workspace search."
        ) {
            ForEach(visibleMeetings) { meeting in
                collectionListRow(
                    icon: "doc.text",
                    tint: meeting.summary.wasSummarized ? Theme.textTertiary : Theme.warning,
                    title: "\(datePrefix(meeting.date)) \(meeting.title.replacingOccurrences(of: "Microsoft Teams", with: "Teams"))",
                    metadata: "\(meeting.date.formatted(date: .abbreviated, time: .shortened)) • \(meeting.formattedDuration)",
                    detail: meeting.summary.wasSummarized ? nil : "Summary needs review"
                ) {
                    selection = .meeting(meeting.id)
                }
            }
        }
    }

    private func collectionListPage<Content: View>(
        eyebrow: String,
        title: String,
        subtitle: String,
        isEmpty: Bool,
        emptyTitle: String,
        emptySubtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(eyebrow.uppercased())
                        .font(.system(size: Theme.smallSize, weight: .bold))
                        .foregroundStyle(Theme.sectionHeader)
                    Text(title)
                        .font(.system(size: Theme.pageTitleSize, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(subtitle)
                        .font(.system(size: Theme.bodySize))
                        .foregroundStyle(Theme.textTertiary)
                }

                if isEmpty {
                    collectionEmptyState(title: emptyTitle, subtitle: emptySubtitle)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        content()
                    }
                }
            }
            .frame(maxWidth: Theme.maxContentWidth, alignment: .leading)
            .padding(.horizontal, Theme.pagePadding)
            .padding(.vertical, 42)
        }
        .background(Theme.notionWindowBG)
    }

    private func collectionGroupHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: Theme.smallSize, weight: .bold))
                .foregroundStyle(Theme.textTertiary)
            Text("\(count)")
                .font(.system(size: Theme.smallSize, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
            Spacer()
        }
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private func collectionListRow(
        icon: String,
        tint: Color,
        title: String,
        metadata: String,
        detail: String?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: Theme.bodySize, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.system(size: Theme.bodySize, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(metadata)
                        .font(.system(size: Theme.smallSize))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: Theme.smallSize))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 12)
                Image(systemName: "chevron.right")
                    .font(.system(size: Theme.smallSize, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 3)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.notionSurfaceBG.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border.opacity(0.85), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func collectionEmptyState(title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: Theme.bodySize, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            Text(subtitle)
                .font(.system(size: Theme.smallSize))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .background(Theme.notionSurfaceBG.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border.opacity(0.70), lineWidth: 1))
    }

    private func notePreview(_ note: Note) -> String? {
        let preview = note.content
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return preview.isEmpty ? nil : preview
    }

    private func taskStatusMetadata(_ task: TaskItem) -> String {
        let status = task.isCompleted ? "Completed" : "Open"
        guard let workDate = task.workDate else { return "\(status) • No work date" }
        return "\(status) • Work date \(workDate.formatted(date: .abbreviated, time: .omitted))"
    }

    private var newT5TPlaceholder: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text("Creating T5T report...")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.notionWindowBG)
    }

    private var processingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
                .padding(.bottom, 8)

            if case .summarizing(let model) = meetingManager.summarizationStatus {
                Text("Generating summary...")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Using \(model)")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textTertiary)
            } else {
                Text("Processing meeting...")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Finalizing transcription")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textTertiary)
            }

            Text("\(meetingManager.currentTranscript.count) segments transcribed")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.notionWindowBG)
    }

    private func activateSelection(_ target: SidebarSelection?) {
        selection = target
        if let target {
            registerOpenTab(target)
        }
    }

    private func registerOpenTab(_ target: SidebarSelection) {
        guard !openTabs.contains(target) else { return }
        openTabs.append(target)
    }

    private func closeTab(_ target: SidebarSelection) {
        guard let index = openTabs.firstIndex(of: target) else { return }
        openTabs.remove(at: index)

        if openTabs.isEmpty {
            openTabs = [.home]
        }

        if selection == target {
            let replacementIndex = min(index, openTabs.count - 1)
            selection = openTabs[replacementIndex]
        }
    }

    // MARK: - Actions

    private func createNewT5T() {
        let end = Date()
        let start = Calendar.current.date(byAdding: .day, value: -14, to: end)!
        let tasksInRange = meetingManager.tasksInRange(start: start, end: end)

        let report = T5TReport(
            id: UUID(),
            title: meetingManager.t5tDefaultTitle,
            createdDate: Date(),
            periodStart: start,
            periodEnd: end,
            meetingIDs: [],
            noteIDs: [],
            taskIDs: tasksInRange.map(\.id),
            todoIDs: tasksInRange.map(\.id),
            sections: .empty,
            status: .draft
        )

        meetingManager.addT5TReport(report)
        selection = .t5tReport(report.id)
    }

    private func createNewTodo() {
        let todo = meetingManager.createTodo()
        selection = .todo(todo.id)
    }

    private func createNewTask() {
        let task = meetingManager.createTask()
        selection = .task(task.id)
    }

    private func createNewNote() {
        let note = meetingManager.createNote()
        selection = .note(note.id)
    }

    private func createNewSpace() {
        guard let rawName = promptForNoteSpaceName(
            title: "New Note Space",
            informativeText: "Create a space to group notes by project or theme.",
            actionTitle: "Create",
            placeholder: "Project or theme name"
        ),
              meetingManager.createNoteSpace(rawName) != nil
        else { return }
        collapsedSections.remove(.notes)
        meetingManager.searchQuery = ""
    }

    private func renameNoteSpace(_ currentName: String) {
        guard let rawName = promptForNoteSpaceName(
            title: "Rename Note Space",
            informativeText: "Rename this space and keep its notes grouped together.",
            actionTitle: "Rename",
            placeholder: "Project or theme name",
            initialValue: currentName
        ) else { return }

        if meetingManager.renameNoteSpace(currentName, to: rawName) {
            meetingManager.searchQuery = ""
        }
    }

    private func deleteNoteSpace(_ name: String) {
        guard confirmDeleteNoteSpace(name) else { return }

        if meetingManager.deleteNoteSpace(name) {
            meetingManager.searchQuery = ""
        }
    }

    private func promptForNoteSpaceName(
        title: String,
        informativeText: String,
        actionTitle: String,
        placeholder: String,
        initialValue: String = ""
    ) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = informativeText
        alert.addButton(withTitle: actionTitle)
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        textField.placeholderString = placeholder
        textField.stringValue = initialValue
        alert.accessoryView = textField
        alert.window.initialFirstResponder = textField

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return textField.stringValue
    }

    private func confirmDeleteNoteSpace(_ name: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete Note Space?"
        alert.informativeText = "Notes in \"\(name)\" will move to Unassigned. No notes will be deleted."
        alert.addButton(withTitle: "Delete Space")
        alert.addButton(withTitle: "Cancel")

        return alert.runModal() == .alertFirstButtonReturn
    }

    private func handleNoteDrop(_ providers: [NSItemProvider], toSpace space: String?) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.text.identifier) }) else {
            return false
        }

        provider.loadItem(forTypeIdentifier: UTType.text.identifier, options: nil) { item, _ in
            guard let rawValue = stringValue(from: item),
                  let noteID = UUID(uuidString: rawValue.trimmingCharacters(in: .whitespacesAndNewlines))
            else { return }

            Task { @MainActor in
                meetingManager.assignNote(noteID, toSpace: space)
                draggingNoteID = nil
                targetedNoteSpace = nil
            }
        }
        return true
    }

    private func stringValue(from item: NSSecureCoding?) -> String? {
        if let value = item as? String {
            return value
        }
        if let value = item as? NSString {
            return value as String
        }
        if let data = item as? Data {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    private var recordButtonLabel: String {
        switch meetingManager.state {
        case .recording:
            return "Stop Recording"
        case .processing:
            if case .summarizing = meetingManager.summarizationStatus {
                return "Summarizing..."
            }
            return "Processing..."
        case .idle:
            return meetingManager.recordingReadiness.primaryActionTitle
        }
    }

    private var formattedDuration: String {
        let total = Int(meetingManager.recordingDuration)
        let mins = total / 60
        let secs = total % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    private func handleOnboardingAction(_ item: OnboardingChecklistItem) {
        switch item.actionTarget {
        case .startRecording:
            meetingManager.startRecording()
        case .requestMicrophonePermission:
            requestMicrophonePermissionForOnboarding()
        case .openMicrophonePrivacySettings:
            if openSystemSettings(path: "com.apple.preference.security?Privacy_Microphone") {
                meetingManager.refreshOnboardingChecklistStateAfterExternalPermissionChange()
            }
        case .requestScreenRecordingPermission:
            requestScreenRecordingPermissionForOnboarding()
        case .openScreenRecordingPrivacySettings:
            if openSystemSettings(path: "com.apple.preference.security?Privacy_ScreenCapture") {
                meetingManager.refreshOnboardingChecklistStateAfterExternalPermissionChange()
            }
        case .requestNotificationPermission:
            meetingManager.requestNotificationPermissionForOnboarding()
        case .openNotificationSettings:
            openNotificationSettings()
        case .openGeneralSettings:
            openSettings(initialTab: .general)
        case .openAISettings:
            openSettings(initialTab: .ai)
        case .openAccountSettings:
            openSettings(initialTab: .account)
        case .openPrivacySettings:
            openSettings(initialTab: .privacy)
        case .none:
            break
        }
    }

    private func requestMicrophonePermissionForOnboarding() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            Task { @MainActor in
                meetingManager.refreshOnboardingChecklistState()
            }
        }
    }

    private func requestScreenRecordingPermissionForOnboarding() {
        let granted = CGRequestScreenCaptureAccess()
        if granted {
            RecordingDiagnosticsSnapshot.recordSystemAudioAccessConfirmed(true)
            meetingManager.refreshOnboardingChecklistState()
            return
        }

        if openSystemSettings(path: "com.apple.preference.security?Privacy_ScreenCapture") {
            meetingManager.refreshOnboardingChecklistStateAfterExternalPermissionChange()
        } else {
            meetingManager.refreshOnboardingChecklistState()
        }
    }

    private func openSettings(initialTab: SettingsView.SettingsTab = .account) {
        if let existing = settingsWindow, existing.isVisible {
            existing.contentView = NSHostingView(rootView: SettingsView(initialTab: initialTab))
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "NoteAI Settings"
        window.contentView = NSHostingView(rootView: SettingsView(initialTab: initialTab))
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        settingsWindow = window
    }

    private func openNotificationSettings() {
        openSystemSettings(path: "com.apple.preference.notifications")
    }

    @discardableResult
    private func openSystemSettings(path: String) -> Bool {
        guard let url = URL(string: "x-apple.systempreferences:\(path)") else {
            return false
        }
        return NSWorkspace.shared.open(url)
    }

    private func exportMeeting(_ meeting: Meeting) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.text]
        panel.nameFieldStringValue = ExportManager.markdownFilename(for: meeting)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? ExportManager.exportAsMarkdown(meeting).write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func exportMeetingPDF(_ meeting: Meeting) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = ExportManager.pdfFilename(for: meeting)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            if let pdfData = try? ExportManager.exportAsPDFData(meeting) {
                try? pdfData.write(to: url, options: .atomic)
            }
        }
    }
}

// MARK: - Record Button (for toolbar fallback)

struct RecordButton: View {
    @ObservedObject var meetingManager: MeetingManager
    var body: some View {
        Button { meetingManager.toggleRecording() } label: {
            switch meetingManager.state {
            case .idle: Label("Record", systemImage: "record.circle")
            case .recording: Label("Stop", systemImage: "stop.circle.fill").foregroundStyle(.red)
            case .processing: ProgressView().controlSize(.small)
            }
        }
        .disabled(meetingManager.state == .processing)
    }
}
