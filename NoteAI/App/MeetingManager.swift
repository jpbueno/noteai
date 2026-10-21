import Foundation
import Combine
import UserNotifications

struct CoachOperationToken: Equatable, Sendable {
    fileprivate let epoch: UInt64
    fileprivate let sessionID: UUID
}

/// MainActor commit barrier for recording-scoped coach work.
@MainActor
final class CoachOperationEpoch {
    private var epoch: UInt64 = 0

    func invalidate() {
        epoch &+= 1
    }

    func capture(sessionID: UUID) -> CoachOperationToken {
        CoachOperationToken(epoch: epoch, sessionID: sessionID)
    }

    func allows(
        _ token: CoachOperationToken,
        coachEnabled: Bool,
        currentSessionID: UUID?
    ) -> Bool {
        coachEnabled
            && token.epoch == epoch
            && token.sessionID == currentSessionID
    }
}

/// Recording-scoped slot that severs retired actor generations synchronously.
@MainActor
final class CoachSessionSlot {
    typealias Factory = @MainActor (
        _ id: UUID,
        _ initialAutoInsights: [CoachInsight],
        _ initialChatMessages: [CoachChatMessage]
    ) -> LiveCoachSession

    private let factory: Factory
    private(set) var recordingID: UUID?
    private(set) var current: LiveCoachSession?

    init(factory: @escaping Factory) {
        self.factory = factory
    }

    func beginRecording() -> LiveCoachSession {
        let id = UUID()
        recordingID = id
        let session = factory(id, [], [])
        current = session
        return session
    }

    func resume(publishedEntries: [CoachInsight]) -> LiveCoachSession? {
        guard let recordingID else { return nil }
        if let current { return current }

        let autoInsights = publishedEntries.filter {
            $0.sessionID == recordingID && $0.role == nil
        }
        let chatMessages = publishedEntries.compactMap { entry -> CoachChatMessage? in
            guard entry.sessionID == recordingID, let role = entry.role else { return nil }
            return CoachChatMessage(
                id: entry.id,
                timestamp: entry.timestamp,
                sessionID: recordingID,
                role: role,
                content: entry.content
            )
        }
        let session = factory(recordingID, autoInsights, chatMessages)
        current = session
        return session
    }

    func retire() -> LiveCoachSession? {
        defer { current = nil }
        return current
    }

    func endRecording() -> LiveCoachSession? {
        recordingID = nil
        return retire()
    }
}

/// Central orchestrator that coordinates audio capture, transcription, and summarization.
@MainActor
final class MeetingManager: ObservableObject, CoachInsightLifecycleMutating {
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

    enum SummarizationStatus: Equatable {
        case idle
        case summarizing(model: String)
        case failed(error: String)
    }

