import Foundation
import Combine
import UserNotifications

/// Central orchestrator that coordinates audio capture, transcription, and summarization.
@MainActor
final class MeetingManager: ObservableObject {
    private static let noteSpacesDefaultsKey = "noteSpaces"

    enum State: Equatable {
        case idle
        case recording
        case processing
    }

    @Published var state: State = .idle
    @Published var currentTranscript: [TranscriptSegment] = []
    @Published var currentSpeakerProfiles: [String: SpeakerProfile] = [:]
    @Published var pendingSpeakerTagID: String?
    @Published var meetings: [Meeting] = []
    @Published var lastError: String?
    @Published var recordingDuration: TimeInterval = 0
    @Published var recordingDiagnostics = RecordingDiagnosticsSnapshot.currentPermissions()
    @Published var onboardingNotificationPermission: OnboardingPermissionStatus = .unknown
    @Published var summarizationStatus: SummarizationStatus = .idle
    @Published var searchQuery: String = ""
    @Published var showMeetingNamePrompt = false
    @Published var pendingMeetingName = ""

    // Notes state
    @Published var notes: [Note] = []
    @Published var noteSpaces: [String] = []

    var filteredNotes: [Note] {
        LibraryOperations.filter(meetings: meetings, notes: notes, query: searchQuery).notes
    }

    // Todos state (lightweight, with optional due date — mirrors web TodoItem)
    @Published var todos: [TodoItem] = []

    var filteredTodos: [TodoItem] {
        guard !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty else { return todos }
        let query = searchQuery.lowercased()
        return todos.filter {
            $0.title.lowercased().contains(query) ||
            $0.description.lowercased().contains(query)
        }
    }

    // Tasks state (durable work records for meeting actions, AI task lists, and T5T)
    @Published var tasks: [TaskItem] = []

    var filteredTasks: [TaskItem] {
        guard !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty else { return tasks }
        let query = searchQuery.lowercased()
        return tasks.filter {
            $0.title.lowercased().contains(query) ||
            $0.description.lowercased().contains(query)
        }
    }

    // T5T state
    @Published var t5tReports: [T5TReport] = []
    @Published var t5tConfig: T5TConfig = .empty
    @Published var t5tGenerationStatus: T5TGenerationStatus = .idle

    enum T5TGenerationStatus: Equatable {
        case idle
        case generating(model: String)
        case failed(error: String)
    }

    enum SummarizationStatus: Equatable {
        case idle
        case summarizing(model: String)
        case failed(error: String)
    }

    var filteredMeetings: [Meeting] {
        LibraryOperations.filter(meetings: meetings, notes: notes, query: searchQuery).meetings
    }

    var recordingReadiness: MeetingRecordingReadiness {
        MeetingRecordingReadiness.resolve(
            recordingState: recordingReadinessState,
            autoDetectEnabled: autoDetectEnabled,
            detectionState: meetingDetector.state,
            detectedApp: meetingDetector.detectedApp ?? meetingDetector.likelyMeetingApp,
            calendarAuthorization: meetingDetector.calendarAuthorization,
            upcomingCalendarEvent: meetingDetector.upcomingCalendarEvent
        )
    }

