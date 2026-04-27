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

struct MeetingLibraryView: View {
    @ObservedObject var meetingManager: MeetingManager
    @ObservedObject var authManager: GoogleAuthManager
    @ObservedObject var chatManager: ChatManager
    @ObservedObject var ttsService: TextToSpeechService
    @State private var selection: SidebarSelection?
    @State private var settingsWindow: NSWindow?
    @State private var pulseAnimation = false
    @State private var showChatDrawer = false
    @State private var sidebarWidth: CGFloat = 220
    @State private var sidebarCollapsed = false

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
            if sidebarCollapsed {
                collapsedSidebarStrip
            } else {
                sidebar
                    .frame(width: sidebarWidth)
                Rectangle()
                    .fill(Theme.border)
                    .frame(width: 4)
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
                detail

                if sidebarCollapsed {
                    VStack {
                        HStack(spacing: 10) {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) { sidebarCollapsed = false }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "brain.head.profile")
                                        .font(.system(size: 22))
                                        .foregroundStyle(Theme.textSecondary)
                                    Text("NoteAI")
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundStyle(Theme.textPrimary)
                                }
                            }
                            .buttonStyle(.plain)
                            .padding(.leading, 14)
                            .padding(.top, 12)
                            Spacer()
                        }
                        Spacer()
                    }
                }

                // Floating AI Assistant button (bottom-right)
                if !showChatDrawer {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) { showChatDrawer = true }
                            } label: {
                                Image(systemName: "brain.head.profile")
                                    .font(.system(size: 22))
                                    .foregroundStyle(.white)
                                    .frame(width: 48, height: 48)
                                    .background(Color.accentColor, in: Circle())
                                    .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
                            }
                            .buttonStyle(.plain)
                            .padding(20)
                        }
                    }
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

    // MARK: - Collapsed sidebar strip

    @ViewBuilder
    private var collapsedSidebarStrip: some View {
        EmptyView()
    }

    // MARK: - Sidebar (Notion-style)

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.textSecondary)
                Text("NoteAI")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 16)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) { sidebarCollapsed = true }
            }

            // User profile (if signed in)
            if let profile = authManager.userProfile {
                HStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(Color(hex: "333333"))
                            .frame(width: 22, height: 22)
                        Text(profile.initials)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    Text(profile.email)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            } else {
                Spacer().frame(height: 8)
            }

            // Record area
            if meetingManager.state == .recording {
                // While recording: clickable bar navigates to live transcript,
                // small stop button inside stops recording
                Button {
                    selection = nil  // deselect anything → shows live transcript
                } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color(hex: "E03E3E"))
                            .frame(width: 8, height: 8)
                            .opacity(pulseAnimation ? 0.4 : 1.0)
                        Text("Recording")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text(formattedDuration)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color(hex: "E03E3E"))
                        // Stop button — nested, stops recording
                        Button {
                            meetingManager.stopRecording()
                        } label: {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(Color(hex: "E03E3E"), in: RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        Color(hex: "E03E3E").opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .onAppear { withAnimation(.easeInOut(duration: 1).repeatForever()) { pulseAnimation = true } }
                .onDisappear { pulseAnimation = false }
            } else {
                // Idle / processing: start recording button
                Button { meetingManager.startRecording() } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color(hex: "E03E3E"))
                            .frame(width: 8, height: 8)
                        Text(meetingManager.state == .processing ? "Processing..." : "Start Recording")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Theme.hoverBG, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .disabled(meetingManager.state == .processing)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }

            Divider().foregroundStyle(Theme.border)

            // Search bar
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                TextField("Search...", text: $meetingManager.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !meetingManager.searchQuery.isEmpty {
                    Button {
                        meetingManager.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Theme.hoverBG, in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 8)
            .padding(.top, 8)

            // Scrollable lists
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Home row
                    homeSidebarRow

                    // Todos section
                    HStack {
                        sidebarSection("Todos", icon: "checkmark.circle")
                        Spacer()
                        sidebarAddButton("New") { createNewTodo() }
                    }

                    ForEach(visibleTodos) { todo in
                        todoSidebarRow(todo: todo)
                    }

                    if visibleTodos.isEmpty && meetingManager.searchQuery.isEmpty {
                        Text("No todos yet")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 4)
                    }

                    // T5T Reports section
                    HStack {
                        sidebarSection("T5T Reports", icon: "list.bullet.rectangle")
                        Spacer()
                        sidebarAddButton("New") { createNewT5T() }
                    }

                    ForEach(meetingManager.t5tReports) { report in
                        t5tSidebarRow(report: report)
                    }

                    if meetingManager.t5tReports.isEmpty {
                        Text("No T5T reports yet")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 4)
                    }

                    // Notes section
                    HStack {
                        sidebarSection("Notes", icon: "note.text")
                        Spacer()
                        sidebarAddButton("New") { createNewNote() }
                    }

                    ForEach(meetingManager.filteredNotes) { note in
                        noteSidebarRow(note: note)
                    }

                    if meetingManager.filteredNotes.isEmpty && meetingManager.searchQuery.isEmpty {
                        Text("No notes yet")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 4)
                    }

                    // Tasks section
                    HStack {
                        sidebarSection("Tasks", icon: "checkmark.circle")
                        Spacer()
                        sidebarAddButton("New") { createNewTask() }
                    }

                    ForEach(meetingManager.filteredTasks) { task in
                        taskSidebarRow(task: task)
                    }

                    if meetingManager.filteredTasks.isEmpty && meetingManager.searchQuery.isEmpty {
                        Text("No tasks yet")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 4)
                    }

                    // Meetings section
                    sidebarSection("Meetings", icon: "waveform")

                    ForEach(meetingManager.filteredMeetings) { meeting in
                        sidebarRow(meeting: meeting)
                    }

                    if meetingManager.filteredMeetings.isEmpty {
                        Text(meetingManager.searchQuery.isEmpty ? "No meetings yet" : "No results")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                    }
                }
                .padding(.top, 8)
            }

            Spacer()

            // Bottom actions
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
        // Width controlled by sidebarWidth state via draggable divider
        .background(Theme.sidebarBG)
    }

    private func sidebarSection(_ title: String, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(Theme.sectionHeader)
            Text(title.uppercased())
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.sectionHeader)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private func sidebarAddButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .semibold))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Theme.hoverBG, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .padding(.trailing, 10)
        .padding(.top, 10)
    }

    private func t5tSidebarRow(report: T5TReport) -> some View {
        Button {
            selection = .t5tReport(report.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 13))
                    .foregroundStyle(report.status == .draft ? Color.orange : Theme.textTertiary)
                Text("\(datePrefix(report.createdDate)) T5T — \(report.periodLabel)")
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
                in: RoundedRectangle(cornerRadius: 4)
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
                in: RoundedRectangle(cornerRadius: 4)
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
                in: RoundedRectangle(cornerRadius: 4)
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
                    .foregroundStyle(task.status == .completed ? Color.green : Theme.textTertiary)
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
                in: RoundedRectangle(cornerRadius: 4)
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
                Image(systemName: "house")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                Text("Home")
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
                in: RoundedRectangle(cornerRadius: 4)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }

    private var visibleTodos: [TodoItem] {
        // Sort: pending first (overdue → today → upcoming → no due date), completed last
        let todos = meetingManager.filteredTodos
        let pending = todos.filter { !$0.completed }
        let completed = todos.filter { $0.completed }
        let sortedPending = pending.sorted { a, b in
            // Items with a due date sort first, ascending; no-due-date items last
            switch (a.dueDate, b.dueDate) {
            case (let x?, let y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.createdDate > b.createdDate
            }
        }
        let sortedCompleted = completed.sorted { $0.modifiedDate > $1.modifiedDate }
        // Keep the sidebar short: cap completed tail at 5
        return sortedPending + sortedCompleted.prefix(5)
    }

    private func todoSidebarRow(todo: TodoItem) -> some View {
        Button {
            selection = .todo(todo.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: todo.completed ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(todo.completed ? Color.green : Theme.textTertiary)
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
                in: RoundedRectangle(cornerRadius: 4)
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
        case .overdue: return Color(hex: "E03E3E")
        case .today: return Color(hex: "E8974F")
        case .upcoming: return Color(hex: "4A90E2")
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
        } else if meetingManager.state == .recording {
            // No specific item selected while recording — show live transcript
            LiveTranscriptView(meetingManager: meetingManager)
                .background(Theme.contentBG)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "doc.text")
                    .font(.system(size: 36))
                    .foregroundStyle(Theme.textTertiary)
                Text("Select a meeting, note, or report")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.contentBG)
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
