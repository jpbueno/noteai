import Foundation
import Combine
import UserNotifications

/// Central orchestrator that coordinates audio capture, transcription, and summarization.
@MainActor
final class MeetingManager: ObservableObject {
    enum State: Equatable {
        case idle
        case recording
        case processing
    }

    @Published var state: State = .idle
    @Published var currentTranscript: [TranscriptSegment] = []
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
    @Published var autoDetectEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoDetectEnabled, forKey: "autoDetectMeetings")
            if autoDetectEnabled {
                meetingDetector.startMonitoring()
            } else {
                meetingDetector.stopMonitoring()
            }
        }
    }

    let meetingDetector = MeetingDetector()

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
    private var localHelperSessionId: UUID?
    private var recordingTimer: Timer?
    private var coachTimer: Timer?
    private var coachAnalyzingInFlight = false
    private var coachLastAnalyzedSegmentCount = 0
    private var coachLastAnalyzedTime: Date?
    private var cancellables = Set<AnyCancellable>()
    private var onboardingPermissionRefreshSequenceTask: Task<Void, Never>?

    init() {
        self.autoDetectEnabled = UserDefaults.standard.bool(forKey: "autoDetectMeetings")
        // Default coach to enabled; users can turn it off from the recording screen.
        if UserDefaults.standard.object(forKey: "aiCoachEnabled") == nil {
            self.coachEnabled = true
        } else {
            self.coachEnabled = UserDefaults.standard.bool(forKey: "aiCoachEnabled")
        }

        loadMeetings()
        loadNotes()
        loadT5TData()
        loadTodos()
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
        guard state == .idle else { return }
        lastError = nil
        if let blocker = onboardingChecklist.firstRecordingBlocker {
            lastError = blocker
            return
        }
        state = .recording
        currentTranscript = []
        currentMeetingStart = Date()
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
                try await audioCaptureManager.startCapture()
                print("[MeetingManager] Audio capture started successfully")
            } catch {
                print("[MeetingManager] Failed to start audio capture: \(error)")
                lastError = "Audio capture failed: \(error.localizedDescription). Check Screen Recording and Microphone permissions in System Settings > Privacy & Security."
                stopDurationTimer()
                stopCoachLoop()
                state = .idle
            }
        }
    }

    func stopRecording() {
        guard state == .recording else { return }
        recordingTimer?.invalidate()
        recordingTimer = nil
        stopCoachLoop()
        audioCaptureManager.stopCapture()

        let appName = meetingDetector.detectedApp ?? "Meeting"
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

        Task {
            await transcriptionEngine.reset()
            let meeting = await summarizeAndSaveMeeting(
                title: title,
                startedAt: currentMeetingStart,
                transcript: currentTranscript
            )
            if meeting != nil {
                currentTranscript = []
            }
            state = .idle
        }
    }

    func importTranscriptMeeting(title: String, rawTranscript: String) async -> Meeting? {
        guard state != .recording else {
            lastError = "Stop the active recording before importing a transcript."
            return nil
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTranscript = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else {
            lastError = "Paste a Teams transcript before importing."
            return nil
        }

        let transcript = TranscriptImportParser.parse(trimmedTranscript)
        let importTitle = trimmedTitle.isEmpty
            ? "Teams Transcript — \(Date().formatted(date: .abbreviated, time: .shortened))"
            : trimmedTitle
        let sourceEvidence = EvidenceSource(
            kind: .teamsTranscriptPaste,
            title: importTitle,
            externalID: nil,
            capturedAt: Date()
        )

        state = .processing
        currentTranscript = transcript

        let meeting = await summarizeAndSaveMeeting(
            title: importTitle,
            startedAt: Date(),
            transcript: transcript,
            sourceEvidence: sourceEvidence
        )

        currentTranscript = []
        state = .idle
        return meeting
    }

    private func summarizeAndSaveMeeting(
        title: String,
        startedAt: Date?,
        finishedAt: Date = Date(),
        transcript: [TranscriptSegment],
        sourceEvidence: EvidenceSource? = nil
    ) async -> Meeting? {
        let transcriptText = MeetingCaptureWorkflow.transcriptText(from: transcript)

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
            startedAt: startedAt,
            finishedAt: finishedAt,
            transcript: transcript,
            summary: summary,
            sourceEvidence: sourceEvidence
        )

        do {
            try meetingStore.save(meeting: meeting)
            meetings.insert(meeting, at: 0)
        } catch {
            print("Failed to save meeting: \(error)")
            lastError = "Failed to save meeting: \(error.localizedDescription)"
            return nil
        }

        ExportManager.autoExportIfEnabled(meeting)
        await notificationManager.sendSummaryReady(meetingTitle: meeting.title)
        return meeting
    }

    func toggleActionItem(meetingId: UUID, actionItemId: String) {
        guard let index = meetings.firstIndex(where: { $0.id == meetingId }) else { return }
        guard let itemIndex = meetings[index].summary.actionItems.firstIndex(where: { $0.id == actionItemId }) else { return }

        meetings[index].summary.actionItems[itemIndex].isCompleted.toggle()

        // Persist the change
        do {
            try meetingStore.save(meeting: meetings[index])
        } catch {
            print("Failed to save action item toggle: \(error)")
        }
    }

    func draftFollowUp(for meeting: Meeting) async throws -> String {
        try await summarizationEngine.draftFollowUp(meeting: meeting)
    }

    func resummarize(meeting: Meeting) async throws -> Meeting {
        debugLog("resummarize called for meeting \(meeting.id), transcript count=\(meeting.transcript.count)")

        let transcriptText = MeetingCaptureWorkflow.transcriptText(from: meeting.transcript)

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

        try meetingStore.save(meeting: updated)

        if let index = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[index] = updated
        }

        debugLog("meeting updated and saved")
        return updated
    }

    private func debugLog(_ message: String) {
        let logFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("\(AppEnvironment.storageNamespace)/debug.log")
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
    func createNote(title: String = "Untitled", content: String = "", tags: [String] = [], sourceMeetingID: UUID? = nil) -> Note {
        let note = Note(title: title, content: content, tags: tags, sourceMeetingID: sourceMeetingID)
        do {
            try meetingStore.saveNote(note)
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
            if let index = notes.firstIndex(where: { $0.id == note.id }) {
                notes[index] = updated
            }
        } catch {
            print("Failed to update note: \(error)")
        }
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

    private func loadTodos() {
        do {
            todos = try meetingStore.fetchAllTodos()
        } catch {
            print("Failed to load todos: \(error)")
        }
    }

    // MARK: - T5T

    func meetingsInRange(start: Date, end: Date) -> [Meeting] {
        LibraryOperations.meetingsInRange(meetings, start: start, end: end)
    }

    func createT5TReport(periodStart: Date, periodEnd: Date, meetingIDs: [UUID], noteIDs: [UUID] = [], todoIDs: [UUID] = []) async throws -> T5TReport {
        let selectedMeetings = meetings.filter { meetingIDs.contains($0.id) }
        let selectedNotes = notes.filter { noteIDs.contains($0.id) }
        let selectedTodos = todos.filter { todoIDs.contains($0.id) }
        guard !selectedMeetings.isEmpty || !selectedNotes.isEmpty || !selectedTodos.isEmpty else {
            throw T5TError.noMeetingsSelected
        }

        let modelName = UserDefaults.standard.string(forKey: "llmModel") ?? "deepseek/deepseek-chat-v3"
        t5tGenerationStatus = .generating(model: modelName)

        let sections: T5TSections
        do {
            sections = try await summarizationEngine.generateT5T(
                meetings: selectedMeetings,
                notes: selectedNotes,
                todos: selectedTodos,
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
            meetingIDs: meetingIDs,
            noteIDs: noteIDs,
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
        let selectedMeetings = meetings.filter { report.meetingIDs.contains($0.id) }
        let selectedNotes = notes.filter { report.noteIDs.contains($0.id) }
        let selectedTodos = todos.filter { report.todoIDs.contains($0.id) }
        guard !selectedMeetings.isEmpty || !selectedNotes.isEmpty || !selectedTodos.isEmpty else {
            throw T5TError.noMeetingsSelected
        }

        let modelName = UserDefaults.standard.string(forKey: "llmModel") ?? "deepseek/deepseek-chat-v3"
        t5tGenerationStatus = .generating(model: modelName)

        let sections: T5TSections
        do {
            sections = try await summarizationEngine.generateT5T(
                meetings: selectedMeetings,
                notes: selectedNotes,
                todos: selectedTodos,
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
    }

    private func setupTranscriptionPipeline() {
        audioCaptureManager.onAudioBuffer = { [weak self] buffer in
            guard let self else { return }
            Task {
                do {
                    let segments = try await self.transcriptionEngine.transcribe(audioBuffer: buffer)
                    await MainActor.run {
                        self.currentTranscript.append(contentsOf: segments)
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
            self.startRecording()
        }

        meetingDetector.onMeetingEnded = { [weak self] in
            guard let self else { return }
            print("[MeetingManager] Auto-detection: meeting ended — stopping recording")
            self.stopRecording()
        }

        // Start monitoring if previously enabled
        if autoDetectEnabled {
            meetingDetector.startMonitoring()
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
            speaker: segment.speaker,
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
    case noMeetingsSelected

    var errorDescription: String? {
        switch self {
        case .noMeetingsSelected:
            return "No meetings selected for T5T generation."
        }
    }
}