    @Published var autoDetectEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoDetectEnabled, forKey: "autoDetectMeetings")
            updateAutoDetectionMonitoring()
        }
    }

    @Published var autoDetectionEngine: AutoDetectionEngine {
        didSet {
            UserDefaults.standard.set(autoDetectionEngine.rawValue, forKey: "autoDetectionEngine")
            updateAutoDetectionMonitoring()
        }
    }

    let meetingDetector = MeetingDetector()
    let teamsCallDetectorV5 = TeamsCallDetectorV5()

    // AI Coach state (real-time Solutions Architect insights during recording)
    @Published var coachInsights: [CoachInsight] = []
    @Published var coachAnalyzing = false
    @Published var coachReplying = false
    @Published var coachEnabled: Bool {
        didSet {
            UserDefaults.standard.set(coachEnabled, forKey: "aiCoachEnabled")
        }
    }

    private let audioCaptureManager = AudioCaptureManager()
    private let transcriptionEngine = TranscriptionEngine()
    private let summarizationEngine = SummarizationEngine()
    private let aiCoachEngine = AICoachEngine()
    private let meetingStore = MeetingStore()
    private let notificationManager = NotificationDelivery()

    private var currentMeetingStart: Date?
    private var currentDetectedAppName: String?
    private var currentPreferredCaptureSource: AppAudioCaptureSource?
    private var localHelperSessionId: UUID?
    private var recordingTimer: Timer?
    private var coachTimer: Timer?
    private var coachAnalyzingInFlight = false
    private var coachLastAnalyzedSegmentCount = 0
    private var coachLastAnalyzedTime: Date?
    private var deferredSpeakerTagIDs = Set<String>()
    private var cancellables = Set<AnyCancellable>()
    private var onboardingPermissionRefreshSequenceTask: Task<Void, Never>?

    private var recordingReadinessState: RecordingReadinessState {
        switch state {
        case .idle:
            return .idle
        case .recording:
            return .recording
        case .processing:
            return .processing
        }
    }

    init() {
        AutoDetectionDefaults.migrateToV5DefaultsIfNeeded()
        self.autoDetectEnabled = AutoDetectionDefaults.isEnabled()
        self.autoDetectionEngine = AutoDetectionDefaults.engine()
        // Default coach to enabled; users can turn it off from the recording screen.
        if UserDefaults.standard.object(forKey: "aiCoachEnabled") == nil {
            self.coachEnabled = true
        } else {
            self.coachEnabled = UserDefaults.standard.bool(forKey: "aiCoachEnabled")
        }

        loadMeetings()
        loadNoteSpaces()
        loadNotes()
        loadT5TData()
        loadTodos()
        loadTasks()
        refreshOnboardingChecklistState()
        setupToggleListener()
        setupTranscriptionPipeline()
        setupAutoDetection()
    }

    var onboardingChecklist: OnboardingChecklist {
        let permissions = recordingDiagnostics.permissions
        let providerRaw = UserDefaults.standard.string(forKey: "llmProvider") ?? LLMProviderType.openRouter.rawValue
        let provider = LLMProviderType(rawValue: providerRaw) ?? .openRouter

        return OnboardingChecklist.build(
            provider: provider,
            providerKeyConfigured: !APIKeyStore.key(for: provider).isEmpty,
            microphonePermission: Self.onboardingPermission(from: permissions[.microphone] ?? .unknown),
            screenRecordingPermission: Self.onboardingPermission(from: permissions[.screenRecording] ?? .unknown),
            notificationPermission: onboardingNotificationPermission,
            calendarAuthConfigured: KeychainHelper.load(key: "google_access_token") != nil,
            meetingCount: meetings.count
        )
    }

    func refreshOnboardingChecklistState() {
        recordingDiagnostics = RecordingDiagnosticsSnapshot.currentPermissions()

        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let status: OnboardingPermissionStatus
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                status = .granted
            case .denied:
                status = .denied
            case .notDetermined:
                status = .unknown
            @unknown default:
                status = .unsupported("Unknown notification authorization status")
            }
            Task { @MainActor in
                self?.onboardingNotificationPermission = status
            }
        }
    }

    func refreshOnboardingChecklistStateAfterExternalPermissionChange() {
        onboardingPermissionRefreshSequenceTask?.cancel()
        onboardingPermissionRefreshSequenceTask = Task { [weak self] in
            for delay in [UInt64(0), 500_000_000, 1_500_000_000, 3_000_000_000] {
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: delay)
                }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.refreshOnboardingChecklistState()
                }
            }
        }
    }

    func requestNotificationPermissionForOnboarding() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
            Task { @MainActor in
                self?.refreshOnboardingChecklistState()
            }
        }
    }

    private static func onboardingPermission(from status: RecordingPermissionStatus) -> OnboardingPermissionStatus {
        switch status {
        case .unknown:
            return .unknown
        case .granted:
            return .granted
        case .denied:
            return .denied
        case .unavailable(let reason):
            return .unsupported(reason)
        }
    }

    func toggleRecording() {
        switch state {
        case .idle:
            startRecording()
        case .recording:
            stopRecording()
        case .processing:
            break
        }
    }

    func startRecording() {
        startRecording(detectedAppName: nil, preferredCaptureSource: nil)
    }

    private func startRecording(
        detectedAppName: String?,
        preferredCaptureSource: AppAudioCaptureSource?
    ) {
        guard state == .idle else { return }
        lastError = nil
        if let blocker = onboardingChecklist.firstRecordingBlocker {
            lastError = blocker
            return
        }
        state = .recording
        currentTranscript = []
        currentSpeakerProfiles = [:]
        pendingSpeakerTagID = nil
        deferredSpeakerTagIDs = []
        currentMeetingStart = Date()
        currentDetectedAppName = detectedAppName
        currentPreferredCaptureSource = preferredCaptureSource
        recordingDuration = 0

        // Reset AI Coach state for the new recording
        coachInsights = []
        coachAnalyzing = false
        coachAnalyzingInFlight = false
        coachLastAnalyzedSegmentCount = 0
        coachLastAnalyzedTime = nil
        startCoachLoopIfEnabled()

        // Start duration timer
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.currentMeetingStart else { return }
                self.recordingDuration = Date().timeIntervalSince(start)
            }
        }

        Task {
            // Load model first so it's ready before audio buffers arrive
            await transcriptionEngine.warmup()

            do {
                try await audioCaptureManager.startCapture(preferredSource: preferredCaptureSource)
                print("[MeetingManager] Audio capture started successfully")
            } catch {
                print("[MeetingManager] Failed to start audio capture: \(error)")
                lastError = "Audio capture failed: \(error.localizedDescription). Check Screen Recording and Microphone permissions in System Settings > Privacy & Security."
                stopDurationTimer()
                stopCoachLoop()
                state = .idle
                currentDetectedAppName = nil
                currentPreferredCaptureSource = nil
            }
        }
    }

    func stopRecording() {
        guard state == .recording else { return }
        recordingTimer?.invalidate()
        recordingTimer = nil
        stopCoachLoop()
        audioCaptureManager.stopCapture()

        let appName = currentDetectedAppName ?? meetingDetector.detectedApp ?? teamsCallDetectorV5.detectedApp ?? "Meeting"
        let dateStr = currentMeetingStart?.formatted(date: .abbreviated, time: .shortened) ?? Date().formatted(date: .abbreviated, time: .shortened)
        pendingMeetingName = "\(appName) — \(dateStr)"
        showMeetingNamePrompt = true
    }

    func finishRecording(name: String) {
        showMeetingNamePrompt = false
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? pendingMeetingName
            : name.trimmingCharacters(in: .whitespacesAndNewlines)
        state = .processing
        currentDetectedAppName = nil
        currentPreferredCaptureSource = nil

        Task {
            await transcriptionEngine.reset()

            let transcript = currentTranscript
            let speakerProfiles = currentSpeakerProfiles
            let transcriptText = MeetingCaptureWorkflow.summaryInput(
                from: transcript,
                speakerLabels: [:],
                speakerProfiles: speakerProfiles
            )

            let modelName = UserDefaults.standard.string(forKey: "llmModel") ?? "deepseek/deepseek-chat-v3"
            summarizationStatus = .summarizing(model: modelName)

            let summary: MeetingSummary
            do {
                summary = try await summarizationEngine.summarize(transcript: transcriptText)
                summarizationStatus = .idle
            } catch {
                print("[MeetingManager] Summarization failed: \(error)")
                lastError = "Summarization failed: \(error.localizedDescription)"
                summarizationStatus = .failed(error: error.localizedDescription)
                summary = MeetingCaptureWorkflow.failedSummary(errorDescription: error.localizedDescription)
            }

            let meeting = MeetingCaptureWorkflow.makeMeeting(
                title: title,
                startedAt: currentMeetingStart,
                transcript: transcript,
                summary: summary,
                speakerProfiles: speakerProfiles
            )

            do {
                try meetingStore.save(meeting: meeting)
                meetings.insert(meeting, at: 0)
                syncActionItemsToTasks(for: meeting)
            } catch {
                print("Failed to save meeting: \(error)")
            }

            ExportManager.autoExportIfEnabled(meeting)
            await notificationManager.sendSummaryReady(meetingTitle: meeting.title)
            state = .idle
            pendingSpeakerTagID = nil
            deferredSpeakerTagIDs = []
        }
    }

    func toggleActionItem(meetingId: UUID, actionItemId: String) {
        guard let index = meetings.firstIndex(where: { $0.id == meetingId }) else { return }
        guard let itemIndex = meetings[index].summary.actionItems.firstIndex(where: { $0.id == actionItemId }) else { return }

        meetings[index].summary.actionItems[itemIndex].isCompleted.toggle()
        let completed = meetings[index].summary.actionItems[itemIndex].isCompleted

        // Persist the change
        do {
            try meetingStore.save(meeting: meetings[index])
            syncActionItemsToTasks(for: meetings[index])
            syncLinkedTaskCompletion(
                meetingID: meetingId,
                actionItemID: actionItemId,
                completed: completed
            )
        } catch {
            print("Failed to save action item toggle: \(error)")
        }
    }

    func draftFollowUp(for meeting: Meeting) async throws -> String {
        try await summarizationEngine.draftFollowUp(meeting: meeting)
    }

    func resummarize(meeting: Meeting) async throws -> Meeting {
        debugLog("resummarize called for meeting \(meeting.id), transcript count=\(meeting.transcript.count)")

        let transcriptText = MeetingCaptureWorkflow.summaryInput(
            from: meeting.transcript,
            speakerLabels: meeting.speakerLabels,
            speakerProfiles: meeting.speakerProfiles
        )

        debugLog("transcript text length=\(transcriptText.count)")

        let summary: MeetingSummary
        do {
            summary = try await summarizationEngine.summarize(transcript: transcriptText)
            debugLog("summarize succeeded, decisions=\(summary.decisions.count) items=\(summary.actionItems.count)")
        } catch {
            debugLog("summarize FAILED: \(error)")
            throw error
        }

        var updated = meeting
        updated.summary = summary
        for section in MeetingSummarySection.allCases {
            updated.summary.mark(section, state: .generated)
        }

        try meetingStore.save(meeting: updated)

        if let index = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[index] = updated
        }

        syncActionItemsToTasks(for: updated)

        debugLog("meeting updated and saved")
        return updated
    }

    func regenerateSummarySection(_ section: MeetingSummarySection, meeting: Meeting) async throws -> Meeting {
        debugLog("regenerateSummarySection \(section.rawValue) called for meeting \(meeting.id)")

        let content = try await summarizationEngine.regenerateSection(section, meeting: meeting)
        var updated = meeting
        updated.summary.replace(section, with: content, state: .generated)

        try meetingStore.save(meeting: updated)

        if let index = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[index] = updated
        }

        if section == .actionItems {
            syncActionItemsToTasks(for: updated)
        }

        debugLog("regenerated section \(section.rawValue) and saved")
        return updated
    }

    @discardableResult
    func updateSummarySection(
        _ section: MeetingSummarySection,
        content: MeetingSummarySectionContent,
        meeting: Meeting
    ) -> Meeting {
        var updated = meeting
        updated.summary.replace(section, with: content, state: .userEdited)

        do {
            try meetingStore.save(meeting: updated)
            if let index = meetings.firstIndex(where: { $0.id == meeting.id }) {
                meetings[index] = updated
            }
            if section == .actionItems {
                syncActionItemsToTasks(for: updated)
            }
        } catch {
            print("Failed to save edited summary section: \(error)")
        }

        return updated
    }

    @discardableResult
    func updateSpeakerLabel(meeting: Meeting, speakerID: String, displayName: String) -> Meeting {
        var updated = meeting
        updated.setSpeakerLabel(speakerID: speakerID, displayName: displayName)

        do {
            try meetingStore.save(meeting: updated)
            if let index = meetings.firstIndex(where: { $0.id == meeting.id }) {
                meetings[index] = updated
            }
        } catch {
            print("Failed to save speaker label: \(error)")
        }

        return updated
    }

    @discardableResult
    func updateSpeakerProfile(meeting: Meeting, profile: SpeakerProfile) -> Meeting {
        var updated = meeting
        updated.setSpeakerProfile(profile)

        do {
            try meetingStore.save(meeting: updated)
            if let index = meetings.firstIndex(where: { $0.id == meeting.id }) {
                meetings[index] = updated
            }
        } catch {
            print("Failed to save speaker profile: \(error)")
        }

        return updated
    }

    var pendingSpeakerProfile: SpeakerProfile? {
        guard let pendingSpeakerTagID else { return nil }
        return currentSpeakerProfiles[pendingSpeakerTagID] ?? SpeakerProfile(speakerID: pendingSpeakerTagID)
    }

    func currentSpeakerDisplayName(for segment: TranscriptSegment) -> String {
        TranscriptSpeakerLabels.displayName(
            for: TranscriptSpeakerLabels.speakerID(for: segment),
            labels: [:],
            profiles: currentSpeakerProfiles
        )
    }

    func saveCurrentSpeakerProfile(_ profile: SpeakerProfile) {
        currentSpeakerProfiles = TranscriptSpeakerLabels.settingProfile(profile, in: currentSpeakerProfiles)
        deferredSpeakerTagIDs.remove(profile.speakerID)
        if pendingSpeakerTagID == profile.speakerID {
            pendingSpeakerTagID = nil
        }
        refreshPendingSpeakerTag()
    }

    func deferCurrentSpeakerPrompt() {
        guard let speakerID = pendingSpeakerTagID else { return }
        deferredSpeakerTagIDs.insert(speakerID)
        pendingSpeakerTagID = nil
        refreshPendingSpeakerTag()
    }

    private func refreshPendingSpeakerTag() {
        if let pendingSpeakerTagID,
           TranscriptSpeakerLabels.isTagged(
                speakerID: pendingSpeakerTagID,
                labels: [:],
                profiles: currentSpeakerProfiles
           ) {
            self.pendingSpeakerTagID = nil
        }

        guard pendingSpeakerTagID == nil else { return }
        pendingSpeakerTagID = TranscriptSpeakerLabels.untaggedSpeakerIDs(
            in: currentTranscript,
            profiles: currentSpeakerProfiles,
            deferredSpeakerIDs: deferredSpeakerTagIDs
        ).first
    }

    private func debugLog(_ message: String) {
        let logFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("NoteAI/debug.log")
        let line = "[\(Date())] \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFile.path) {
                if let handle = try? FileHandle(forWritingTo: logFile) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: logFile)
            }
        }
    }

    // MARK: - Notes

    @discardableResult
    func createNote(title: String = "Untitled", content: String = "", tags: [String] = [], space: String? = nil, sourceMeetingID: UUID? = nil) -> Note {
        let note = Note(title: title, content: content, tags: tags, space: space, sourceMeetingID: sourceMeetingID)
        do {
            try meetingStore.saveNote(note)
            ensureNoteSpace(note.space)
            notes.insert(note, at: 0)
        } catch {
            print("Failed to save note: \(error)")
        }
        return note
    }

    func updateNote(_ note: Note) {
        var updated = note
        updated.modifiedDate = Date()
        do {
            try meetingStore.saveNote(updated)
            ensureNoteSpace(updated.space)
            if let index = notes.firstIndex(where: { $0.id == note.id }) {
                notes[index] = updated
            }
        } catch {
            print("Failed to update note: \(error)")
        }
    }

    @discardableResult
    func createNoteSpace(_ rawName: String) -> String? {
        guard let name = NoteSpaceOrganizer.normalized(rawName) else { return nil }
        ensureNoteSpace(name)
        return name
    }

    func assignNote(_ noteID: UUID, toSpace rawSpace: String?) {
        guard let index = notes.firstIndex(where: { $0.id == noteID }) else { return }
        var note = notes[index]
        note.space = NoteSpaceOrganizer.normalized(rawSpace)
        updateNote(note)
    }

    @discardableResult
    func renameNoteSpace(_ oldName: String, to newName: String) -> Bool {
        guard let mutation = NoteSpaceOrganizer.renamingSpace(
            oldName,
            to: newName,
            spaces: noteSpaces,
            notes: notes
        ) else { return false }

        return applyNoteSpaceMutation(mutation)
    }

    @discardableResult
    func deleteNoteSpace(_ name: String) -> Bool {
        guard let mutation = NoteSpaceOrganizer.deletingSpace(
            name,
            spaces: noteSpaces,
            notes: notes
        ) else { return false }

        return applyNoteSpaceMutation(mutation)
    }

    private func applyNoteSpaceMutation(_ mutation: NoteSpaceMutation) -> Bool {
        let currentNotesByID = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
        let now = Date()
        var updatedNotes = mutation.notes
        var changedNotes: [Note] = []

        for index in updatedNotes.indices {
            guard currentNotesByID[updatedNotes[index].id]?.space != updatedNotes[index].space else { continue }
            updatedNotes[index].modifiedDate = now
            changedNotes.append(updatedNotes[index])
        }

        do {
            for note in changedNotes {
                try meetingStore.saveNote(note)
            }
            notes = updatedNotes
            noteSpaces = mutation.spaces
            saveNoteSpaces()
            return true
        } catch {
            print("Failed to update note space: \(error)")
            return false
        }
    }

    private func ensureNoteSpace(_ rawSpace: String?) {
        guard let space = NoteSpaceOrganizer.normalized(rawSpace) else { return }
        guard !noteSpaces.contains(where: { $0.caseInsensitiveCompare(space) == .orderedSame }) else { return }
        noteSpaces.append(space)
        noteSpaces = NoteSpaceOrganizer.orderedSpaceTitles(noteSpaces)
        saveNoteSpaces()
    }

    private func loadNoteSpaces() {
        noteSpaces = NoteSpaceOrganizer.orderedSpaceTitles(
            UserDefaults.standard.stringArray(forKey: Self.noteSpacesDefaultsKey) ?? []
        )
    }

    private func saveNoteSpaces() {
        UserDefaults.standard.set(noteSpaces, forKey: Self.noteSpacesDefaultsKey)
    }

    func deleteNote(_ note: Note) {
        do {
            try meetingStore.deleteNote(id: note.id)
            notes.removeAll { $0.id == note.id }
        } catch {
            print("Failed to delete note: \(error)")
        }
    }

    func createNoteFromMeeting(_ meeting: Meeting) -> Note {
        let markdown = ExportManager.exportAsMarkdown(meeting)
        return createNote(
            title: meeting.title,
            content: markdown,
            tags: meeting.summary.topics.prefix(5).map { $0 },
            sourceMeetingID: meeting.id
        )
    }

    // MARK: - Notion Import

    func importNotesFromNotion(directoryURL: URL) throws -> NotionImporter.ImportResult {
        let result = try NotionImporter.importNotes(from: directoryURL)
        for note in result.imported {
            do {
                try meetingStore.saveNote(note)
                notes.insert(note, at: 0)
            } catch {
                print("Failed to save imported note '\(note.title)': \(error)")
            }
        }
        // Sort notes by modified date after bulk import
        notes.sort { $0.modifiedDate > $1.modifiedDate }
        return result
    }

    func notesInRange(start: Date, end: Date) -> [Note] {
        LibraryOperations.notesInRange(notes, start: start, end: end)
    }

    private func loadNotes() {
        do {
            notes = try meetingStore.fetchAllNotes()
        } catch {
            print("Failed to load notes: \(error)")
        }
    }

    // MARK: - Todos

    @discardableResult
    func createTodo(title: String = "", description: String = "", dueDate: Date? = nil) -> TodoItem {
        let todo = TodoItem(title: title, description: description, dueDate: dueDate)
        do {
            try meetingStore.saveTodo(todo)
            todos.insert(todo, at: 0)
        } catch {
            print("Failed to save todo: \(error)")
        }
        return todo
    }

    func updateTodo(_ todo: TodoItem) {
        var updated = todo
        updated.modifiedDate = Date()
        do {
            try meetingStore.saveTodo(updated)
            if let index = todos.firstIndex(where: { $0.id == todo.id }) {
                todos[index] = updated
            }
        } catch {
            print("Failed to update todo: \(error)")
        }
    }

    func toggleTodoCompletion(_ todo: TodoItem) {
        var updated = todo
        updated.completed.toggle()
        updated.modifiedDate = Date()
        updateTodo(updated)
    }

    func deleteTodo(_ todo: TodoItem) {
        do {
            try meetingStore.deleteTodo(id: todo.id)
            todos.removeAll { $0.id == todo.id }
        } catch {
            print("Failed to delete todo: \(error)")
        }
    }

    func todosInRange(start: Date, end: Date) -> [TodoItem] {
        todos.filter { $0.createdDate >= start && $0.createdDate <= end }
    }

    func todosLinked(to meetingID: UUID) -> [TodoItem] {
        todos.filter { $0.isLinked(to: meetingID) }
    }

    private func loadTodos() {
        do {
            todos = try meetingStore.fetchAllTodos()
        } catch {
            print("Failed to load todos: \(error)")
        }
    }

    // MARK: - Tasks

    @discardableResult
    func createTask(
        title: String = "",
        description: String = "",
        status: TaskItem.Status = .open,
        workDate: Date? = nil,
        sourceMetadata: TaskItem.SourceMetadata? = nil
    ) -> TaskItem {
        let now = Date()
        let task = TaskItem(
            title: title,
            description: description,
            status: status,
            workDate: workDate,
            completedDate: status == .completed ? (workDate ?? now) : nil,
            sourceMetadata: sourceMetadata,
            createdDate: now,
            modifiedDate: now
        )
        do {
            try meetingStore.saveTask(task)
            tasks.insert(task, at: 0)
        } catch {
            print("Failed to save task: \(error)")
        }
        return task
    }

    func updateTask(_ task: TaskItem) {
        var updated = task
        updated.modifiedDate = Date()
        if updated.status == .completed && updated.completedDate == nil {
            updated.completedDate = updated.modifiedDate
        } else if updated.status == .open {
            updated.completedDate = nil
        }
        do {
            try meetingStore.saveTask(updated)
            if let index = tasks.firstIndex(where: { $0.id == task.id }) {
                tasks[index] = updated
            }
        } catch {
            print("Failed to update task: \(error)")
        }
    }

    func toggleTaskCompletion(_ task: TaskItem) {
        var updated = task
        if updated.status == .completed {
            updated.status = .open
            updated.completedDate = nil
        } else {
            updated.status = .completed
            updated.completedDate = Date()
        }
        updated.modifiedDate = Date()
        updateTask(updated)
        syncActionItemCompletionFromTask(updated)
    }

    func deleteTask(_ task: TaskItem) {
        do {
            try meetingStore.deleteTask(id: task.id)
            tasks.removeAll { $0.id == task.id }
        } catch {
            print("Failed to delete task: \(error)")
        }
    }

    func tasksInRange(start: Date, end: Date) -> [TaskItem] {
        tasks.filter { $0.activityDate >= start && $0.activityDate <= end }
    }

    func tasksLinked(to meetingID: UUID) -> [TaskItem] {
        tasks.filter { $0.isLinked(to: meetingID) }
    }

    private func loadTasks() {
        do {
            tasks = try meetingStore.fetchAllTasks()
        } catch {
            print("Failed to load tasks: \(error)")
        }
    }

    private func syncActionItemsToTasks(for meeting: Meeting) {
        let merged = TaskItem.mergingActionLinkedTasks(existing: tasks, meeting: meeting)
        let existingByID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        let changedTasks = merged.filter { existingByID[$0.id] != $0 }
        guard !changedTasks.isEmpty else { return }

        do {
            for task in changedTasks {
                try meetingStore.saveTask(task)
            }
            tasks = merged
        } catch {
            print("Failed to sync action item tasks: \(error)")
        }
    }

    private func syncLinkedTaskCompletion(meetingID: UUID, actionItemID: String, completed: Bool) {
        for index in tasks.indices {
            guard tasks[index].sourceMeetingID == meetingID,
                  tasks[index].sourceActionItemID == actionItemID,
                  tasks[index].isCompleted != completed else { continue }

            var updated = tasks[index]
            updated.status = completed ? .completed : .open
            updated.completedDate = completed ? Date() : nil
            updated.modifiedDate = Date()

            do {
                try meetingStore.saveTask(updated)
                tasks[index] = updated
            } catch {
                print("Failed to sync linked task completion: \(error)")
            }
        }
    }

    private func syncActionItemCompletionFromTask(_ task: TaskItem) {
        guard let sourceMeetingID = task.sourceMeetingID,
              let sourceActionItemID = task.sourceActionItemID,
              let meetingIndex = meetings.firstIndex(where: { $0.id == sourceMeetingID }),
              let actionIndex = meetings[meetingIndex].summary.actionItems.firstIndex(where: { $0.id == sourceActionItemID }),
              meetings[meetingIndex].summary.actionItems[actionIndex].isCompleted != task.isCompleted else {
            return
        }

        meetings[meetingIndex].summary.actionItems[actionIndex].isCompleted = task.isCompleted

        do {
            try meetingStore.save(meeting: meetings[meetingIndex])
        } catch {
            print("Failed to sync task completion back to action item: \(error)")
        }
    }

    // MARK: - T5T

    func meetingsInRange(start: Date, end: Date) -> [Meeting] {
        LibraryOperations.meetingsInRange(meetings, start: start, end: end)
    }

    func createT5TReport(
        periodStart: Date,
        periodEnd: Date,
        meetingIDs: [UUID],
        noteIDs: [UUID] = [],
        taskIDs: [UUID] = [],
        todoIDs: [UUID] = []
    ) async throws -> T5TReport {
        let selectedTasks = tasks.filter { taskIDs.contains($0.id) || todoIDs.contains($0.id) }
        guard !selectedTasks.isEmpty else {
            throw T5TError.noTasksSelected
        }

        let modelName = UserDefaults.standard.string(forKey: "llmModel") ?? "deepseek/deepseek-chat-v3"
        t5tGenerationStatus = .generating(model: modelName)

        let sections: T5TSections
        do {
            sections = try await summarizationEngine.generateT5T(
                meetings: [],
                notes: [],
                tasks: selectedTasks,
                config: t5tConfig,
                periodStart: periodStart,
                periodEnd: periodEnd
            )
            t5tGenerationStatus = .idle
        } catch {
            t5tGenerationStatus = .failed(error: error.localizedDescription)
            throw error
        }

        let report = T5TReport(
            id: UUID(),
            title: t5tDefaultTitle,
            createdDate: Date(),
            periodStart: periodStart,
            periodEnd: periodEnd,
            meetingIDs: [],
            noteIDs: [],
            taskIDs: taskIDs,
            todoIDs: todoIDs,
            sections: sections,
            status: .draft
        )

        try meetingStore.saveT5TReport(report)
        t5tReports.insert(report, at: 0)
        return report
    }

    func addT5TReport(_ report: T5TReport) {
        do {
            try meetingStore.saveT5TReport(report)
            t5tReports.insert(report, at: 0)
        } catch {
            print("Failed to save new T5T report: \(error)")
        }
    }

    func updateT5TReport(_ report: T5TReport) {
        do {
            try meetingStore.saveT5TReport(report)
            if let index = t5tReports.firstIndex(where: { $0.id == report.id }) {
                t5tReports[index] = report
            }
        } catch {
            print("Failed to save T5T report: \(error)")
        }
    }

    func deleteT5TReport(_ report: T5TReport) {
        do {
            try meetingStore.deleteT5TReport(id: report.id)
            t5tReports.removeAll { $0.id == report.id }
        } catch {
            print("Failed to delete T5T report: \(error)")
        }
    }

    func regenerateT5T(report: T5TReport) async throws -> T5TReport {
        let selectedTasks = tasks.filter { report.taskIDs.contains($0.id) || report.todoIDs.contains($0.id) }
        guard !selectedTasks.isEmpty else {
            throw T5TError.noTasksSelected
        }

        let modelName = UserDefaults.standard.string(forKey: "llmModel") ?? "deepseek/deepseek-chat-v3"
        t5tGenerationStatus = .generating(model: modelName)

        let sections: T5TSections
        do {
            sections = try await summarizationEngine.generateT5T(
                meetings: [],
                notes: [],
                tasks: selectedTasks,
                config: t5tConfig,
                periodStart: report.periodStart,
                periodEnd: report.periodEnd
            )
            t5tGenerationStatus = .idle
        } catch {
            t5tGenerationStatus = .failed(error: error.localizedDescription)
            throw error
        }

        var updated = report
        updated.sections = sections
        updated.meetingIDs = []
        updated.noteIDs = []
        updateT5TReport(updated)
        return updated
    }

    func saveT5TConfig(_ config: T5TConfig) {
        t5tConfig = config
        do {
            try meetingStore.saveT5TConfig(config)
        } catch {
            print("Failed to save T5T config: \(error)")
        }
    }

    private func loadT5TData() {
        do {
            t5tReports = try meetingStore.fetchAllT5TReports()
            t5tConfig = try meetingStore.loadT5TConfig() ?? .empty
        } catch {
            print("Failed to load T5T data: \(error)")
        }
    }

    private func formatPeriod(start: Date, end: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"
        return "\(fmt.string(from: start))–\(fmt.string(from: end))"
    }

    var t5tDefaultTitle: String {
        LibraryOperations.t5tDefaultTitle(config: t5tConfig)
    }

    func deleteMeeting(_ meeting: Meeting) {
        do {
            try meetingStore.delete(meetingId: meeting.id)
            meetings.removeAll { $0.id == meeting.id }
        } catch {
            print("Failed to delete meeting: \(error)")
        }
    }

    // MARK: - Private

    private func loadMeetings() {
        do {
            meetings = try meetingStore.fetchAll()
        } catch {
            print("Failed to load meetings: \(error)")
        }
    }

    private func setupToggleListener() {
        NotificationCenter.default.publisher(for: .toggleRecording)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.toggleRecording()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncAutoDetectionSettingsFromUserDefaults()
            }
            .store(in: &cancellables)
    }

    private func syncAutoDetectionSettingsFromUserDefaults() {
        let enabled = AutoDetectionDefaults.isEnabled()
        let engine = AutoDetectionDefaults.engine()

        if autoDetectionEngine != engine {
            autoDetectionEngine = engine
        }
        if autoDetectEnabled != enabled {
            autoDetectEnabled = enabled
        }
    }

    private func setupTranscriptionPipeline() {
        audioCaptureManager.onAudioBuffer = { [weak self] buffer in
            guard let self else { return }
            Task {
                do {
                    let segments = try await self.transcriptionEngine.transcribe(audioBuffer: buffer.buffer)
                    await MainActor.run {
                        self.currentTranscript.append(
                            contentsOf: TranscriptSpeakerLabels.assignPlaceholders(
                                to: segments,
                                fallbackSpeakerID: buffer.source.fallbackSpeakerID
                            )
                        )
                        self.refreshPendingSpeakerTag()
                    }
                } catch {
                    print("Transcription error: \(error)")
                }
            }
        }
        audioCaptureManager.onDiagnosticsChange = { [weak self] snapshot in
            Task { @MainActor in
                self?.recordingDiagnostics = snapshot
            }
        }
    }

    // MARK: - AI Coach loop

    func toggleCoach() {
        coachEnabled.toggle()
        if state == .recording {
            if coachEnabled {
                startCoachLoopIfEnabled()
            } else {
                stopCoachLoop()
            }
        }
    }

    private func startCoachLoopIfEnabled() {
        guard coachEnabled else { return }
        coachTimer?.invalidate()
        // Poll every 8 seconds — mirrors the web implementation in useAICoach.ts.
        coachTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.considerCoachAnalysis()
            }
        }
    }

    private func stopCoachLoop() {
        coachTimer?.invalidate()
        coachTimer = nil
    }

    /// Send a chat message to the AI SA. Appends the user message, awaits a
    /// reply using the current transcript + prior auto-insights, and appends
    /// the assistant response to `coachInsights`.
    func sendCoachMessage(_ question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !coachReplying else { return }

        let userMsg = CoachInsight(type: .keyInsight, content: trimmed, role: .user)
        coachInsights.append(userMsg)
        coachReplying = true

        let transcript = currentTranscript.map { $0.text }.joined(separator: " ")
        let chatHistory: [(role: CoachRole, content: String)] = coachInsights
            .compactMap { entry in
                guard let role = entry.role else { return nil }
                return (role: role, content: entry.content)
            }
        let priorInsights = coachInsights
            .filter { $0.role == nil }
            .map { $0.content }

        Task { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor in self.coachReplying = false }
            }
            do {
                let reply = try await self.aiCoachEngine.ask(
                    question: trimmed,
                    transcript: transcript,
                    chatHistory: chatHistory,
                    priorInsights: priorInsights
                )
                let cleaned = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty else { return }
                await MainActor.run {
                    self.coachInsights.append(
                        CoachInsight(type: .keyInsight, content: cleaned, role: .assistant)
                    )
                }
            } catch {
                let msg = "Reply failed: \(error.localizedDescription)"
                await MainActor.run {
                    self.coachInsights.append(
                        CoachInsight(type: .keyInsight, content: msg, role: .assistant)
                    )
                }
            }
        }
    }

    private func considerCoachAnalysis() {
        guard coachEnabled else { return }
        guard state == .recording else { return }
        guard !coachAnalyzingInFlight else { return }

        let segments = currentTranscript
        guard !segments.isEmpty else { return }

        let fullText = segments.map { $0.text }.joined(separator: " ")
        let words = fullText.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        guard words.count >= 25 else { return }

        // Enforce minimum interval between analyses
        if let last = coachLastAnalyzedTime {
            let elapsed = Date().timeIntervalSince(last)
            if elapsed < 45 { return }
            let newSegments = segments.count - coachLastAnalyzedSegmentCount
            if newSegments < 2 && elapsed < 90 { return }
        }

        coachAnalyzingInFlight = true
        coachAnalyzing = true
        let priorContents = coachInsights.map { $0.content }
        let currentCount = segments.count

        Task { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor in
                    self.coachAnalyzingInFlight = false
                    self.coachAnalyzing = false
                }
            }

            do {
                let new = try await self.aiCoachEngine.analyze(
                    transcript: fullText,
                    previousInsights: priorContents
                )
                await MainActor.run {
                    guard self.state == .recording else { return }
                    if !new.isEmpty {
                        self.coachInsights.append(contentsOf: new)
                    }
                    self.coachLastAnalyzedSegmentCount = currentCount
                    self.coachLastAnalyzedTime = Date()
                }
            } catch {
                print("[AICoach] Analysis failed: \(error.localizedDescription)")
                await MainActor.run {
                    self.coachLastAnalyzedTime = Date()
                }
            }
        }
    }

    private func setupAutoDetection() {
        meetingDetector.onMeetingStarted = { [weak self] in
            guard let self else { return }
            print("[MeetingManager] Auto-detection triggered — starting recording")
            self.startRecording(
                detectedAppName: self.meetingDetector.detectedApp,
                preferredCaptureSource: nil
            )
        }

        meetingDetector.onMeetingEnded = { [weak self] in
            guard let self else { return }
            print("[MeetingManager] Auto-detection: meeting ended — stopping recording")
            self.stopRecording()
        }

        teamsCallDetectorV5.onCallStarted = { [weak self] context in
            guard let self else { return }
            print("[MeetingManager] V5 Teams detection triggered — starting recording")
            self.startRecording(
                detectedAppName: context.displayName,
                preferredCaptureSource: .processID(context.processID, displayName: context.displayName)
            )
        }

        teamsCallDetectorV5.onCallEnded = { [weak self] in
            guard let self else { return }
            print("[MeetingManager] V5 Teams detection: call ended — stopping recording")
            self.stopRecording()
        }

        // Start monitoring if previously enabled
        updateAutoDetectionMonitoring()
    }

    private func updateAutoDetectionMonitoring() {
        meetingDetector.stopMonitoring()
        teamsCallDetectorV5.stopMonitoring()

        guard autoDetectEnabled else { return }

        switch autoDetectionEngine {
        case .classicV4:
            meetingDetector.startMonitoring()
        case .teamsV5:
            teamsCallDetectorV5.startMonitoring()
        }
    }
}

