import SwiftUI
import UniformTypeIdentifiers

enum SidebarSelection: Hashable {
    case home
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
    case todos
    case tasks
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
    @State private var sidebarWidth: CGFloat = 220
    @State private var sidebarCollapsed = false
    @State private var collapsedSections: Set<SidebarSectionID> = []
    @State private var quickFilter: CommandCenterQuickFilter?
    @FocusState private var searchFocused: Bool

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM/dd/yy"
        return f
    }()

    private func datePrefix(_ date: Date) -> String {
        Self.dateFmt.string(from: date)
    }

    var body: some View {
        HStack(spacing: 0) {
            if !sidebarCollapsed {
                sidebar
                    .frame(width: sidebarWidth)
                Rectangle()
                    .fill(Theme.border)
                    .frame(width: 1)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let newWidth = sidebarWidth + value.translation.width
                                sidebarWidth = max(160, min(400, newWidth))
                            }
                        )
            }
            ZStack {
                VStack(spacing: 0) {
                    commandBar
                    detail
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showChatDrawer {
                Rectangle().fill(Theme.border).frame(width: 1)
                ChatPanelView(chatManager: chatManager, onClose: {
                    withAnimation(.easeInOut(duration: 0.2)) { showChatDrawer = false }
                })
                .frame(width: 340)
                .transition(.move(edge: .trailing))
            }
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
            case .task:
                selection = .task(link.id)
            case .t5t:
                selection = .t5tReport(link.id)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleChatPanel)) { _ in
            showChatDrawer.toggle()
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

    // MARK: - Command bar

    private var commandBar: some View {
        HStack(spacing: 12) {
            if sidebarCollapsed {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { sidebarCollapsed = false }
                } label: {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 40, height: 40)
                        .background(Theme.sidebarBG.opacity(0.95), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Show sidebar")
            }

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                TextField(
                    quickFilter?.commandBarLabel ?? "Command + K  Search meetings, notes, tasks...",
                    text: $meetingManager.searchQuery
                )
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textPrimary)
                .focused($searchFocused)
            }
            .frame(minWidth: 320, maxWidth: 560)
            .frame(height: 40)
            .padding(.horizontal, 14)
            .background(Theme.sidebarBG.opacity(0.70), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1))

            Spacer()

            Button {
                createNewNote()
            } label: {
                Label("New note", systemImage: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(height: 40)
                    .padding(.horizontal, 12)
                    .background(Theme.sidebarBG.opacity(0.70), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)

            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    showChatDrawer.toggle()
                }
            } label: {
                Label("AI copilot", systemImage: "message")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(showChatDrawer ? Theme.accent : .black)
                    .frame(height: 40)
                    .padding(.horizontal, 12)
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
        .padding(.leading, sidebarCollapsed ? 12 : 24)
        .padding(.trailing, 24)
        .frame(height: 62)
        .background(Theme.contentBG.opacity(0.88))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.border.opacity(0.70))
                .frame(height: 1)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            brandHeader
            recordingControls
            Divider().foregroundStyle(Theme.border)
            searchAndFilters

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    homeSidebarRow

                    sidebarSection(.t5t, title: "T5T Reports", icon: "list.bullet.rectangle", action: createNewT5T) {
                        ForEach(meetingManager.t5tReports) { report in
                            t5tSidebarRow(report: report)
                        }
                        if meetingManager.t5tReports.isEmpty {
                            emptyHint("No T5T reports yet")
                        }
                    }

                    sidebarSection(.notes, title: "Notes", icon: "note.text", action: createNewNote) {
                        ForEach(visibleNotes) { note in
                            noteSidebarRow(note: note)
                        }
                        if visibleNotes.isEmpty && meetingManager.searchQuery.isEmpty {
                            emptyHint("No notes yet")
                        }
                    }

                    sidebarSection(.todos, title: "Todos", icon: "checkmark.square", action: createNewTodo) {
                        ForEach(visibleTodos) { todo in
                            todoSidebarRow(todo: todo)
                        }
                        if visibleTodos.isEmpty && meetingManager.searchQuery.isEmpty {
                            emptyHint("No todos yet")
                        }
                    }

                    sidebarSection(.tasks, title: "Tasks", icon: "checkmark.circle", action: createNewTask) {
                        ForEach(visibleTasks) { task in
                            taskSidebarRow(task: task)
                        }
                        if visibleTasks.isEmpty && meetingManager.searchQuery.isEmpty {
                            emptyHint("No tasks yet")
                        }
                    }

                    sidebarSection(.meetings, title: "Meetings", icon: "waveform", action: nil) {
                        ForEach(visibleMeetings) { meeting in
                            sidebarRow(meeting: meeting)
                        }
                        if visibleMeetings.isEmpty {
                            emptyHint(meetingManager.searchQuery.isEmpty ? "No meetings yet" : "No results")
                        }
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 8)
            }

            Spacer()
            Divider().foregroundStyle(Theme.border)

            VStack(spacing: 0) {
                sidebarAction(icon: "gear", label: "Settings") {
                    openSettings()
                }
                if authManager.isAuthenticated && !UserDefaults.standard.bool(forKey: "skippedAuth") {
                    sidebarAction(icon: "rectangle.portrait.and.arrow.right", label: "Sign Out") {
                        authManager.signOut()
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .background(Theme.sidebarBG)
    }

    private var brandHeader: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) { sidebarCollapsed = true }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.textSecondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text("NoteAI")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("v4.0 Command Center")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 52)
        }
        .buttonStyle(.plain)
        .help("Hide sidebar")
    }

    private var recordingControls: some View {
        VStack(spacing: 8) {
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
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text(formattedDuration)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.danger)
                        Button {
                            meetingManager.stopRecording()
                        } label: {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(Theme.danger, in: RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Theme.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.danger.opacity(0.30), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .onAppear { withAnimation(.easeInOut(duration: 1).repeatForever()) { pulseAnimation = true } }
                .onDisappear { pulseAnimation = false }
            } else {
                HStack(spacing: 6) {
                    recordingSourceCard(icon: "waveform", title: "System", subtitle: "Native capture", active: true)
                    recordingSourceCard(icon: "mic", title: "Mic", subtitle: "Ready", active: false)
                }

                Button {
                    meetingManager.startRecording()
                    selection = nil
                } label: {
                    Label(recordButtonLabel, systemImage: "record.circle")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
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
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private func recordingSourceCard(icon: String, title: String, subtitle: String, active: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .bold))
                    .lineLimit(1)
            }
            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
        }
        .foregroundStyle(active ? Theme.textPrimary : Theme.textSecondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 48)
        .background(active ? Theme.accent.opacity(0.12) : Theme.contentBG.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(active ? Theme.accent.opacity(0.45) : Theme.border.opacity(0.70), lineWidth: 1))
    }

    private var searchAndFilters: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                TextField("Search workspace...", text: $meetingManager.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($searchFocused)
                if !meetingManager.searchQuery.isEmpty {
                    Button {
                        meetingManager.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(Theme.contentBG.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1))

            HStack(spacing: 6) {
                ForEach(CommandCenterQuickFilter.allCases, id: \.self) { filter in
                    quickFilterButton(filter)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    private func quickFilterButton(_ filter: CommandCenterQuickFilter) -> some View {
        Button {
            quickFilter = quickFilter == filter ? nil : filter
        } label: {
            Text(filter.label)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
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
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    toggleSection(id)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: collapsedSections.contains(id) ? "chevron.right" : "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                        Image(systemName: icon)
                            .font(.system(size: 12, weight: .medium))
                        Text(title.uppercased())
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(Theme.sectionHeader)
                }
                .buttonStyle(.plain)

                Spacer()

                if let action {
                    Button(action: action) {
                        Label("New", systemImage: "plus")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(Theme.hoverBG, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 5)

            if !collapsedSections.contains(id) {
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

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 18)
            .padding(.vertical, 5)
    }

    private func t5tSidebarRow(report: T5TReport) -> some View {
        Button {
            selection = .t5tReport(report.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 13))
                    .foregroundStyle(report.status == .draft ? Color.orange : Theme.textTertiary)
                Text("\(datePrefix(report.createdDate)) T5T - \(report.periodLabel)")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
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

    private func sidebarRow(meeting: Meeting) -> some View {
        Button {
            selection = .meeting(meeting.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
                Text("\(datePrefix(meeting.date)) \(meeting.title.replacingOccurrences(of: "Microsoft Teams", with: "Teams"))")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
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
            Button("Create Task") {
                let task = meetingManager.createTaskFromMeeting(meeting)
                selection = .task(task.id)
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

    private func noteSidebarRow(note: Note) -> some View {
        Button {
            selection = .note(note.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "note.text")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
                Text("\(datePrefix(note.createdDate)) \(note.title)")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
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
            Button("Create Task") {
                let task = meetingManager.createTaskFromNote(note)
                selection = .task(task.id)
            }
            Divider()
            Button("Delete", role: .destructive) {
                if selection == .note(note.id) { selection = nil }
                meetingManager.deleteNote(note)
            }
        }
    }

    private func taskSidebarRow(task: TaskItem) -> some View {
        Button {
            selection = .task(task.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: task.status == .completed ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(task.status == .completed ? Theme.success : Theme.textTertiary)
                Text(task.title.isEmpty ? "New Task" : "\(datePrefix(task.createdDate)) \(task.title)")
                    .font(.system(size: 13))
                    .foregroundStyle(task.status == .completed ? Theme.textTertiary : Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .strikethrough(task.status == .completed)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selection == .task(task.id)
                    ? Theme.selectedBG
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 12)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .contextMenu {
            Button(task.status == .completed ? "Mark Pending" : "Mark Complete") {
                var updated = task
                updated.status = task.status == .completed ? .pending : .completed
                meetingManager.updateTask(updated)
            }
            Divider()
            Button("Delete", role: .destructive) {
                if selection == .task(task.id) { selection = nil }
                meetingManager.deleteTask(task)
            }
        }
    }

    // MARK: - Home + Todos sidebar

    private var homeSidebarRow: some View {
        Button {
            selection = .home
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.grid.2x2")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                Text("Today")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                let pending = meetingManager.todos.filter { !$0.completed }.count
                if pending > 0 {
                    Text("\(pending)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Theme.hoverBG, in: Capsule())
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selection == .home ? Theme.selectedBG : Color.clear,
                in: RoundedRectangle(cornerRadius: 12)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .padding(.top, 4)
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

    private var visibleTasks: [TaskItem] {
        let tasks = meetingManager.filteredTasks
        if quickFilter == .openTodos {
            return tasks.filter { $0.status != .completed }
        }
        return tasks
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

    private func todoSidebarRow(todo: TodoItem) -> some View {
        Button {
            selection = .todo(todo.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: todo.completed ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(todo.completed ? Theme.success : Theme.textTertiary)
                Text(todo.title.isEmpty ? "Untitled task" : todo.title)
                    .font(.system(size: 13))
                    .foregroundStyle(todo.completed ? Theme.textTertiary : Theme.textPrimary)
                    .strikethrough(todo.completed)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                if let label = todo.dueDateLabel, !todo.completed {
                    Text(label)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(dueLabelColor(for: todo))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
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

    private func sidebarAction(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
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
        } else if case .task(let id) = selection,
                  let index = meetingManager.tasks.firstIndex(where: { $0.id == id }) {
            TaskDetailView(
                task: $meetingManager.tasks[index],
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

    private func createNewTask() {
        let task = meetingManager.createTask()
        selection = .task(task.id)
    }

    private func createNewTodo() {
        let todo = meetingManager.createTodo()
        selection = .todo(todo.id)
    }

    private func createNewNote() {
        let note = meetingManager.createNote()
        selection = .note(note.id)
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
            return "Start Recording"
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
        case .openGeneralSettings:
            if item.id == .notifications {
                meetingManager.requestNotificationPermissionForOnboarding()
            }
            openSettings(initialTab: .general)
        case .openAISettings:
            openSettings(initialTab: .ai)
        case .openAccountSettings:
            openSettings(initialTab: .account)
        case .openPrivacySettings:
            openSettings(initialTab: .privacy)
        case .openSystemPrivacySettings:
            openSystemPrivacySettings()
        case .none:
            break
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

    private func openSystemPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        if let url {
            NSWorkspace.shared.open(url)
        }
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
