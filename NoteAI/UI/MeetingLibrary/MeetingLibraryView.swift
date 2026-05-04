import AVFoundation
import AppKit
import CoreGraphics
import SwiftUI
import UniformTypeIdentifiers

enum SidebarSelection: Hashable {
    case home
    case meeting(UUID)
    case t5tReport(UUID)
    case newT5T
    case note(UUID)
    case todo(UUID)
}

private enum SidebarSectionID: Hashable {
    case t5t
    case notes
    case todos
    case meetings
}

private enum CommandCenterQuickFilter: CaseIterable, Hashable {
    case recent
    case openTodos
    case unreviewed

    var label: String {
        switch self {
        case .recent: return "Recent"
        case .openTodos: return "Open"
        case .unreviewed: return "Unreviewed"
        }
    }

    var commandBarLabel: String {
        switch self {
        case .recent: return "Recent meetings filter active"
        case .openTodos: return "Open todos filter active"
        case .unreviewed: return "Unreviewed summaries filter active"
        }
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
    @State private var quickFilter: CommandCenterQuickFilter?
    @State private var targetedNoteSpace: String?
    @State private var draggingNoteID: UUID?
    @FocusState private var searchFocused: Bool

    private let sidebarDividerHitWidth: CGFloat = 8

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
            let layout = CommandCenterLayout.metrics(forWindowWidth: proxy.size.width)
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
        .background(Theme.contentBG)
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
                        .background(Theme.sidebarBG.opacity(0.95), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Show sidebar")
            }

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: layout.bodyFontSize + 1, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                TextField(
                    quickFilter?.commandBarLabel ?? "Command + K  Search meetings, notes, todos...",
                    text: $meetingManager.searchQuery
                )
                .textFieldStyle(.plain)
                .font(.system(size: layout.bodyFontSize + 1))
                .foregroundStyle(Theme.textPrimary)
                .focused($searchFocused)
            }
            .frame(minWidth: min(layout.commandSearchMaxWidth, round(320 * layout.scale)), maxWidth: layout.commandSearchMaxWidth)
            .frame(height: layout.controlHeight)
            .padding(.horizontal, round(14 * layout.scale))
            .background(Theme.sidebarBG.opacity(0.70), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1))

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    showChatDrawer.toggle()
                }
            } label: {
                Label("AI copilot", systemImage: "message")
                    .font(.system(size: layout.bodyFontSize, weight: .semibold))
                    .foregroundStyle(showChatDrawer ? Theme.accent : .black)
                    .frame(height: layout.controlHeight)
                    .padding(.horizontal, round(12 * layout.scale))
                    .background(
                        showChatDrawer ? Theme.accent.opacity(0.12) : Theme.accent,
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(showChatDrawer ? Theme.accent.opacity(0.45) : Color.clear, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, sidebarCollapsed ? round(10 * layout.scale) : round(18 * layout.scale))
        .padding(.trailing, round(18 * layout.scale))
        .frame(height: max(48, round(52 * layout.scale)))
        .background(Theme.contentBG.opacity(0.88))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.border.opacity(0.70))
                .frame(height: 1)
        }
    }

    // MARK: - Sidebar

    private func sidebar(layout: CommandCenterLayout) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            brandHeader(layout: layout)
            recordingControls(layout: layout)
            Divider().foregroundStyle(Theme.border)
            searchAndFilters(layout: layout)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    homeSidebarRow(layout: layout)

                    sidebarSection(.t5t, title: "T5T Reports", icon: "list.bullet.rectangle", action: createNewT5T, layout: layout) {
                        ForEach(meetingManager.t5tReports) { report in
                            t5tSidebarRow(report: report, layout: layout)
                        }
                        if meetingManager.t5tReports.isEmpty {
                            emptyHint("No T5T reports yet", layout: layout)
                        }
                    }

                    notesSidebarSection(layout: layout) {
                        ForEach(
                            NoteSpaceOrganizer.groups(
                                for: visibleNotes,
                                explicitSpaces: meetingManager.noteSpaces,
                                includeEmptyUnassigned: !meetingManager.noteSpaces.isEmpty
                            )
                        ) { group in
                            VStack(alignment: .leading, spacing: 0) {
                                noteSpaceHeader(group: group, layout: layout)
                                ForEach(group.notes) { note in
                                    noteSidebarRow(note: note, layout: layout)
                                }
                            }
                        }
                        if visibleNotes.isEmpty && meetingManager.searchQuery.isEmpty {
                            emptyHint("No notes yet", layout: layout)
                        }
                    }

                    sidebarSection(.todos, title: "Todos", icon: "checkmark.square", action: createNewTodo, layout: layout) {
                        ForEach(visibleTodos) { todo in
                            todoSidebarRow(todo: todo, layout: layout)
                        }
                        if visibleTodos.isEmpty && meetingManager.searchQuery.isEmpty {
                            emptyHint("No todos yet", layout: layout)
                        }
                    }

                    sidebarSection(.meetings, title: "Meetings", icon: "waveform", action: nil, layout: layout) {
                        ForEach(visibleMeetings) { meeting in
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
        .background(Theme.sidebarBG)
    }

    private func brandHeader(layout: CommandCenterLayout) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) { sidebarCollapsed = true }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: layout.sectionTitleFontSize + 4))
                    .foregroundStyle(Theme.textSecondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text("NoteAI")
                        .font(.system(size: layout.sectionTitleFontSize + 1, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("v4.0 Command Center")
                        .font(.system(size: layout.tinyFontSize, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
            }
            .padding(.leading, layout.sidebarBrandLeadingInset)
            .padding(.trailing, round(12 * layout.scale))
            .padding(.top, layout.sidebarBrandHeaderTopPadding)
            .padding(.bottom, layout.sidebarBrandHeaderBottomPadding)
            .frame(height: layout.sidebarBrandHeaderHeight, alignment: .top)
        }
        .buttonStyle(.plain)
        .help("Hide sidebar")
    }

    private func recordingControls(layout: CommandCenterLayout) -> some View {
        let readiness = meetingManager.recordingReadiness
        return VStack(spacing: round(8 * layout.scale)) {
            if meetingManager.state == .recording {
                Button {
                    selection = nil
                } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Theme.danger)
                            .frame(width: 8, height: 8)
                            .opacity(pulseAnimation ? 0.4 : 1.0)
                        Text("Recording")
                            .font(.system(size: layout.bodyFontSize, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
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
                    .padding(.vertical, round(8 * layout.scale))
                    .background(Theme.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.danger.opacity(0.30), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .onAppear { withAnimation(.easeInOut(duration: 1).repeatForever()) { pulseAnimation = true } }
                .onDisappear { pulseAnimation = false }
            } else {
                Button {
                    meetingManager.startRecording()
                    selection = nil
                } label: {
                    Label(recordButtonLabel, systemImage: readiness.systemImage)
                        .font(.system(size: layout.bodyFontSize, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: layout.actionButtonHeight)
                        .background(
                            LinearGradient(colors: [Theme.danger, Color(hex: "FF8A5C")], startPoint: .leading, endPoint: .trailing),
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                }
                .buttonStyle(.plain)
                .disabled(meetingManager.state == .processing)
                .opacity(meetingManager.state == .processing ? 0.55 : 1)
            }
        }
        .padding(.horizontal, round(10 * layout.scale))
        .padding(.bottom, round(10 * layout.scale))
    }

    private func searchAndFilters(layout: CommandCenterLayout) -> some View {
        VStack(spacing: round(8 * layout.scale)) {
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
            .background(Theme.contentBG.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1))

            HStack(spacing: 6) {
                ForEach(CommandCenterQuickFilter.allCases, id: \.self) { filter in
                    quickFilterButton(filter, layout: layout)
                }
            }
        }
        .padding(.horizontal, round(10 * layout.scale))
        .padding(.vertical, round(10 * layout.scale))
    }

    private func quickFilterButton(_ filter: CommandCenterQuickFilter, layout: CommandCenterLayout) -> some View {
        Button {
            quickFilter = quickFilter == filter ? nil : filter
        } label: {
            Text(filter.label)
                .font(.system(size: layout.tinyFontSize + 1, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity)
                .frame(height: max(28, round(28 * layout.scale)))
                .foregroundStyle(quickFilter == filter ? Theme.accent : Theme.textTertiary)
                .background(
                    quickFilter == filter ? Theme.accent.opacity(0.12) : Theme.contentBG.opacity(0.35),
                    in: RoundedRectangle(cornerRadius: 9)
                )
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(quickFilter == filter ? Theme.accent.opacity(0.45) : Theme.border.opacity(0.70), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(filter.commandBarLabel)
    }

    private func sidebarSection<Content: View>(
        _ id: SidebarSectionID,
        title: String,
        icon: String,
        action: (() -> Void)?,
        layout: CommandCenterLayout,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    toggleSection(id)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: collapsedSections.contains(id) ? "chevron.right" : "chevron.down")
                            .font(.system(size: layout.tinyFontSize - 1, weight: .bold))
                        Image(systemName: icon)
                            .font(.system(size: layout.smallFontSize, weight: .medium))
                        Text(title.uppercased())
                            .font(.system(size: layout.tinyFontSize + 1, weight: .bold))
                    }
                    .foregroundStyle(Theme.sectionHeader)
                }
                .buttonStyle(.plain)

                Spacer()

                if let action {
                    Button(action: action) {
                        Label("New", systemImage: "plus")
                            .font(.system(size: layout.tinyFontSize + 1, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, round(7 * layout.scale))
                            .padding(.vertical, round(4 * layout.scale))
                            .background(Theme.hoverBG, in: RoundedRectangle(cornerRadius: 8))
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
        layout: CommandCenterLayout,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    toggleSection(.notes)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: collapsedSections.contains(.notes) ? "chevron.right" : "chevron.down")
                            .font(.system(size: layout.tinyFontSize - 1, weight: .bold))
                        Image(systemName: "note.text")
                            .font(.system(size: layout.smallFontSize, weight: .medium))
                        Text("NOTES")
                            .font(.system(size: layout.tinyFontSize + 1, weight: .bold))
                    }
                    .foregroundStyle(Theme.sectionHeader)
                }
                .buttonStyle(.plain)

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
                        .background(Theme.hoverBG, in: RoundedRectangle(cornerRadius: 8))
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
            in: RoundedRectangle(cornerRadius: 8)
        )
        .contentShape(Rectangle())
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
                    ? Theme.selectedBG
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 12)
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
                    ? Theme.selectedBG
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 12)
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
                    ? Theme.selectedBG
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 12)
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
                        .background(Theme.hoverBG, in: Capsule())
                }
            }
            .padding(.horizontal, round(14 * layout.scale))
            .padding(.vertical, round(6 * layout.scale))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selection == .home ? Theme.selectedBG : Color.clear,
                in: RoundedRectangle(cornerRadius: 12)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .padding(.top, round(4 * layout.scale))
    }

    private var visibleTodos: [TodoItem] {
        let todos = quickFilter == .openTodos
            ? meetingManager.filteredTodos.filter { !$0.completed }
            : meetingManager.filteredTodos
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
        return sortedPending + sortedCompleted.prefix(5)
    }

    private var visibleNotes: [Note] {
        meetingManager.filteredNotes
    }

    private var visibleMeetings: [Meeting] {
        var meetings = meetingManager.filteredMeetings
        if quickFilter == .unreviewed {
            meetings = meetings.filter { !$0.summary.wasSummarized }
        }
        if quickFilter == .recent {
            return Array(meetings.prefix(8))
        }
        return meetings
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
                selection == .todo(todo.id) ? Theme.selectedBG : Color.clear,
                in: RoundedRectangle(cornerRadius: 12)
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
        } else if case .todo(let id) = selection,
                  let index = meetingManager.todos.firstIndex(where: { $0.id == id }) {
            TodoDetailView(
                todo: $meetingManager.todos[index],
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
                .background(Theme.contentBG)
        } else {
            HomeDashboardView(
                meetingManager: meetingManager,
                onSelectTodo: { id in selection = .todo(id) },
                onOnboardingAction: handleOnboardingAction
            )
        }
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
        .background(Theme.contentBG)
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
        .background(Theme.contentBG)
    }

    // MARK: - Actions

    private func createNewT5T() {
        let end = Date()
        let start = Calendar.current.date(byAdding: .day, value: -14, to: end)!
        let meetingsInRange = meetingManager.meetingsInRange(start: start, end: end)

        let report = T5TReport(
            id: UUID(),
            title: meetingManager.t5tDefaultTitle,
            createdDate: Date(),
            periodStart: start,
            periodEnd: end,
            meetingIDs: meetingsInRange.map(\.id),
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

    private func createNewNote() {
        let note = meetingManager.createNote()
        selection = .note(note.id)
    }

    private func createNewSpace() {
        guard let rawName = promptForNoteSpaceName(),
              meetingManager.createNoteSpace(rawName) != nil
        else { return }
        collapsedSections.remove(.notes)
        meetingManager.searchQuery = ""
    }

    private func promptForNoteSpaceName() -> String? {
        let alert = NSAlert()
        alert.messageText = "New Note Space"
        alert.informativeText = "Create a space to group notes by project or theme."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        textField.placeholderString = "Project or theme name"
        alert.accessoryView = textField
        alert.window.initialFirstResponder = textField

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return textField.stringValue
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