    var filteredMeetings: [Meeting] {
        LibraryOperations.filter(meetings: meetings, query: searchQuery)
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
            if !coachEnabled {
                coachOperationEpoch.invalidate()
            }
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
    private lazy var coachSessionSlot = CoachSessionSlot { [unowned self] id, autoInsights, chatMessages in
        LiveCoachSession(
            id: id,
            generator: self.aiCoachEngine,
            initialAutoInsights: autoInsights,
            initialChatMessages: chatMessages
        )
    }
    private var liveCoachSession: LiveCoachSession? { coachSessionSlot.current }
    private var coachAnalysisTask: Task<Void, Never>?
    private var coachAnalysisOperationID: UUID?
    private var coachQuestionTask: Task<Void, Never>?
    private let coachOperationEpoch = CoachOperationEpoch()
    private var speakerAttribution = TranscriptSpeakerAttribution()
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
        speakerAttribution = TranscriptSpeakerAttribution()
        currentMeetingStart = Date()
        currentDetectedAppName = detectedAppName
        currentPreferredCaptureSource = preferredCaptureSource
        recordingDuration = 0

        resetCoachStateForRecording()
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
                endCoachSession()
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
        endCoachSession()
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
            let meeting = await summarizeAndSaveMeeting(
                title: title,
                startedAt: currentMeetingStart,
                transcript: transcript
            )
            if meeting != nil {
                currentTranscript = []
            }

            state = .idle
        }
    }

    func discardPendingRecording() {
        showMeetingNamePrompt = false
        pendingMeetingName = ""
        currentTranscript = []
        speakerAttribution = TranscriptSpeakerAttribution()
        currentMeetingStart = nil
        currentDetectedAppName = nil
        currentPreferredCaptureSource = nil
        recordingDuration = 0
        summarizationStatus = .idle
        coachInsights = []
        endCoachSession()
        state = .idle

        Task {
            await transcriptionEngine.reset()
        }
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

    func importTranscriptMeeting(title: String, rawTranscript: String) async -> Meeting? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let transcript = TranscriptImportParser.parse(rawTranscript)
        guard !transcript.isEmpty else {
            lastError = "Paste a Teams transcript before importing."
            return nil
        }

        state = .processing
        defer { state = .idle }

        let meetingTitle = trimmedTitle.isEmpty
            ? "Imported Teams Transcript"
            : trimmedTitle
        let sourceEvidence = EvidenceSource(
            kind: .teamsTranscriptPaste,
            title: meetingTitle,
            externalID: nil,
            capturedAt: Date()
        )

        return await summarizeAndSaveMeeting(
            title: meetingTitle,
            startedAt: Date(),
            transcript: transcript,
            sourceEvidence: sourceEvidence
        )
    }

    private func summarizeAndSaveMeeting(
        title: String,
        startedAt: Date?,
        finishedAt: Date = Date(),
        transcript: [TranscriptSegment],
        speakerProfiles: [String: SpeakerProfile] = [:],
        sourceEvidence: EvidenceSource? = nil
    ) async -> Meeting? {
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
            summary = MeetingCaptureWorkflow.failedSummary(error: error)
        }

        let meeting = MeetingCaptureWorkflow.makeMeeting(
            title: title,
            startedAt: startedAt,
            finishedAt: finishedAt,
            transcript: transcript,
            summary: summary,
            speakerProfiles: speakerProfiles,
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

    func currentSpeakerDisplayName(for segment: TranscriptSegment) -> String {
        TranscriptSpeakerLabels.displayName(
            for: TranscriptSpeakerLabels.speakerID(for: segment),
            labels: [:]
        )
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

    func meetingsInRange(start: Date, end: Date) -> [Meeting] {
        LibraryOperations.meetingsInRange(meetings, start: start, end: end)
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
                            contentsOf: self.speakerAttribution.attributedSegments(
                                segments,
                                source: buffer.source
                            )
                        )
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
        guard coachSessionSlot.resume(publishedEntries: coachInsights) != nil else { return }
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
        coachAnalysisTask?.cancel()
        coachQuestionTask?.cancel()
        coachAnalysisTask = nil
        coachAnalysisOperationID = nil
        coachQuestionTask = nil
        coachAnalyzing = false
        coachReplying = false
        retireCoachGeneration()
    }

    /// Send a chat message through the current recording-scoped coach session.
    func sendCoachMessage(_ question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard coachEnabled else { return }
        guard !trimmed.isEmpty else { return }
        guard !coachReplying else { return }
        guard let session = liveCoachSession else { return }
        let operationToken = coachOperationEpoch.capture(sessionID: session.id)

        coachInsights.append(CoachInsight(
            type: .keyInsight,
            content: trimmed,
            role: .user,
            sessionID: session.id
        ))
        coachReplying = true
        let transcript = currentTranscript

        coachQuestionTask = Task { [weak self] in
            let outcome = await session.ask(question: trimmed, transcript: transcript)
            guard let self,
                  self.coachOperationEpoch.allows(
                      operationToken,
                      coachEnabled: self.coachEnabled,
                      currentSessionID: self.liveCoachSession?.id
                  ) else { return }
            self.coachQuestionTask = nil
            self.coachReplying = false

            switch outcome {
            case .staleSession:
                return
            case .failed:
                print("[AICoach] Question request failed")
            case .ignored, .busy, .answered:
                break
            }
            await self.refreshCoachTimeline(from: session, operationToken: operationToken)
        }
    }

    @discardableResult
    func setAutoInsightLifecycle(
        id: UUID,
        lifecycle: CoachInsightLifecycle
    ) async -> CoachInsightLifecycleMutationOutcome {
        guard coachEnabled, let session = liveCoachSession else { return .staleSession }
        let operationToken = coachOperationEpoch.capture(sessionID: session.id)
        let outcome = await session.setAutoInsightLifecycle(id: id, lifecycle: lifecycle)
        guard coachOperationEpoch.allows(
            operationToken,
            coachEnabled: coachEnabled,
            currentSessionID: liveCoachSession?.id
        ) else { return .staleSession }
        if case .updated = outcome {
            await refreshCoachTimeline(from: session, operationToken: operationToken)
        }
        return outcome
    }

    private func considerCoachAnalysis() {
        guard coachEnabled else { return }
        guard state == .recording else { return }
        guard coachAnalysisTask == nil else { return }
        guard let session = liveCoachSession else { return }
        let operationToken = coachOperationEpoch.capture(sessionID: session.id)

        let transcript = currentTranscript
        let operationID = UUID()
        coachAnalysisOperationID = operationID

        coachAnalysisTask = Task { [weak self] in
            let isReady = await session.isAnalysisReady(transcript: transcript)
            guard let self,
                  self.coachOperationEpoch.allows(
                      operationToken,
                      coachEnabled: self.coachEnabled,
                      currentSessionID: self.liveCoachSession?.id
                  ),
                  self.state == .recording,
                  self.coachAnalysisOperationID == operationID else { return }
            guard isReady else {
                self.coachAnalysisTask = nil
                self.coachAnalysisOperationID = nil
                return
            }

            self.coachAnalyzing = true
            let outcome = await session.analyze(transcript: transcript)
            guard self.coachOperationEpoch.allows(
                      operationToken,
                      coachEnabled: self.coachEnabled,
                      currentSessionID: self.liveCoachSession?.id
                  ),
                  self.state == .recording,
                  self.coachAnalysisOperationID == operationID else { return }
            self.coachAnalysisTask = nil
            self.coachAnalysisOperationID = nil
            self.coachAnalyzing = false

            switch outcome {
            case .admitted:
                await self.refreshCoachTimeline(from: session, operationToken: operationToken)
            case .malformed(let reason):
                print("[AICoach] Malformed analysis response: \(reason)")
            case .failed:
                print("[AICoach] Analysis request failed")
            case .rejected(let rejections):
                print("[AICoach] Rejected \(rejections.count) candidate(s) by admission policy")
            case .notReady, .busy, .noOp, .staleSession:
                break
            }
        }
    }

    private func refreshCoachTimeline(
        from session: LiveCoachSession,
        operationToken: CoachOperationToken
    ) async {
        let snapshot = await session.snapshot()
        guard snapshot.sessionID == session.id,
              coachOperationEpoch.allows(
                  operationToken,
                  coachEnabled: coachEnabled,
                  currentSessionID: liveCoachSession?.id
              ) else { return }

        let chatEntries = snapshot.chatMessages.map { message in
            CoachInsight(
                id: message.id,
                timestamp: message.timestamp,
                type: .keyInsight,
                content: message.content,
                role: message.role,
                sessionID: message.sessionID
            )
        }
        coachInsights = (snapshot.autoInsights + chatEntries).sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            return lhs.id.uuidString < rhs.id.uuidString
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
            endCoachSession()
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
        endCoachSession()
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
        endCoachSession()
        _ = coachSessionSlot.beginRecording()
        coachInsights = []
        coachAnalyzing = false
        coachReplying = false
    }

    private func endCoachSession() {
        coachOperationEpoch.invalidate()
        let session = coachSessionSlot.endRecording()
        coachAnalysisTask?.cancel()
        coachQuestionTask?.cancel()
        coachAnalysisTask = nil
        coachAnalysisOperationID = nil
        coachQuestionTask = nil
        coachAnalyzing = false
        coachReplying = false
        if let session {
            Task { await session.cancel() }
        }
    }

    private func retireCoachGeneration() {
        coachOperationEpoch.invalidate()
        guard let session = coachSessionSlot.retire() else { return }
        Task { await session.cancel() }
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