extension MeetingManager: LocalCaptureControlling {
    var snapshot: LocalCaptureSessionSnapshot {
        guard let sessionId = localHelperSessionId,
              let startedAt = currentMeetingStart,
              state == .recording else {
            return .idle
        }

        return LocalCaptureSessionSnapshot(
            sessionId: sessionId,
            state: "recording",
            recordingIndicator: "visible-recording",
            startedAt: startedAt,
            duration: Date().timeIntervalSince(startedAt),
            transcript: currentTranscript.map(LocalCaptureTranscriptSegment.init(segment:))
        )
    }

    func startCapture(_ request: LocalCaptureStartRequest) async throws -> LocalCaptureStartResponse {
        try await startLocalHelperCapture(request)
    }

    func stopCapture() async throws -> LocalCaptureStopResponse {
        try await stopLocalHelperCapture()
    }

    private func startLocalHelperCapture(_ request: LocalCaptureStartRequest) async throws -> LocalCaptureStartResponse {
        guard request.source == "teamsDesktop" else {
            throw LocalHelperCaptureError.unsupportedSource
        }
        guard state == .idle else {
            throw LocalHelperCaptureError.alreadyRecording
        }

        lastError = nil
        let sessionId = UUID()
        let startedAt = Date()
        localHelperSessionId = sessionId
        state = .recording
        currentTranscript = []
        currentSpeakerProfiles = [:]
        pendingSpeakerTagID = nil
        deferredSpeakerTagIDs = []
        currentMeetingStart = startedAt
        recordingDuration = 0
        resetCoachStateForRecording()
        startCoachLoopIfEnabled()
        startDurationTimer()

        await transcriptionEngine.reset()
        await transcriptionEngine.warmup()

        do {
            try await audioCaptureManager.startCapture()
            print("[MeetingManager] Local helper capture started successfully")
        } catch {
            print("[MeetingManager] Local helper capture failed: \(error)")
            lastError = "Audio capture failed: \(error.localizedDescription). Check Screen Recording and Microphone permissions in System Settings > Privacy & Security."
            audioCaptureManager.stopCapture()
            stopDurationTimer()
            stopCoachLoop()
            localHelperSessionId = nil
            currentMeetingStart = nil
            recordingDuration = 0
            state = .idle
            throw LocalHelperCaptureError.startFailed(error.localizedDescription)
        }

        return LocalCaptureStartResponse(
            sessionId: sessionId,
            captureState: "recording",
            startedAt: startedAt,
            recordingIndicator: "visible-recording"
        )
    }

    private func stopLocalHelperCapture() async throws -> LocalCaptureStopResponse {
        guard state == .recording,
              let sessionId = localHelperSessionId,
              let startedAt = currentMeetingStart else {
            throw LocalHelperCaptureError.notRecording
        }

        stopDurationTimer()
        stopCoachLoop()
        audioCaptureManager.stopCapture()
        await transcriptionEngine.reset()

        let stoppedAt = Date()
        let duration = stoppedAt.timeIntervalSince(startedAt)
        let transcript = currentTranscript.map(LocalCaptureTranscriptSegment.init(segment:))

        localHelperSessionId = nil
        currentMeetingStart = nil
        recordingDuration = duration
        state = .idle

        return LocalCaptureStopResponse(
            sessionId: sessionId,
            captureState: "stopped",
            startedAt: startedAt,
            stoppedAt: stoppedAt,
            duration: duration,
            transcript: transcript
        )
    }

    private func resetCoachStateForRecording() {
        coachInsights = []
        coachAnalyzing = false
        coachAnalyzingInFlight = false
        coachLastAnalyzedSegmentCount = 0
        coachLastAnalyzedTime = nil
    }

    private func startDurationTimer() {
        stopDurationTimer()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.currentMeetingStart else { return }
                self.recordingDuration = Date().timeIntervalSince(start)
            }
        }
    }

    private func stopDurationTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }
}

private extension LocalCaptureTranscriptSegment {
    init(segment: TranscriptSegment) {
        self.init(
            id: segment.id,
            text: segment.text,
            startTime: segment.startTime,
            endTime: segment.endTime,
            speaker: TranscriptSpeakerLabels.speakerID(for: segment),
            confidence: segment.confidence
        )
    }
}

private enum LocalHelperCaptureError: LocalizedError {
    case unsupportedSource
    case alreadyRecording
    case notRecording
    case startFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSource:
            return "Only Teams Desktop capture can be started by the local helper."
        case .alreadyRecording:
            return "NoteAI is already recording."
        case .notRecording:
            return "NoteAI is not recording a Teams Desktop session."
        case .startFailed(let reason):
            return reason
        }
    }
}

enum T5TError: LocalizedError {
    case noTasksSelected

    var errorDescription: String? {
        switch self {
        case .noTasksSelected:
            return "No tasks selected for T5T generation."
        }
    }
}
