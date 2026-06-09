import XCTest
import SwiftUI
@testable import NoteAI

final class ArchitectureModuleTests: XCTestCase {
    func testV5AutoDetectionDefaultsArmTeamsSmartWhenNoEngineWasChosen() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "NoteAI.v5.auto-detect.default.\(UUID().uuidString)"))

        XCTAssertNil(defaults.object(forKey: AutoDetectionDefaults.engineKey))
        XCTAssertFalse(defaults.bool(forKey: AutoDetectionDefaults.autoDetectKey))

        AutoDetectionDefaults.migrateToV5DefaultsIfNeeded(defaults)

        XCTAssertTrue(defaults.bool(forKey: AutoDetectionDefaults.autoDetectKey))
        XCTAssertEqual(defaults.string(forKey: AutoDetectionDefaults.engineKey), AutoDetectionEngine.teamsV5.rawValue)
    }

    func testV5AutoDetectionMigrationPreservesExplicitEngineChoice() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "NoteAI.v5.auto-detect.explicit.\(UUID().uuidString)"))
        defaults.set(false, forKey: AutoDetectionDefaults.autoDetectKey)
        defaults.set(AutoDetectionEngine.classicV4.rawValue, forKey: AutoDetectionDefaults.engineKey)

        AutoDetectionDefaults.migrateToV5DefaultsIfNeeded(defaults)

        XCTAssertFalse(defaults.bool(forKey: AutoDetectionDefaults.autoDetectKey))
        XCTAssertEqual(defaults.string(forKey: AutoDetectionDefaults.engineKey), AutoDetectionEngine.classicV4.rawValue)
    }

    func testSidebarBrandShowsV5ReleaseLabel() throws {
        let source = try String(contentsOf: repositoryRoot()
            .appendingPathComponent("NoteAI/UI/MeetingLibrary/MeetingLibraryView.swift"))

        XCTAssertTrue(source.contains("Text(\"v5.0\")"))
        XCTAssertFalse(source.contains("Text(\"v4.0\")"))
    }

    func testNVIDIAModelCatalogIncludesOpus47BeforeOpus46() throws {
        let models = OpenRouterModels.models(for: .nvidia)

        let opus47Index = try XCTUnwrap(models.firstIndex { $0.id == "aws/anthropic/bedrock-claude-opus-4-7" })
        let opus46Index = try XCTUnwrap(models.firstIndex { $0.id == "azure/anthropic/claude-opus-4-6" })

        XCTAssertEqual(models[opus47Index].name, "Claude Opus 4.7")
        XCTAssertEqual(models[opus47Index].contextWindow, 1_000_000)
        XCTAssertLessThan(opus47Index, opus46Index)
    }

    func testChatPanelComposerSupportsMultilineAutosizing() throws {
        let source = try String(contentsOf: repositoryRoot()
            .appendingPathComponent("NoteAI/UI/Chat/ChatPanelView.swift"))

        XCTAssertTrue(source.contains("TextField(\"Ask anything...\", text: $inputText, axis: .vertical)"))
        XCTAssertTrue(source.contains(".lineLimit(1...5)"))
        XCTAssertFalse(source.contains("TextField(\"Ask anything...\", text: $inputText)\n"))
    }

    func testChatPanelAssistantMessagesExposeCopyAction() throws {
        let source = try String(contentsOf: repositoryRoot()
            .appendingPathComponent("NoteAI/UI/Chat/ChatPanelView.swift"))

        XCTAssertTrue(source.contains("copyAssistantMessageContent(content)"))
        XCTAssertTrue(source.contains("assistantMessageCopyButton(content)"))
        XCTAssertTrue(source.contains("private func assistantMessageCopyButton(_ content: String) -> some View"))
        XCTAssertTrue(source.contains("NSPasteboard.general.setString(content, forType: .string)"))
        XCTAssertTrue(source.contains("Label(\"Copy\", systemImage: \"doc.on.doc\")"))
        XCTAssertTrue(source.contains(".contextMenu"))
        XCTAssertTrue(source.contains("static let messageTextSelectionEnabled = false"))

        let messageTextRange = try XCTUnwrap(source.range(of: "Text(content)"))
        let copyButtonRange = try XCTUnwrap(source.range(of: "assistantMessageCopyButton(content)"))
        XCTAssertLessThan(messageTextRange.lowerBound, copyButtonRange.lowerBound)
    }

    func testProcessTapProviderTranslatesPIDToCoreAudioProcessObjectID() throws {
        let source = try String(contentsOf: repositoryRoot()
            .appendingPathComponent("NoteAI/Audio/ProcessTapProvider.swift"))

        XCTAssertTrue(source.contains("kAudioHardwarePropertyTranslatePIDToProcessObject"))
        XCTAssertFalse(source.contains("AudioObjectID(bitPattern: processID)"))
    }

    func testAudioConverterCacheKeyIncludesFullInputFormatForBluetoothRouteChanges() throws {
        let source = try String(contentsOf: repositoryRoot()
            .appendingPathComponent("NoteAI/Audio/AudioCaptureManager.swift"))

        XCTAssertTrue(source.contains("struct AudioConverterCacheKey: Hashable"))
        XCTAssertTrue(source.contains("let channelCount: AVAudioChannelCount"))
        XCTAssertTrue(source.contains("let commonFormat: AVAudioCommonFormat"))
        XCTAssertTrue(source.contains("let interleaved: Bool"))
        XCTAssertTrue(source.contains("converterCache[cacheKey]"))
        XCTAssertFalse(source.contains("converterCache[srcFormat.sampleRate]"))
    }

    func testMicrophoneCaptureEnablesVoiceProcessingBeforeReadingInputFormat() throws {
        let source = try String(contentsOf: repositoryRoot()
            .appendingPathComponent("NoteAI/Audio/MicrophoneCaptureManager.swift"))

        let voiceProcessingRange = try XCTUnwrap(source.range(of: "setVoiceProcessingEnabled(true)"))
        let formatRange = try XCTUnwrap(source.range(of: "let format = inputNode.outputFormat(forBus: 0)"))

        XCTAssertLessThan(voiceProcessingRange.lowerBound, formatRange.lowerBound)
    }

    func testLegacyNoteDecodesWithoutSpace() throws {
        let data = """
        {"id":"11111111-1111-1111-1111-111111111111","title":"Legacy","content":"Existing note","tags":["account"],"createdDate":0,"modifiedDate":0,"sourceMeetingID":null}
        """.data(using: .utf8)!

        let note = try JSONDecoder().decode(Note.self, from: data)

        XCTAssertNil(note.space)
    }

    func testNoteSpaceOrganizerGroupsNotesByNormalizedSpaceAndKeepsUnassignedVisible() {
        let projectNote = Note(
            title: "Project brief",
            content: "Blackwell rollout",
            space: "  Blackwell Launch  ",
            modifiedDate: Date(timeIntervalSince1970: 30)
        )
        let unassignedNote = Note(
            title: "Loose thought",
            content: "No current project",
            space: nil,
            modifiedDate: Date(timeIntervalSince1970: 20)
        )
        let blankSpaceNote = Note(
            title: "Blank space",
            content: "Whitespace should be unassigned",
            space: "   ",
            modifiedDate: Date(timeIntervalSince1970: 10)
        )

        let groups = NoteSpaceOrganizer.groups(for: [projectNote, unassignedNote, blankSpaceNote])

        XCTAssertEqual(groups.map(\.title), ["Blackwell Launch", "Unassigned"])
        XCTAssertEqual(groups[0].notes.map(\.id), [projectNote.id])
        XCTAssertEqual(groups[1].notes.map(\.id), [unassignedNote.id, blankSpaceNote.id])
    }

    func testNoteSpaceOrganizerKeepsExplicitEmptySpacesVisible() {
        let projectNote = Note(
            title: "Project brief",
            content: "Blackwell rollout",
            space: "  Roadmap  "
        )

        let groups = NoteSpaceOrganizer.groups(
            for: [projectNote],
            explicitSpaces: ["Customer Success", "Parking Lot", "  Customer Success  "],
            includeEmptyUnassigned: true
        )

        XCTAssertEqual(groups.map(\.title), ["Customer Success", "Parking Lot", "Roadmap", "Unassigned"])
        XCTAssertEqual(groups[0].notes.count, 0)
        XCTAssertEqual(groups[1].notes.count, 0)
        XCTAssertEqual(groups[2].notes.map(\.id), [projectNote.id])
        XCTAssertTrue(groups[3].isUnassigned)
        XCTAssertEqual(groups[3].notes.count, 0)
    }

    func testNoteSpaceOrganizerOrdersAndDeduplicatesSpaceTitles() {
        let titles = NoteSpaceOrganizer.orderedSpaceTitles([
            "  Roadmap  ",
            "customer success",
            "",
            "ROADMAP",
            "Customer Success"
        ])

        XCTAssertEqual(titles, ["customer success", "Roadmap"])
    }

    func testNoteSpaceOrganizerRenamesSpaceAndMergesExistingTarget() throws {
        let roadmapNote = Note(title: "Roadmap", content: "Plan", space: "Roadmap")
        let lowercasedRoadmapNote = Note(title: "Roadmap 2", content: "Plan", space: "roadmap")
        let customerNote = Note(title: "Customer", content: "Account", space: "Customer Success")
        let unassignedNote = Note(title: "Loose", content: "Idea", space: nil)

        let mutation = try XCTUnwrap(NoteSpaceOrganizer.renamingSpace(
            "  Roadmap ",
            to: "Customer Success",
            spaces: ["Roadmap", "Customer Success", "Parking Lot"],
            notes: [roadmapNote, lowercasedRoadmapNote, customerNote, unassignedNote]
        ))

        XCTAssertEqual(mutation.spaces, ["Customer Success", "Parking Lot"])
        XCTAssertEqual(mutation.notes.map(\.space), [
            "Customer Success",
            "Customer Success",
            "Customer Success",
            nil,
        ])
    }

    func testNoteSpaceOrganizerDeletesSpaceWithoutDeletingNotes() throws {
        let roadmapNote = Note(title: "Roadmap", content: "Plan", space: "Roadmap")
        let customerNote = Note(title: "Customer", content: "Account", space: "Customer Success")

        let mutation = try XCTUnwrap(NoteSpaceOrganizer.deletingSpace(
            "roadmap",
            spaces: ["Roadmap", "Customer Success"],
            notes: [roadmapNote, customerNote]
        ))

        XCTAssertEqual(mutation.spaces, ["Customer Success"])
        XCTAssertEqual(mutation.notes.map(\.id), [roadmapNote.id, customerNote.id])
        XCTAssertEqual(mutation.notes.map(\.space), [nil, "Customer Success"])
        XCTAssertNil(NoteSpaceOrganizer.deletingSpace(NoteSpaceOrganizer.unassignedTitle, spaces: ["Roadmap"], notes: [roadmapNote]))
    }

    func testLibraryOperationsFilterAcrossMeetingsAndNotes() {
        let meeting = Meeting(
            id: UUID(),
            title: "Roadmap Sync",
            date: Date(),
            duration: 120,
            transcript: [TranscriptSegment(text: "Discussed Grace roadmap")],
            summary: MeetingSummary(decisions: ["Ship preview"], topics: ["Inference"])
        )
        let note = Note(title: "Customer Notes", content: "Blackwell rollout", tags: ["account"])
        let result = LibraryOperations.filter(
            meetings: [meeting],
            notes: [note],
            query: "grace"
        )

        XCTAssertEqual(result.meetings.map(\.id), [meeting.id])
        XCTAssertEqual(result.notes.count, 0)
    }

    func testLibraryOperationsFilterMatchesNoteSpace() {
        let note = Note(
            title: "Customer Notes",
            content: "Blackwell rollout",
            tags: ["account"],
            space: "Customer Success"
        )

        let result = LibraryOperations.filter(
            meetings: [],
            notes: [note],
            query: "success"
        )

        XCTAssertEqual(result.notes.map(\.id), [note.id])
    }

    func testMeetingCaptureWorkflowFormatsTranscriptAndFallbackSummary() {
        let segments = [
            TranscriptSegment(id: 1, text: "Hello there", startTime: 3, speaker: "Alice", confidence: 0.9),
            TranscriptSegment(id: 2, text: "Follow up next week", startTime: 65, speaker: nil, confidence: 0.9),
        ]

        let text = MeetingCaptureWorkflow.transcriptText(from: segments)
        let fallback = MeetingCaptureWorkflow.failedSummary(errorDescription: "No key")

        XCTAssertTrue(text.contains("[00:03] Alice: Hello there"))
        XCTAssertTrue(text.contains("[01:05] Speaker 1: Follow up next week"))
        XCTAssertEqual(fallback.topics, ["Summarization failed: No key"])
        XCTAssertFalse(fallback.wasSummarized)
    }

    func testRecordingReadinessFallsBackToManualWhenCalendarAndDetectionAreMissing() {
        let readiness = MeetingRecordingReadiness.resolve(
            recordingState: .idle,
            autoDetectEnabled: true,
            detectionState: .monitoring,
            detectedApp: nil,
            calendarAuthorization: .denied,
            upcomingCalendarEvent: nil
        )

        XCTAssertEqual(readiness.mode, .manualFallback)
        XCTAssertEqual(readiness.title, "Manual recording")
        XCTAssertTrue(readiness.detail.contains("Calendar access is unavailable"))
        XCTAssertEqual(readiness.primaryActionTitle, "Start Recording")
    }

    func testRecordingReadinessSurfacesLikelyMeetingAppSignal() {
        let readiness = MeetingRecordingReadiness.resolve(
            recordingState: .idle,
            autoDetectEnabled: true,
            detectionState: .monitoring,
            detectedApp: "Microsoft Teams",
            calendarAuthorization: .notDetermined,
            upcomingCalendarEvent: nil
        )

        XCTAssertEqual(readiness.mode, .likelyMeeting)
        XCTAssertEqual(readiness.title, "Microsoft Teams detected")
        XCTAssertTrue(readiness.detail.contains("likely meeting signal"))
        XCTAssertEqual(readiness.badgeTitle, "Signal")
    }

    func testRecordingReadinessAutoArmsForUpcomingCalendarEvent() {
        let event = CalendarMeetingSignal(
            title: "Customer Sync",
            startDate: Date(timeIntervalSince1970: 1_000),
            endDate: Date(timeIntervalSince1970: 2_000)
        )

        let readiness = MeetingRecordingReadiness.resolve(
            recordingState: .idle,
            autoDetectEnabled: true,
            detectionState: .monitoring,
            detectedApp: nil,
            calendarAuthorization: .authorized,
            upcomingCalendarEvent: event
        )

        XCTAssertEqual(readiness.mode, .calendarArmed)
        XCTAssertEqual(readiness.title, "Customer Sync soon")
        XCTAssertTrue(readiness.detail.contains("auto-armed"))
        XCTAssertEqual(readiness.badgeTitle, "Armed")
    }

    func testSpeakerLabelingResolvesStablePlaceholdersAndOverrides() {
        var meeting = Meeting(
            id: UUID(),
            title: "Speaker Sync",
            date: Date(timeIntervalSince1970: 0),
            duration: 120,
            transcript: [
                TranscriptSegment(id: 1, text: "Fallback speaker.", startTime: 0, speaker: nil, confidence: 0.9),
                TranscriptSegment(id: 2, text: "Known placeholder.", startTime: 5, speaker: "speaker-2", confidence: 0.9),
                TranscriptSegment(id: 3, text: "Named participant.", startTime: 10, speaker: "Ana", confidence: 0.9),
            ],
            summary: MeetingSummary()
        )

        XCTAssertEqual(meeting.speakerID(for: meeting.transcript[0]), "speaker-1")
        XCTAssertEqual(meeting.speakerDisplayName(for: meeting.transcript[0]), "Speaker 1")
        XCTAssertEqual(meeting.speakerDisplayName(for: meeting.transcript[1]), "Speaker 2")
        XCTAssertEqual(meeting.speakerDisplayName(for: meeting.transcript[2]), "Ana")

        meeting.setSpeakerLabel(speakerID: "speaker-1", displayName: "JP")
        meeting.setSpeakerLabel(speakerID: "speaker-2", displayName: "Customer")

        XCTAssertEqual(meeting.speakerDisplayName(for: meeting.transcript[0]), "JP")
        XCTAssertEqual(meeting.speakerDisplayName(for: meeting.transcript[1]), "Customer")
    }

    func testMeetingCaptureWorkflowAssignsPlaceholderSpeakersBeforePersisting() {
        let meeting = MeetingCaptureWorkflow.makeMeeting(
            title: "Fallback Speakers",
            startedAt: Date(timeIntervalSince1970: 0),
            finishedAt: Date(timeIntervalSince1970: 30),
            transcript: [
                TranscriptSegment(id: 1, text: "We need a stable label.", startTime: 0, speaker: nil, confidence: 0.9)
            ],
            summary: MeetingSummary()
        )

        XCTAssertEqual(meeting.transcript.first?.speaker, "speaker-1")
        XCTAssertEqual(meeting.speakerDisplayName(for: meeting.transcript[0]), "Speaker 1")
    }

    func testAudioSourcePlaceholdersSeparateLocalAndRemoteWhenAvailable() {
        let localSegments = TranscriptSpeakerLabels.assignPlaceholders(
            to: [
                TranscriptSegment(id: 1, text: "Local voice.", startTime: 0, speaker: nil, confidence: 0.9)
            ],
            fallbackSpeakerID: CapturedAudioSource.microphone.fallbackSpeakerID
        )
        let remoteSegments = TranscriptSpeakerLabels.assignPlaceholders(
            to: [
                TranscriptSegment(id: 2, text: "Remote voice.", startTime: 7, speaker: nil, confidence: 0.9)
            ],
            fallbackSpeakerID: CapturedAudioSource.systemAudio.fallbackSpeakerID
        )

        XCTAssertEqual(localSegments[0].speaker, "speaker-local")
        XCTAssertEqual(remoteSegments[0].speaker, "speaker-remote")
        XCTAssertEqual(TranscriptSpeakerLabels.displayName(for: "speaker-local", labels: [:]), "You")
        XCTAssertEqual(TranscriptSpeakerLabels.displayName(for: "speaker-remote", labels: [:]), "Remote audio")
    }

    func testTranscriptionWindowPlannerSplitsLongBuffersIntoBoundedWindows() {
        let windows = TranscriptionWindowPlanner.windows(
            frameLength: 75 * 16_000,
            sampleRate: 16_000,
            maxDuration: 30
        )

        XCTAssertEqual(windows.map(\.startFrame), [0, 480_000, 960_000])
        XCTAssertEqual(windows.map(\.frameCount), [480_000, 480_000, 240_000])
        XCTAssertEqual(windows.map(\.startTime), [0, 30, 60])
        XCTAssertTrue(windows.allSatisfy { $0.duration <= 30 })
    }

    func testTranscriptionWarningSegmentPreservesSharedTranscriptShape() {
        let warning = TranscriptionWindowPlanner.warningSegment(
            id: 4,
            startTime: 30,
            endTime: 45,
            reason: "Whisper chunk failed"
        )

        XCTAssertEqual(warning.id, 4)
        XCTAssertEqual(warning.text, "[Transcript may be incomplete: Whisper chunk failed]")
        XCTAssertEqual(warning.startTime, 30)
        XCTAssertEqual(warning.endTime, 45)
        XCTAssertEqual(warning.speaker, "System")
        XCTAssertEqual(warning.confidence, 0)
    }

    func testAITasksExtractJSONFromMarkdownFence() throws {
        let raw = """
        Sure:
        ```json
        {"decisions":["Go"],"actionItems":[{"task":"Email","owner":"Ana","deadline":null}],"topics":["Launch"],"openQuestions":[]}
        ```
        """

        let summary = try AITasks.parseMeetingSummary(raw)

        XCTAssertEqual(summary.decisions, ["Go"])
        XCTAssertEqual(summary.actionItems.first?.task, "Email")
        XCTAssertTrue(summary.wasSummarized)
    }

    func testParsedActionItemsUseDeterministicContentIDs() throws {
        let raw = """
        {"decisions":[],"actionItems":[{"task":"Email the launch brief","owner":"Ana","deadline":"2026-05-08"},{"task":"Email  the launch brief","owner":" ana ","deadline":"2026-05-08"}],"topics":[],"openQuestions":[]}
        """

        let summary = try AITasks.parseMeetingSummary(raw)

        XCTAssertEqual(summary.actionItems.count, 1)
        XCTAssertEqual(
            summary.actionItems.first?.id,
            ActionItem.stableID(task: "Email the launch brief", owner: "Ana", deadline: "2026-05-08")
        )
    }

    func testLegacySummaryDecodesWithGeneratedSectionMetadata() throws {
        let data = """
        {"decisions":["Ship"],"actionItems":[],"topics":["Launch"],"openQuestions":[],"wasSummarized":true}
        """.data(using: .utf8)!

        let summary = try JSONDecoder().decode(MeetingSummary.self, from: data)

        XCTAssertEqual(summary.metadata(for: .decisions).state, .generated)
        XCTAssertEqual(summary.metadata(for: .actionItems).state, .generated)
        XCTAssertEqual(summary.metadata(for: .topics).state, .generated)
        XCTAssertEqual(summary.metadata(for: .openQuestions).state, .generated)
    }

    func testReplacingOneSummarySectionPreservesOtherUserEdits() {
        let editedAt = Date(timeIntervalSince1970: 100)
        let regeneratedAt = Date(timeIntervalSince1970: 200)
        var summary = MeetingSummary(
            decisions: ["User edited decision"],
            actionItems: [ActionItem(task: "Keep customer follow-up", owner: "Bo")],
            topics: ["Old topic"],
            openQuestions: ["Existing question"],
            wasSummarized: true,
            sectionMetadata: [
                MeetingSummarySection.decisions.rawValue: SummarySectionEditMetadata(state: .userEdited, modifiedAt: editedAt),
                MeetingSummarySection.actionItems.rawValue: SummarySectionEditMetadata(state: .userEdited, modifiedAt: editedAt),
            ]
        )

        summary.replace(.topics, with: .topics(["Regenerated topic"]), state: .generated, modifiedAt: regeneratedAt)

        XCTAssertEqual(summary.decisions, ["User edited decision"])
        XCTAssertEqual(summary.actionItems.map(\.task), ["Keep customer follow-up"])
        XCTAssertEqual(summary.topics, ["Regenerated topic"])
        XCTAssertEqual(summary.openQuestions, ["Existing question"])
        XCTAssertEqual(summary.metadata(for: .decisions).state, .userEdited)
        XCTAssertEqual(summary.metadata(for: .actionItems).state, .userEdited)
        XCTAssertEqual(summary.metadata(for: .topics).state, .generated)
        XCTAssertEqual(summary.metadata(for: .topics).modifiedAt, regeneratedAt)
    }

    func testLegacyTodosAreConservativelySplitIntoTodosAndTasks() {
        let calendar = Calendar(identifier: .gregorian)
        let dueDate = calendar.date(from: DateComponents(year: 2026, month: 5, day: 8))
        let lightweightTodo = TodoItem(
            title: "Ping Itay on Crusoe's Dynamo work",
            dueDate: dueDate,
            createdDate: Date(timeIntervalSince1970: 100),
            modifiedDate: Date(timeIntervalSince1970: 100)
        )
        let durableWork = TodoItem(
            title: "Completed Nscale 1:1 follow-up",
            description: "Captured the gateway routing decision, NATS implications, and session-affinity context for reuse in the next T5T.",
            completed: true,
            createdDate: Date(timeIntervalSince1970: 200),
            modifiedDate: Date(timeIntervalSince1970: 300)
        )
        let actionLinked = TodoItem(
            title: "Send customer benchmark notes",
            description: "From meeting: Nscale 1:1\nOwner: JP",
            sourceMeetingID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            sourceActionItemID: "action-1",
            owner: "JP",
            createdDate: Date(timeIntervalSince1970: 400),
            modifiedDate: Date(timeIntervalSince1970: 400)
        )

        let split = TaskTodoClassifier.splitLegacyTodos([lightweightTodo, durableWork, actionLinked])

        XCTAssertEqual(split.todos.map(\.id), [lightweightTodo.id])
        XCTAssertEqual(split.tasks.map(\.id), [durableWork.id, actionLinked.id])
        XCTAssertEqual(split.tasks[0].status, .completed)
        XCTAssertEqual(split.tasks[0].completedDate, durableWork.modifiedDate)
        XCTAssertTrue(split.tasks[0].description.contains("gateway routing decision"))
        XCTAssertEqual(split.tasks[1].sourceMeetingID, actionLinked.sourceMeetingID)
        XCTAssertEqual(split.tasks[1].sourceActionItemID, actionLinked.sourceActionItemID)
        XCTAssertEqual(split.tasks[1].owner, "JP")
    }

    func testActionLinkedTaskMergeUsesSourceFieldsWithoutDuplicating() {
        let meetingID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let action = ActionItem(task: "Send pricing notes", owner: "Ana", deadline: "2026-05-08")
        let meeting = Meeting(
            id: meetingID,
            title: "Customer Sync",
            date: Date(timeIntervalSince1970: 0),
            duration: 60,
            transcript: [],
            summary: MeetingSummary(actionItems: [action], wasSummarized: true)
        )
        let now = Date(timeIntervalSince1970: 300)

        let firstMerge = TaskItem.mergingActionLinkedTasks(existing: [], meeting: meeting, now: now)
        let secondMerge = TaskItem.mergingActionLinkedTasks(existing: firstMerge, meeting: meeting, now: now.addingTimeInterval(60))

        XCTAssertEqual(firstMerge.count, 1)
        XCTAssertEqual(secondMerge.count, 1)
        XCTAssertEqual(firstMerge[0].title, "Send pricing notes")
        XCTAssertTrue(firstMerge[0].description.contains("From meeting: Customer Sync"))
        XCTAssertEqual(firstMerge[0].sourceMeetingID, meetingID)
        XCTAssertEqual(firstMerge[0].sourceActionItemID, action.id)
        XCTAssertEqual(firstMerge[0].owner, "Ana")
    }

    func testActionLinkedTaskMergeRefreshesExistingSourceFieldsWithoutResettingCompletion() throws {
        let meetingID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let originalAction = ActionItem(task: "Send pricing notes", owner: "Ana", deadline: "2026-05-08")
        let refreshedAction = ActionItem(
            task: "Send updated pricing notes",
            owner: "Bo",
            deadline: "2026-05-15",
            isCompleted: false
        )
        let existingTaskID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let existingTask = TaskItem(
            id: existingTaskID,
            title: "Send pricing notes",
            description: "From meeting: Customer Sync\nOwner: Ana\nDeadline: 2026-05-08",
            status: .completed,
            workDate: Date(timeIntervalSince1970: 0),
            completedDate: Date(timeIntervalSince1970: 110),
            sourceMeetingID: meetingID,
            sourceActionItemID: originalAction.id,
            owner: "Ana",
            createdDate: Date(timeIntervalSince1970: 100),
            modifiedDate: Date(timeIntervalSince1970: 100)
        )
        let meeting = Meeting(
            id: meetingID,
            title: "Customer Sync",
            date: Date(timeIntervalSince1970: 0),
            duration: 60,
            transcript: [],
            summary: MeetingSummary(actionItems: [refreshedAction], wasSummarized: true)
        )

        let merged = TaskItem.mergingActionLinkedTasks(
            existing: [existingTask],
            meeting: meeting,
            now: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].id, existingTaskID)
        XCTAssertEqual(merged[0].title, "Send updated pricing notes")
        XCTAssertTrue(merged[0].description.contains("Owner: Bo"))
        XCTAssertTrue(merged[0].description.contains("Deadline: 2026-05-15"))
        XCTAssertEqual(merged[0].owner, "Bo")
        XCTAssertEqual(merged[0].sourceActionItemID, refreshedAction.id)
        XCTAssertEqual(merged[0].status, .completed)
        XCTAssertEqual(merged[0].completedDate, Date(timeIntervalSince1970: 110))
        XCTAssertEqual(merged[0].createdDate, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(merged[0].modifiedDate, Date(timeIntervalSince1970: 200))

        let workDate = try XCTUnwrap(merged[0].workDate)
        let components = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: workDate)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 5)
        XCTAssertEqual(components.day, 15)
    }

    func testRemovedRegeneratedActionItemsAreUnlinkedWithoutDeletingTask() {
        let meetingID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let staleAction = ActionItem(task: "Publish stale notes", owner: "Ana", deadline: "2026-05-08")
        let existingTaskID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        let existingTask = TaskItem(
            id: existingTaskID,
            title: "Publish stale notes",
            description: "From meeting: Customer Sync",
            sourceMeetingID: meetingID,
            sourceActionItemID: staleAction.id,
            owner: "Ana",
            createdDate: Date(timeIntervalSince1970: 100),
            modifiedDate: Date(timeIntervalSince1970: 100)
        )
        let meeting = Meeting(
            id: meetingID,
            title: "Customer Sync",
            date: Date(timeIntervalSince1970: 0),
            duration: 60,
            transcript: [],
            summary: MeetingSummary(actionItems: [], wasSummarized: true)
        )

        let merged = TaskItem.mergingActionLinkedTasks(
            existing: [existingTask],
            meeting: meeting,
            now: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].id, existingTaskID)
        XCTAssertNil(merged[0].sourceMeetingID)
        XCTAssertNil(merged[0].sourceActionItemID)
        XCTAssertEqual(merged[0].modifiedDate, Date(timeIntervalSince1970: 200))
    }

    func testCommandCenterSnapshotPrioritizesFocusQueueAndNextMove() throws {
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: Date())
        let overdueDate = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let tomorrowDate = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: today))
        let oldCompletion = try XCTUnwrap(calendar.date(byAdding: .day, value: -3, to: today))
        let recentCompletion = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))

        let overdue = TodoItem(title: "Escalate roadmap blocker", dueDate: overdueDate)
        let todayTodo = TodoItem(title: "Prep customer sync", dueDate: today)
        let upcoming = TodoItem(title: "Draft T5T", dueDate: tomorrowDate)
        let noDueDate = TodoItem(title: "Clean backlog")
        let olderDone = TodoItem(title: "Old closed loop", completed: true, modifiedDate: oldCompletion)
        let recentDone = TodoItem(title: "Recent closed loop", completed: true, modifiedDate: recentCompletion)

        let snapshot = CommandCenterSnapshot(todos: [
            upcoming,
            recentDone,
            noDueDate,
            todayTodo,
            olderDone,
            overdue,
        ])

        XCTAssertEqual(snapshot.focusCount, 2)
        XCTAssertEqual(snapshot.pendingCount, 4)
        XCTAssertEqual(snapshot.completed.count, 2)
        XCTAssertEqual(snapshot.upcoming.map(\.id), [upcoming.id])
        XCTAssertEqual(snapshot.nextTodo?.id, overdue.id)
        XCTAssertEqual(snapshot.completed.map(\.id), [recentDone.id, olderDone.id])
    }

    func testCommandCenterLayoutUsesLinearReadableTypographyScale() {
        let compact = CommandCenterLayout.metrics(forWindowWidth: 980)
        let wide = CommandCenterLayout.metrics(forWindowWidth: 1700)

        XCTAssertLessThan(compact.scale, wide.scale)
        XCTAssertLessThan(compact.sidebarWidth, wide.sidebarWidth)
        XCTAssertLessThan(compact.commandSearchMaxWidth, wide.commandSearchMaxWidth)
        XCTAssertLessThan(compact.contentMaxWidth, wide.contentMaxWidth)
        XCTAssertLessThan(compact.onboardingMinimumCardWidth, wide.onboardingMinimumCardWidth)

        XCTAssertGreaterThanOrEqual(wide.sidebarWidth, 260)
        XCTAssertLessThanOrEqual(wide.sidebarWidth, 280)
        XCTAssertGreaterThanOrEqual(wide.maximumSidebarWidth, 320)
        XCTAssertGreaterThanOrEqual(wide.contentMaxWidth, 1300)
        XCTAssertLessThanOrEqual(wide.scale, 1)
        XCTAssertGreaterThanOrEqual(wide.titleFontSize, 32)
        XCTAssertGreaterThanOrEqual(wide.metricValueFontSize, 24)
        XCTAssertGreaterThanOrEqual(wide.sectionTitleFontSize, 16)
        XCTAssertEqual(wide.bodyFontSize, 14)
        XCTAssertEqual(wide.smallFontSize, 12)
        XCTAssertEqual(wide.tinyFontSize, 11)

        XCTAssertGreaterThanOrEqual(compact.bodyFontSize, 13)
        XCTAssertGreaterThanOrEqual(compact.smallFontSize, 12)
        XCTAssertGreaterThanOrEqual(compact.tinyFontSize, 11)

        XCTAssertLessThanOrEqual(wide.controlHeight, 39)
        XCTAssertLessThanOrEqual(wide.actionButtonHeight, 42)
    }

    func testAppearanceModeMapsToPreferredColorScheme() {
        XCTAssertEqual(NoteAIAppearanceMode.allCases.map(\.rawValue), ["system", "dark", "light"])
        XCTAssertNil(NoteAIAppearanceMode.system.preferredColorScheme)
        XCTAssertEqual(NoteAIAppearanceMode.dark.preferredColorScheme, .dark)
        XCTAssertEqual(NoteAIAppearanceMode.light.preferredColorScheme, .light)
    }

    func testCommandCenterLayoutPresetsChangeDensityAndSpacing() {
        let compact = CommandCenterLayout.metrics(forWindowWidth: 1400, preset: .compact)
        let balanced = CommandCenterLayout.metrics(forWindowWidth: 1400, preset: .balanced)
        let comfortable = CommandCenterLayout.metrics(forWindowWidth: 1400, preset: .comfortable)

        XCTAssertLessThan(compact.dashboardSpacing, balanced.dashboardSpacing)
        XCTAssertLessThan(compact.panelPadding, balanced.panelPadding)
        XCTAssertLessThan(compact.onboardingMinimumCardWidth, balanced.onboardingMinimumCardWidth)

        XCTAssertGreaterThan(comfortable.dashboardSpacing, balanced.dashboardSpacing)
        XCTAssertGreaterThan(comfortable.panelPadding, balanced.panelPadding)
        XCTAssertGreaterThan(comfortable.onboardingMinimumCardWidth, balanced.onboardingMinimumCardWidth)

        XCTAssertEqual(CommandCenterLayoutPreset.allCases.map(\.rawValue), ["compact", "balanced", "comfortable"])
    }

    func testSettingsExposeAppearanceAndLayoutControls() throws {
        let source = try settingsSource()

        XCTAssertTrue(source.contains("AppearanceSettingsView"))
        XCTAssertTrue(source.contains("@AppStorage(\"noteai.appearanceMode\")"))
        XCTAssertTrue(source.contains("@AppStorage(\"noteai.commandCenterLayoutPreset\")"))
        XCTAssertTrue(source.contains("Picker(\"Appearance\""))
        XCTAssertTrue(source.contains("Picker(\"Dashboard layout\""))
    }

    func testMainWindowAppliesSavedAppearanceAndLayoutPreset() throws {
        let appSource = try appDelegateSource()
        let meetingSource = try meetingLibrarySource()

        XCTAssertTrue(appSource.contains(".preferredColorScheme(NoteAIAppearanceMode"))
        XCTAssertTrue(meetingSource.contains("CommandCenterLayoutPreset(rawValue: commandCenterLayoutPresetRaw)"))
        XCTAssertTrue(meetingSource.contains("CommandCenterLayout.metrics(forWindowWidth: proxy.size.width, preset: layoutPreset)"))
    }

    func testCommandCenterSidebarBrandReservesTitlebarControls() throws {
        let compact = CommandCenterLayout.metrics(forWindowWidth: 980)
        let wide = CommandCenterLayout.metrics(forWindowWidth: 1700)
        let source = try meetingLibrarySource()

        XCTAssertGreaterThanOrEqual(compact.sidebarBrandLeadingInset, 12)
        XCTAssertLessThanOrEqual(compact.sidebarBrandLeadingInset, 18)
        XCTAssertEqual(compact.sidebarBrandLeadingInset, wide.sidebarBrandLeadingInset)
        XCTAssertTrue(source.contains(".padding(.leading, layout.sidebarBrandLeadingInset)"))
        XCTAssertTrue(source.contains(".padding(.top, layout.sidebarBrandHeaderTopPadding)"))
        XCTAssertTrue(source.contains(".padding(.bottom, layout.sidebarBrandHeaderBottomPadding)"))
        XCTAssertTrue(source.contains(".frame(height: layout.sidebarBrandHeaderHeight"))
    }

    func testSidebarRecordingControlsDoNotRenderStaticSourceCards() throws {
        let source = try meetingLibrarySource()

        XCTAssertFalse(source.contains("recordingSourceCard("))
        XCTAssertFalse(source.contains("Native capture"))
        XCTAssertFalse(source.contains("subtitle: \"Ready\""))
        XCTAssertFalse(source.contains("recordingReadinessRow(readiness"))
        XCTAssertFalse(source.contains("private func recordingReadinessRow"))
    }

    func testSidebarRecordingControlsUsesReadinessOnlyForPrimaryActionLabel() throws {
        let source = try meetingLibrarySource()

        XCTAssertTrue(source.contains("recordingReadiness.primaryActionTitle"))
        XCTAssertTrue(source.contains("meetingManager.startRecording()"))
    }

    func testCommandCenterDoesNotRenderRedundantTopLevelCreationButtons() throws {
        let meetingSource = try meetingLibrarySource()
        let homeSource = try homeDashboardSource()

        XCTAssertFalse(meetingSource.contains("Label(\"New note\""))
        XCTAssertFalse(homeSource.contains("Label(\"New Todo\""))
        XCTAssertTrue(meetingSource.contains("Label(\"AI copilot\""))
        XCTAssertTrue(meetingSource.contains("notesSidebarSection(selectionTarget: .notesList, layout: layout)"))
        XCTAssertTrue(meetingSource.contains("sidebarSection(.todos"))
    }

    func testDashboardPanelsUseSharedDotFirstHeaderTonesAndKeepSetupItemIcons() throws {
        let source = try homeDashboardSource()

        XCTAssertTrue(source.contains("enum DashboardPanelTone"))
        XCTAssertTrue(source.contains("private struct DashboardPanelHeader<Accessory: View>: View"))
        XCTAssertEqual(source.components(separatedBy: "DashboardPanelHeader(").count - 1, 4)
        XCTAssertTrue(source.contains("tone: .neutralAccent"))
        XCTAssertTrue(source.contains("tone: checklist.requiredReady ? .done : .warning"))
        XCTAssertTrue(source.contains("TodoColumn(title: \"Focus Queue\", subtitle: \"Overdue and due today\", tone: .danger)"))
        XCTAssertTrue(source.contains("TodoColumn(title: \"Upcoming\", subtitle: \"Next work to prepare\", tone: .accent)"))
        XCTAssertTrue(source.contains("TodoColumn(title: \"Recently Completed\", subtitle: \"Latest closed loops\", tone: .done)"))
        XCTAssertTrue(source.contains("dashboardPanelDragHandle(for: id)"))
        XCTAssertTrue(source.contains("Image(systemName: onboardingIcon(for: item.status))"))
    }

    func testSidebarListLimiterShowsInitialItemsAndCountsHiddenItems() {
        let items = Array(1...8)

        let collapsed = SidebarListLimiter.slice(items, expanded: false, searchActive: false, limit: 5)
        XCTAssertEqual(collapsed.items, [1, 2, 3, 4, 5])
        XCTAssertEqual(collapsed.hiddenCount, 3)
        XCTAssertTrue(collapsed.canToggle)

        let expanded = SidebarListLimiter.slice(items, expanded: true, searchActive: false, limit: 5)
        XCTAssertEqual(expanded.items, items)
        XCTAssertEqual(expanded.hiddenCount, 0)
        XCTAssertTrue(expanded.canToggle)

        let searching = SidebarListLimiter.slice(items, expanded: false, searchActive: true, limit: 5)
        XCTAssertEqual(searching.items, items)
        XCTAssertEqual(searching.hiddenCount, 0)
        XCTAssertFalse(searching.canToggle)
    }

    func testSidebarShowMoreAffordanceIsPersistedAndScoped() throws {
        let source = try meetingLibrarySource()

        XCTAssertTrue(source.contains("@AppStorage(\"noteai.sidebarExpandedLists.v1\")"))
        XCTAssertTrue(source.contains("Show more"))
        XCTAssertTrue(source.contains("Show less"))
        XCTAssertTrue(source.contains("sidebarLimitedContent"))
        XCTAssertTrue(source.contains("sidebarListToggleRow"))
        XCTAssertTrue(source.contains("sidebarExpansionID(forNoteSpace title:"))
    }

    func testSidebarSectionHeadersSelectCollectionListViews() throws {
        let source = try meetingLibrarySource()

        XCTAssertTrue(source.contains("case t5tList"))
        XCTAssertTrue(source.contains("case notesList"))
        XCTAssertTrue(source.contains("case tasksList"))
        XCTAssertTrue(source.contains("case todosList"))
        XCTAssertTrue(source.contains("case meetingsList"))
        XCTAssertTrue(source.contains("selectionTarget: .t5tList"))
        XCTAssertTrue(source.contains("notesSidebarSection(selectionTarget: .notesList"))
        XCTAssertTrue(source.contains("selectionTarget: .tasksList"))
        XCTAssertTrue(source.contains("selectionTarget: .todosList"))
        XCTAssertTrue(source.contains("selectionTarget: .meetingsList"))
        XCTAssertTrue(source.contains("private func sidebarSectionHeaderButton"))
        XCTAssertTrue(source.contains("selection = selectionTarget"))
    }

    func testCollectionListDestinationsRenderInMainDetailArea() throws {
        let source = try meetingLibrarySource()

        XCTAssertTrue(source.contains("case .t5tList = selection"))
        XCTAssertTrue(source.contains("t5tReportsListPage"))
        XCTAssertTrue(source.contains("case .notesList = selection"))
        XCTAssertTrue(source.contains("notesListPage"))
        XCTAssertTrue(source.contains("case .tasksList = selection"))
        XCTAssertTrue(source.contains("tasksListPage"))
        XCTAssertTrue(source.contains("case .todosList = selection"))
        XCTAssertTrue(source.contains("todosListPage"))
        XCTAssertTrue(source.contains("case .meetingsList = selection"))
        XCTAssertTrue(source.contains("meetingsListPage"))
        XCTAssertTrue(source.contains("private func collectionListPage"))
        XCTAssertTrue(source.contains("private func collectionListRow"))
    }

    func testMacOSTasksTrackerHasSeparateSidebarSectionAndCreateAction() throws {
        let source = try meetingLibrarySource()

        XCTAssertTrue(source.contains("case task(UUID)"))
        XCTAssertTrue(source.contains("sidebarSection(.tasks, title: \"Tasks\", icon: \"checklist\", selectionTarget: .tasksList, action: createNewTask"))
        XCTAssertTrue(source.contains("visibleTasks"))
        XCTAssertTrue(source.contains("taskSidebarRow(task: task"))
        XCTAssertTrue(source.contains("emptyHint(\"No tasks yet\""))
        XCTAssertTrue(source.contains("private func createNewTask()"))
        XCTAssertTrue(source.contains("let task = meetingManager.createTask()"))
        XCTAssertTrue(source.contains("selection = .task(task.id)"))
    }

    func testMacOSTasksTrackerRendersListPageAndTaskDetailEditor() throws {
        let source = try meetingLibrarySource()
        let detailSource = try taskDetailSource()

        XCTAssertTrue(source.contains("private var tasksListPage: some View"))
        XCTAssertTrue(source.contains("eyebrow: \"Tasks\""))
        XCTAssertTrue(source.contains("title: \"Tasks\""))
        XCTAssertTrue(source.contains("durable work records for T5T"))
        XCTAssertTrue(source.contains("collectionListRow("))
        XCTAssertTrue(source.contains("selection = .task(task.id)"))
        XCTAssertTrue(source.contains("TaskDetailView("))
        XCTAssertTrue(detailSource.contains("struct TaskDetailView: View"))
        XCTAssertTrue(detailSource.contains("@Binding var task: TaskItem"))
        XCTAssertTrue(detailSource.contains("meetingManager.updateTask(updated)"))
        XCTAssertTrue(detailSource.contains("meetingManager.toggleTaskCompletion(task)"))
        XCTAssertTrue(detailSource.contains("meetingManager.deleteTask(task)"))
        XCTAssertTrue(detailSource.contains("WORK DATE"))
    }

    func testTaskSidebarStatusCircleHasDedicatedCompletionAction() throws {
        let source = try meetingLibrarySource()
        let rowStart = try XCTUnwrap(source.range(of: "private func taskSidebarRow(task: TaskItem, layout: CommandCenterLayout) -> some View"))
        let nextFunction = try XCTUnwrap(source.range(of: "private func dueLabelColor", range: rowStart.upperBound..<source.endIndex))
        let rowSource = String(source[rowStart.lowerBound..<nextFunction.lowerBound])

        XCTAssertTrue(rowSource.contains("selection = .task(task.id)"))
        XCTAssertTrue(rowSource.contains("meetingManager.toggleTaskCompletion(task)"))
        XCTAssertTrue(rowSource.contains(".buttonStyle(.plain)"))
        XCTAssertTrue(rowSource.contains(".accessibilityLabel(task.isCompleted ? \"Mark task open\" : \"Mark task complete\")"))
    }

    func testNoteSpaceHeadersExposeRenameAndDeleteContextMenuForCustomSpaces() throws {
        let source = try meetingLibrarySource()

        XCTAssertTrue(source.contains("private func noteSpaceHeader"))
        XCTAssertTrue(source.contains("if !group.isUnassigned"))
        XCTAssertTrue(source.contains(".contextMenu"))
        XCTAssertTrue(source.contains("Label(\"Rename Space\""))
        XCTAssertTrue(source.contains("renameNoteSpace(group.title)"))
        XCTAssertTrue(source.contains("Label(\"Delete Space\""))
        XCTAssertTrue(source.contains("deleteNoteSpace(group.title)"))
    }

    func testTodoDetailCompletionActionDoesNotDoubleToggleBoundTodo() throws {
        let source = try todoDetailSource()

        XCTAssertTrue(source.contains("private func toggleCompletion()"))
        XCTAssertTrue(source.contains("meetingManager.toggleTodoCompletion(todo)"))
        XCTAssertFalse(source.contains("todo.completed.toggle()"))
    }

    func testT5TComposerUsesTasksAsPrimarySourceInput() throws {
        let source = try t5tComposerSource()
        let selectorSource = try taskSelectorSource()
        let engineSource = try summarizationEngineSource()

        XCTAssertTrue(source.contains("@State private var selectedTaskIDs"))
        XCTAssertTrue(source.contains("meetingManager.tasksInRange"))
        XCTAssertTrue(source.contains("TaskSelectorView("))
        XCTAssertTrue(source.contains("report.taskIDs = Array(selectedTaskIDs)"))
        XCTAssertTrue(source.contains("Text(\"Source Tasks\")"))
        XCTAssertTrue(source.contains(".disabled(selectedTaskIDs.isEmpty)"))
        XCTAssertFalse(source.contains("MeetingSelectorView("))
        XCTAssertFalse(source.contains("NoteSelectorView("))
        XCTAssertFalse(source.contains("Text(\"Source Meetings\")"))
        XCTAssertFalse(source.contains("Text(\"Source Notes\")"))
        XCTAssertFalse(source.contains("meetingIDs: Array(selectedMeetingIDs)"))
        XCTAssertFalse(source.contains("noteIDs: Array(selectedNoteIDs)"))
        XCTAssertFalse(source.contains("Text(\"Source Todos\")"))
        XCTAssertTrue(selectorSource.contains("struct TaskSelectorView"))
        XCTAssertTrue(selectorSource.contains("let tasks: [TaskItem]"))
        XCTAssertTrue(selectorSource.contains(".frame(minHeight: 260, maxHeight: 420)"))
        XCTAssertTrue(selectorSource.contains("systemImage: \"calendar\""))
        XCTAssertTrue(selectorSource.contains("systemImage: \"text.alignleft\""))
        XCTAssertTrue(engineSource.contains("func generateT5T(meetings: [Meeting], notes: [Note] = [], tasks: [TaskItem] = []"))
        XCTAssertTrue(engineSource.contains("T5TPrompt.buildPrompt("))
        XCTAssertTrue(try t5tPromptSource().contains("TASK SOURCE MATERIAL:"))
        XCTAssertFalse(engineSource.contains("TODOS:"))
    }

    func testT5TPromptCentralizesJPPreferredNVIDIAStyle() throws {
        let promptSource = try t5tPromptSource()
        let engineSource = try summarizationEngineSource()

        XCTAssertTrue(promptSource.contains("enum T5TPrompt"))
        XCTAssertTrue(promptSource.contains("Top 5 Things - Inference Ops | NALA | SA"))
        XCTAssertTrue(promptSource.contains("Industry Business Development / Account Updates"))
        XCTAssertTrue(promptSource.contains("Future Plans"))
        XCTAssertTrue(promptSource.contains("Make it a priority list, not a to-do list."))
        XCTAssertTrue(promptSource.contains("Do not use \"Result:\" labels"))
        XCTAssertTrue(promptSource.contains("Work-in-progress and open items belong in futurePlans"))
        XCTAssertTrue(promptSource.contains("Do not claim JP caused a customer or partner action when he is supporting it."))
        XCTAssertTrue(promptSource.contains("Omit sections that do not apply"))
        XCTAssertTrue(promptSource.contains("Avoid naming Slack channels"))
        XCTAssertTrue(promptSource.contains("Avoid links in final T5Ts unless explicitly requested."))
        XCTAssertTrue(promptSource.contains("Return ONLY valid JSON"))

        XCTAssertTrue(engineSource.contains("T5TPrompt.buildPrompt("))
        XCTAssertFalse(engineSource.contains("T5T FORMAT RULES (from Jensen Huang):"))
    }

    func testT5TPromptBuildsTaskOnlyContextAndRoutesOpenWorkToFuturePlans() throws {
        let completed = TaskItem(
            title: "Delivered Production Cadence JEDAI Platform",
            description: "Moved Cadence JEDAI from PoC to production NVPark/NVCF service for 300+ engineers.",
            status: .completed,
            workDate: Date(timeIntervalSince1970: 1_800),
            completedDate: Date(timeIntervalSince1970: 2_000),
            createdDate: Date(timeIntervalSince1970: 1_000),
            modifiedDate: Date(timeIntervalSince1970: 2_000)
        )
        let open = TaskItem(
            title: "Execute Nscale Dynamo PoC",
            description: "Advance sample integrations, two-cluster testing, network validation, and load metrics.",
            status: .open,
            workDate: Date(timeIntervalSince1970: 3_000),
            createdDate: Date(timeIntervalSince1970: 3_000),
            modifiedDate: Date(timeIntervalSince1970: 3_000)
        )

        let prompt = T5TPrompt.buildPrompt(
            tasks: [completed, open],
            config: .empty,
            periodStart: Date(timeIntervalSince1970: 0),
            periodEnd: Date(timeIntervalSince1970: 86_400)
        )

        XCTAssertTrue(prompt.contains("SUBJECT LINE DEFAULT:\nTop 5 Things - Inference Ops | NALA | SA"))
        XCTAssertTrue(prompt.contains("COMPLETED TASKS - use as candidates for accountUpdates"))
        XCTAssertTrue(prompt.contains("[COMPLETED] Delivered Production Cadence JEDAI Platform"))
        XCTAssertTrue(prompt.contains("OPEN / IN-PROGRESS TASKS - use as candidates for futurePlans"))
        XCTAssertTrue(prompt.contains("[OPEN] Execute Nscale Dynamo PoC"))
        XCTAssertFalse(prompt.contains("MEETING SUMMARIES:"))
        XCTAssertFalse(prompt.contains("NOTES:"))
        XCTAssertFalse(prompt.contains("TODOS:"))
    }

    func testT5TDefaultSubjectUsesExactPreferredHyphenatedFormat() throws {
        XCTAssertEqual(T5TPrompt.defaultSubjectLine, "Top 5 Things - Inference Ops | NALA | SA")
        XCTAssertEqual(LibraryOperations.t5tDefaultTitle(config: .empty), "Top 5 Things - Inference Ops | NALA | SA")

        let source = try t5tConfigSheetSource()
        XCTAssertTrue(source.contains("Top 5 Things - "))
        XCTAssertFalse(source.contains("Top 5 Things – "))
    }

    func testAssistantT5TCreationUsesTasksAndCanonicalPromptPath() throws {
        let source = try chatManagerSource()
        let actionStart = try XCTUnwrap(source.range(of: "case \"create_t5t\":"))
        let nextAction = try XCTUnwrap(source.range(of: "case \"list_t5t\":", range: actionStart.upperBound..<source.endIndex))
        let actionSource = String(source[actionStart.lowerBound..<nextAction.lowerBound])

        XCTAssertTrue(actionSource.contains("tasks: tasks"))
        XCTAssertTrue(actionSource.contains("taskIDs: tasks.map(\\.id)"))
        XCTAssertTrue(actionSource.contains("meetingIDs: []"))
        XCTAssertTrue(actionSource.contains("noteIDs: []"))
        XCTAssertFalse(actionSource.contains("let meetings = manager.meetingsInRange"))
        XCTAssertFalse(actionSource.contains("let notes = manager.notes"))
        XCTAssertFalse(actionSource.contains("notes: inputText.isEmpty ? notes"))
    }

    func testNewT5TReportsAreSeededFromTasksOnly() throws {
        let source = try meetingLibrarySource()
        let actionStart = try XCTUnwrap(source.range(of: "private func createNewT5T()"))
        let nextAction = try XCTUnwrap(source.range(of: "private func createNewTodo()", range: actionStart.upperBound..<source.endIndex))
        let actionSource = String(source[actionStart.lowerBound..<nextAction.lowerBound])

        XCTAssertTrue(actionSource.contains("let tasksInRange = meetingManager.tasksInRange(start: start, end: end)"))
        XCTAssertTrue(actionSource.contains("meetingIDs: []"))
        XCTAssertTrue(actionSource.contains("noteIDs: []"))
        XCTAssertTrue(actionSource.contains("taskIDs: tasksInRange.map(\\.id)"))
        XCTAssertFalse(actionSource.contains("meetingsInRange"))
        XCTAssertFalse(actionSource.contains("meetingIDs: meetingsInRange.map(\\.id)"))
    }

    func testT5TGenerationUpdatesCurrentReportInsteadOfCreatingDuplicate() throws {
        let source = try t5tComposerSource()
        let actionStart = try XCTUnwrap(source.range(of: "private func generateT5T()"))
        let nextAction = try XCTUnwrap(source.range(of: "private func copyToClipboard()", range: actionStart.upperBound..<source.endIndex))
        let actionSource = String(source[actionStart.lowerBound..<nextAction.lowerBound])

        XCTAssertTrue(actionSource.contains("report.periodStart = periodStart"))
        XCTAssertTrue(actionSource.contains("report.periodEnd = periodEnd"))
        XCTAssertTrue(actionSource.contains("report.taskIDs = Array(selectedTaskIDs)"))
        XCTAssertTrue(actionSource.contains("report.todoIDs = Array(selectedTaskIDs)"))
        XCTAssertTrue(actionSource.contains("meetingManager.regenerateT5T(report: report)"))
        XCTAssertFalse(actionSource.contains("report.sections.isEmpty"))
        XCTAssertFalse(actionSource.contains("meetingManager.createT5TReport"))
    }

    func testT5TMailDraftURLPreservesFullBodyWithAmpersandsBulletsAndNewlines() throws {
        let report = T5TReport(
            id: UUID(),
            title: "Top 5 Things - Inference Ops | NALA | SA",
            createdDate: Date(timeIntervalSince1970: 0),
            periodStart: Date(timeIntervalSince1970: 0),
            periodEnd: Date(timeIntervalSince1970: 86_400),
            meetingIDs: [],
            taskIDs: [],
            sections: T5TSections(
                insights: [
                    T5TEntry(
                        headline: "Insights, Management Escalations & Help Needed",
                        explanation: "Reframed roadmap ownership & automation blockers."
                    ),
                ],
                accountUpdates: [
                    T5TEntry(
                        headline: "Industry Business Development / Account Updates",
                        explanation: "Restarted Nscale 30/60/90 with Dynamo PoC & Envoy alignment."
                    ),
                ],
                futurePlans: [
                    T5TEntry(
                        headline: "Land Nscale Dynamo PoC",
                        explanation: "Next two weeks: execute benchmark runs.\nKeep follow-up crisp."
                    ),
                ]
            ),
            status: .draft
        )

        let url = try XCTUnwrap(T5TMailDraft.mailtoURL(for: report))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let subject = components.queryItems?.first { $0.name == "subject" }?.value
        let body = components.queryItems?.first { $0.name == "body" }?.value

        XCTAssertEqual(subject, report.title)
        XCTAssertEqual(body, report.emailBody)
        XCTAssertTrue(body?.contains("Management Escalations & Help Needed") == true)
        XCTAssertTrue(body?.contains("Dynamo PoC & Envoy alignment") == true)
        XCTAssertTrue(body?.contains("• Land Nscale Dynamo PoC") == true)
        XCTAssertTrue(body?.contains("Keep follow-up crisp.") == true)

        let composerSource = try t5tComposerSource()
        XCTAssertTrue(composerSource.contains("T5TMailDraft.open(for: report)"))
        XCTAssertFalse(composerSource.contains(".urlQueryAllowed"))
    }

    func testT5TMailDraftHTMLUsesAptosHierarchyForOutlookDrafts() throws {
        let report = T5TReport(
            id: UUID(),
            title: "Top 5 Things - Inference Ops | NALA | SA",
            createdDate: Date(timeIntervalSince1970: 0),
            periodStart: Date(timeIntervalSince1970: 0),
            periodEnd: Date(timeIntervalSince1970: 86_400),
            meetingIDs: [],
            taskIDs: [],
            sections: T5TSections(
                insights: [],
                accountUpdates: [
                    T5TEntry(
                        headline: "Delivered ModelOpt Demo to CoreWeave Covering Speculative Decoding and FP4 Quantization",
                        explanation: "To enable the CoreWeave team to optimize LLM deployments on their GPU cloud infrastructure, I delivered a ModelOpt demo & technical presentation."
                    ),
                ],
                futurePlans: []
            ),
            status: .draft
        )

        let html = T5TMailDraft.htmlBody(for: report)

        XCTAssertTrue(html.contains("font-family: Aptos, Arial, sans-serif; font-size: 13pt; font-weight: 700"))
        XCTAssertTrue(html.contains(">Industry Business Development / Account Updates<"))
        XCTAssertTrue(html.contains("font-family: Aptos, Arial, sans-serif; font-size: 11pt; font-weight: 700"))
        XCTAssertTrue(html.contains(">Delivered ModelOpt Demo to CoreWeave Covering Speculative Decoding and FP4 Quantization<"))
        XCTAssertTrue(html.contains("font-family: Aptos, Arial, sans-serif; font-size: 11pt; font-weight: 400"))
        XCTAssertTrue(html.contains("&bull;&nbsp;To enable the CoreWeave team"))
        XCTAssertTrue(html.contains("demo &amp; technical presentation"))

        let composerSource = try t5tComposerSource()
        XCTAssertTrue(composerSource.contains("T5TMailDraft.open(for: report)"))
        XCTAssertFalse(composerSource.contains("NSWorkspace.shared.open(url)"))

        let mailDraftSource = try t5tMailDraftSource()
        XCTAssertTrue(mailDraftSource.contains(#""\u{00AB}class outm\u{00BB}""#))
        XCTAssertFalse(mailDraftSource.contains("make new outgoing_message with properties"))
        XCTAssertFalse(mailDraftSource.contains("make new message with properties"))
        XCTAssertFalse(mailDraftSource.contains("make new outgoing message"))
    }

    func testT5TMailDraftFallsBackToMailtoOnlyWhenOutlookIsUnavailable() throws {
        let report = T5TReport(
            id: UUID(),
            title: "Top 5 Things - Inference Ops | NALA | SA",
            createdDate: Date(timeIntervalSince1970: 0),
            periodStart: Date(timeIntervalSince1970: 0),
            periodEnd: Date(timeIntervalSince1970: 86_400),
            meetingIDs: [],
            taskIDs: [],
            sections: T5TSections(
                insights: [T5TEntry(headline: "Insight", explanation: "Plain fallback content")],
                accountUpdates: [],
                futurePlans: []
            ),
            status: .draft
        )
        var openedURL: URL?
        var executedScripts: [String] = []
        let environment = T5TMailDraft.Environment(
            isOutlookAvailable: { false },
            executeAppleScript: { source in
                executedScripts.append(source)
                return .success
            },
            openURL: { url in openedURL = url }
        )

        let result = T5TMailDraft.open(for: report, environment: environment)

        XCTAssertEqual(result, .openedMailtoFallback)
        XCTAssertEqual(openedURL?.scheme, "mailto")
        XCTAssertTrue(executedScripts.isEmpty)
    }

    func testT5TMailDraftDoesNotOpenPlainMailtoWhenOutlookAutomationFails() throws {
        let report = T5TReport(
            id: UUID(),
            title: "Top 5 Things - Inference Ops | NALA | SA",
            createdDate: Date(timeIntervalSince1970: 0),
            periodStart: Date(timeIntervalSince1970: 0),
            periodEnd: Date(timeIntervalSince1970: 86_400),
            meetingIDs: [],
            taskIDs: [],
            sections: T5TSections(
                insights: [T5TEntry(headline: "Insight", explanation: "Formatted content")],
                accountUpdates: [],
                futurePlans: []
            ),
            status: .draft
        )
        var openedURL: URL?
        var executedScript: String?
        let environment = T5TMailDraft.Environment(
            isOutlookAvailable: { true },
            executeAppleScript: { source in
                executedScript = source
                return .failure("Not authorized to send Apple events to Microsoft Outlook.")
            },
            openURL: { url in openedURL = url }
        )

        let result = T5TMailDraft.open(for: report, environment: environment)

        XCTAssertNil(openedURL)
        XCTAssertTrue(executedScript?.contains("make new \u{00AB}class outm\u{00BB} with properties") == true)
        XCTAssertTrue(executedScript?.contains("outgoing_message") == false)
        XCTAssertEqual(result, .outlookAutomationFailed("Not authorized to send Apple events to Microsoft Outlook."))
    }

    func testT5TComposerShowsOutlookAutomationFailureInsteadOfSilentFallback() throws {
        let composerSource = try t5tComposerSource()

        XCTAssertTrue(composerSource.contains("@State private var mailDraftError: String?"))
        XCTAssertTrue(composerSource.contains(".alert("))
        XCTAssertTrue(composerSource.contains("\"Could not open formatted Outlook draft\""))
        XCTAssertTrue(composerSource.contains("let result = T5TMailDraft.open(for: report)"))
        XCTAssertTrue(composerSource.contains("mailDraftError = message"))
        XCTAssertFalse(composerSource.contains("private func openInMail() {\n        T5TMailDraft.open(for: report)\n    }"))
    }

    func testChatAssistantSeparatesTasksFromTodosWithoutCreatingTaskLikeNotes() throws {
        let source = try chatManagerSource()

        XCTAssertTrue(source.contains("- create_task: {\"action\":\"create_task\", \"title\":\"...\", \"description\":\"...\", \"status\":\"open|completed\", \"work_date\":\"YYYY-MM-DD or ISO-8601\", \"source\""))
        XCTAssertTrue(source.contains("- create_tasks: {\"action\":\"create_tasks\", \"tasks\""))
        XCTAssertTrue(source.contains("- create_todo: {\"action\":\"create_todo\", \"title\":\"...\", \"due_date\":\"YYYY-MM-DD or ISO-8601\"}"))
        XCTAssertTrue(source.contains("task requests use create_task"))
        XCTAssertTrue(source.contains("todo requests use create_todo"))
        XCTAssertTrue(source.contains("When converting Outlook email conversations into work items, use create_tasks"))
        XCTAssertTrue(source.contains("use create_task or create_todo (NOT create_note)"))
        XCTAssertTrue(source.contains("case \"create_task\""))
        XCTAssertTrue(source.contains("AssistantTaskActionParser.taskDraft(from: json)"))
        XCTAssertTrue(source.contains("sourceMetadata: draft.sourceMetadata"))
        XCTAssertTrue(source.contains("case \"create_tasks\""))
        XCTAssertTrue(source.contains("case \"create_todo\""))
        XCTAssertTrue(source.contains("manager.createTodo(title: title, dueDate: dueDate)"))
        XCTAssertTrue(source.contains("ISO8601DateFormatter"))
        XCTAssertTrue(source.contains("parseTodoDueDate"))
        XCTAssertTrue(source.contains("Untitled todo"))
        XCTAssertTrue(source.contains("- list_tasks: {\"action\":\"list_tasks\""))
        XCTAssertTrue(source.contains("- list_todos: {\"action\":\"list_todos\""))
        XCTAssertTrue(source.contains("case \"list_tasks\""))
        XCTAssertTrue(source.contains("case \"list_todos\""))
        XCTAssertTrue(source.contains("handleLocalTaskOrTodoListRequest"))
    }

    func testAssistantTaskListActionFormatsCopyReadyTitleAndDescription() throws {
        let calendar = Calendar(identifier: .gregorian)
        let afterDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 13)))
        let olderDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 10)))
        let newerDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 14)))

        let included = TaskItem(
            title: "Drive NSScale routing alignment",
            description: "Summarize the NATS decision and gateway/session-affinity implications for the architecture doc.",
            workDate: newerDate,
            createdDate: olderDate,
            modifiedDate: newerDate
        )
        let excluded = TaskItem(
            title: "Old reminder",
            description: "Should not appear in the copy-ready list.",
            createdDate: olderDate,
            modifiedDate: olderDate
        )

        let filters = AssistantTaskListFormatter.Filters(after: afterDate, status: .all)
        let output = AssistantTaskListFormatter.format(tasks: [included, excluded], filters: filters)

        XCTAssertTrue(output.contains("Tasks after Mar 13, 2026"))
        XCTAssertTrue(output.contains("- Drive NSScale routing alignment"))
        XCTAssertTrue(output.contains("  Summarize the NATS decision and gateway/session-affinity implications for the architecture doc."))
        XCTAssertFalse(output.contains("Old reminder"))
        XCTAssertFalse(output.contains("Title:"))
        XCTAssertFalse(output.contains("Description:"))
    }

    func testAssistantTaskListActionGroupsCopyReadyTasksByDate() throws {
        let calendar = Calendar(identifier: .gregorian)
        let march13 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 13)))
        let march14 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 14)))

        let first = TaskItem(
            title: "Created Dynamo KBYG Guide",
            description: "Prepared the full product guide for GTC 2026 workshop follow-up.",
            workDate: march13,
            createdDate: march13,
            modifiedDate: march13
        )
        let second = TaskItem(
            title: "Reviewed NSScale routing plan",
            description: "Captured gateway and session-affinity alignment for reuse.",
            workDate: march14,
            createdDate: march14,
            modifiedDate: march14
        )

        let output = AssistantTaskListFormatter.format(
            tasks: [second, first],
            filters: AssistantTaskListFormatter.Filters(after: march13, status: .all)
        )

        XCTAssertTrue(output.contains("""
        - 03/13/2026
          - Created Dynamo KBYG Guide
            Prepared the full product guide for GTC 2026 workshop follow-up.
        - 03/14/2026
          - Reviewed NSScale routing plan
            Captured gateway and session-affinity alignment for reuse.
        """))
        XCTAssertFalse(output.contains("(completed"))
        XCTAssertFalse(output.contains("Title:"))
        XCTAssertFalse(output.contains("Description:"))
    }

    func testTaskItemPreservesOutlookSourceMetadataThroughCodable() throws {
        let calendar = Calendar(identifier: .gregorian)
        let messageDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 4, day: 8, hour: 10)))
        let source = TaskItem.SourceMetadata(
            kind: .email,
            provider: "outlook",
            threadID: "thread-123",
            messageID: "message-456",
            subject: "Follow up on NSScale routing",
            sender: "alex@example.com",
            sentDate: messageDate,
            url: "https://outlook.office.com/mail/thread-123"
        )
        let task = TaskItem(
            title: "Send routing summary",
            description: "Alex asked for the latest gateway recommendation.",
            sourceMetadata: source
        )

        let decoded = try JSONDecoder().decode(TaskItem.self, from: JSONEncoder().encode(task))

        XCTAssertEqual(decoded.sourceMetadata, source)
    }

    func testAssistantBulkTaskActionParsesOutlookCandidates() throws {
        let taskDate = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-04-09T14:30:00Z"))
        let drafts = AssistantTaskActionParser.taskDrafts(from: [
            "action": "create_tasks",
            "tasks": [
                [
                    "title": "Send routing summary",
                    "description": "Alex asked for the latest gateway recommendation.",
                    "status": "open",
                    "work_date": "2026-04-09T14:30:00Z",
                    "source": [
                        "kind": "email",
                        "provider": "outlook",
                        "thread_id": "thread-123",
                        "message_id": "message-456",
                        "subject": "Follow up on NSScale routing",
                        "sender": "alex@example.com",
                        "date": "2026-04-08T10:00:00Z",
                        "url": "https://outlook.office.com/mail/thread-123"
                    ]
                ]
            ]
        ])

        let draft = try XCTUnwrap(drafts.first)
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(draft.title, "Send routing summary")
        XCTAssertEqual(draft.description, "Alex asked for the latest gateway recommendation.")
        XCTAssertEqual(draft.status, .open)
        XCTAssertEqual(draft.workDate, taskDate)
        XCTAssertEqual(draft.sourceMetadata?.kind, .email)
        XCTAssertEqual(draft.sourceMetadata?.provider, "outlook")
        XCTAssertEqual(draft.sourceMetadata?.threadID, "thread-123")
        XCTAssertEqual(draft.sourceMetadata?.messageID, "message-456")
    }

    func testAssistantTaskListCanIncludeEmailSourceInCopyReadyOutput() throws {
        let calendar = Calendar(identifier: .gregorian)
        let workDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 4, day: 9)))
        let messageDate = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-04-08T10:00:00Z"))
        let task = TaskItem(
            title: "Send routing summary",
            description: "Alex asked for the latest gateway recommendation.",
            workDate: workDate,
            sourceMetadata: TaskItem.SourceMetadata(
                kind: .email,
                provider: "outlook",
                threadID: "thread-123",
                messageID: "message-456",
                subject: "Follow up on NSScale routing",
                sender: "alex@example.com",
                sentDate: messageDate,
                url: "https://outlook.office.com/mail/thread-123"
            )
        )

        let output = AssistantTaskListFormatter.format(
            tasks: [task],
            filters: AssistantTaskListFormatter.Filters(status: .all, includeSource: true)
        )

        XCTAssertTrue(output.contains("""
        - 04/09/2026
          - Send routing summary
            Alex asked for the latest gateway recommendation.
            Source: Outlook email from alex@example.com, "Follow up on NSScale routing" (04/08/2026)
            Link: https://outlook.office.com/mail/thread-123
        """))
    }

    func testAssistantTaskListActionParsesSlashDateFilter() throws {
        let filters = AssistantTaskListFormatter.filters(from: [
            "after": "03/13/2026",
            "include_completed": true
        ])

        let components = Calendar.current.dateComponents([.year, .month, .day], from: try XCTUnwrap(filters.after))
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 3)
        XCTAssertEqual(components.day, 13)
        XCTAssertEqual(filters.status, .all)
    }

    func testAssistantTaskListActionParsesNaturalLanguageAfterDate() throws {
        let filters = AssistantTaskListFormatter.filters(fromPrompt: "list all my tasks after 03/13/2026 so that I can copy them to a google doc")

        let components = Calendar.current.dateComponents([.year, .month, .day], from: try XCTUnwrap(filters.after))
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 3)
        XCTAssertEqual(components.day, 13)
        XCTAssertEqual(filters.status, .all)
    }

    func testAssistantTaskListActionParsesNaturalLanguageSinceDate() throws {
        let filters = AssistantTaskListFormatter.filters(fromPrompt: "List my tasks since 03/13/2026")

        let components = Calendar.current.dateComponents([.year, .month, .day], from: try XCTUnwrap(filters.after))
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 3)
        XCTAssertEqual(components.day, 13)
        XCTAssertEqual(filters.status, .all)
    }

    func testOutlookGraphAdapterUsesExplicitBoundedMailReadSearch() throws {
        let source = try outlookGraphIntegrationSource()

        XCTAssertTrue(source.contains("Mail.Read"))
        XCTAssertTrue(source.contains("offline_access"))
        XCTAssertTrue(source.contains("outlook_graph_access_token"))
        XCTAssertTrue(source.contains("outlook_graph_refresh_token"))
        XCTAssertTrue(source.contains("KeychainHelper.save(key: accessTokenKey"))
        XCTAssertTrue(source.contains("https://graph.microsoft.com/v1.0/me/messages"))
        XCTAssertTrue(source.contains("$top"))
        XCTAssertTrue(source.contains("$select"))
        XCTAssertTrue(source.contains("id,conversationId,subject,from,sentDateTime,bodyPreview,webLink"))
        XCTAssertFalse(source.contains("body,"))
        XCTAssertFalse(source.contains("https://graph.microsoft.com/v1.0/me/mailFolders"))
    }

    func testOutlookGraphAdapterBuildsSearchURLWithoutMailboxSync() throws {
        let client = OutlookGraphClient(accessTokenProvider: { "token" })
        let request = OutlookMailSearchRequest(query: "Nscale routing", limit: 50)
        let url = client.searchURL(for: request)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })

        XCTAssertEqual(components.path, "/v1.0/me/messages")
        XCTAssertEqual(items["$top"], "25")
        XCTAssertEqual(items["$search"], "\"Nscale routing\"")
        XCTAssertEqual(items["$select"], "id,conversationId,subject,from,sentDateTime,bodyPreview,webLink")
        XCTAssertNil(items["$expand"])
    }

    func testOutlookGraphCandidatePreservesOnlyTaskContentAndMinimalSourceMetadata() throws {
        let data = """
        {"value":[{"id":"message-1","conversationId":"thread-1","subject":"RE: Nscale routing follow-up","from":{"emailAddress":{"name":"Alex","address":"alex@example.com"}},"sentDateTime":"2026-05-18T14:30:00Z","bodyPreview":" Please send the gateway routing summary.   Thanks. ","webLink":"https://outlook.office.com/mail/message-1"}]}
        """.data(using: .utf8)!

        let message = try XCTUnwrap(OutlookGraphClient.decodeMessages(from: data).first)
        let candidate = OutlookTaskCandidate.from(message: message)

        XCTAssertEqual(candidate.title, "Nscale routing follow-up")
        XCTAssertEqual(candidate.description, "Please send the gateway routing summary. Thanks.")
        XCTAssertEqual(candidate.sourceMetadata.kind, .email)
        XCTAssertEqual(candidate.sourceMetadata.provider, "outlook")
        XCTAssertEqual(candidate.sourceMetadata.threadID, "thread-1")
        XCTAssertEqual(candidate.sourceMetadata.messageID, "message-1")
        XCTAssertEqual(candidate.sourceMetadata.subject, "RE: Nscale routing follow-up")
        XCTAssertEqual(candidate.sourceMetadata.sender, "Alex <alex@example.com>")
        XCTAssertEqual(candidate.sourceMetadata.url, "https://outlook.office.com/mail/message-1")
    }

    func testChatAssistantExposesOutlookSearchReviewAndApprovalActions() throws {
        let source = try chatManagerSource()

        XCTAssertTrue(source.contains("- search_outlook_tasks: {\"action\":\"search_outlook_tasks\""))
        XCTAssertTrue(source.contains("- approve_outlook_tasks: {\"action\":\"approve_outlook_tasks\""))
        XCTAssertTrue(source.contains("use search_outlook_tasks first and ask the user to approve candidates"))
        XCTAssertTrue(source.contains("do not store full email bodies by default"))
        XCTAssertTrue(source.contains("private var pendingOutlookTaskCandidates"))
        XCTAssertTrue(source.contains("case \"search_outlook_tasks\""))
        XCTAssertTrue(source.contains("OutlookGraphClient"))
        XCTAssertTrue(source.contains("AssistantOutlookCandidateFormatter.format"))
        XCTAssertTrue(source.contains("case \"approve_outlook_tasks\""))
        XCTAssertTrue(source.contains("sourceMetadata: candidate.sourceMetadata"))
    }

    func testSettingsExposesMicrosoftGraphConfigurationWithoutSecretsInDefaults() throws {
        let settingsSource = try settingsSource()

        XCTAssertTrue(settingsSource.contains("@AppStorage(OutlookGraphSettings.clientIDKey)"))
        XCTAssertTrue(settingsSource.contains("@AppStorage(OutlookGraphSettings.tenantIDKey)"))
        XCTAssertTrue(settingsSource.contains("Microsoft Outlook"))
        XCTAssertTrue(settingsSource.contains("Sign In with Microsoft"))
        XCTAssertTrue(settingsSource.contains("stores tokens in Keychain"))
        XCTAssertFalse(settingsSource.contains("@AppStorage(\"outlook_graph_access_token\")"))
        XCTAssertFalse(settingsSource.contains("@AppStorage(\"outlook_graph_refresh_token\")"))
    }

    func testSidebarDividerIsFullHeightShellChrome() throws {
        let source = try meetingLibrarySource()

        XCTAssertTrue(source.contains("private let sidebarDividerHitWidth"))
        XCTAssertTrue(source.contains("sidebarResizeDivider(layout: layout, effectiveSidebarWidth: effectiveSidebarWidth)"))
        XCTAssertTrue(source.contains("private func sidebarResizeDivider"))
        XCTAssertTrue(source.contains(".ignoresSafeArea(edges: .top)"))
        XCTAssertFalse(source.contains("Rectangle()\n                        .fill(Theme.border)\n                        .frame(width: 1)\n                        .contentShape(Rectangle())"))
    }

    func testRichMarkdownEditorUsesAppContentBackground() throws {
        let editorSource = try richMarkdownEditorSource()
        let themeSource = try themeSource()

        XCTAssertTrue(themeSource.contains("static let contentBGNSColor"))
        XCTAssertTrue(editorSource.contains("RichMarkdownEditorTheme.background"))
        XCTAssertTrue(editorSource.contains("textView.backgroundColor = RichMarkdownEditorTheme.background"))
        XCTAssertTrue(editorSource.contains("scrollView.backgroundColor = RichMarkdownEditorTheme.background"))
        XCTAssertFalse(editorSource.contains("textView.backgroundColor = NSColor(red: 0.122"))
        XCTAssertFalse(editorSource.contains("layer?.backgroundColor = NSColor(red: 0.122"))
    }

    func testRichMarkdownEditorCodeBlocksUseAppContentBackground() throws {
        let editorSource = try richMarkdownEditorSource()

        XCTAssertTrue(editorSource.contains("static let codeBlockBackground = Theme.contentBGNSColor"))
        XCTAssertTrue(editorSource.contains("storage.addAttribute(.backgroundColor, value: RichMarkdownEditorTheme.codeBlockBackground"))
        XCTAssertFalse(editorSource.contains("let codeBG = NSColor(white: 0.15"))
    }

    func testMarkdownRendererCodeBlocksUseAppContentBackground() throws {
        let rendererSource = try markdownRendererSource()

        XCTAssertTrue(rendererSource.contains(".background(Theme.contentBG, in: RoundedRectangle(cornerRadius: 8))"))
        XCTAssertFalse(rendererSource.contains(".background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))"))
    }

    private func meetingLibrarySource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let sidebarFile = projectRoot.appendingPathComponent("NoteAI/UI/MeetingLibrary/MeetingLibraryView.swift")
        return try String(contentsOf: sidebarFile, encoding: .utf8)
    }

    private func homeDashboardSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let dashboardFile = projectRoot.appendingPathComponent("NoteAI/UI/Home/HomeDashboardView.swift")
        return try String(contentsOf: dashboardFile, encoding: .utf8)
    }

    private func todoDetailSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let todoDetailFile = projectRoot.appendingPathComponent("NoteAI/UI/Todos/TodoDetailView.swift")
        return try String(contentsOf: todoDetailFile, encoding: .utf8)
    }

    private func taskDetailSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let taskDetailFile = projectRoot.appendingPathComponent("NoteAI/UI/Tasks/TaskDetailView.swift")
        return try String(contentsOf: taskDetailFile, encoding: .utf8)
    }

    private func chatManagerSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let chatManagerFile = projectRoot.appendingPathComponent("NoteAI/UI/Chat/ChatManager.swift")
        return try String(contentsOf: chatManagerFile, encoding: .utf8)
    }

    private func outlookGraphIntegrationSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let integrationFile = projectRoot.appendingPathComponent("NoteAI/Integrations/Outlook/OutlookGraphIntegration.swift")
        return try String(contentsOf: integrationFile, encoding: .utf8)
    }

    private func t5tComposerSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let composerFile = projectRoot.appendingPathComponent("NoteAI/UI/T5T/T5TComposerView.swift")
        return try String(contentsOf: composerFile, encoding: .utf8)
    }

    private func t5tMailDraftSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let mailDraftFile = projectRoot.appendingPathComponent("NoteAI/Delivery/T5TMailDraft.swift")
        return try String(contentsOf: mailDraftFile, encoding: .utf8)
    }

    private func taskSelectorSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let selectorFile = projectRoot.appendingPathComponent("NoteAI/UI/T5T/TodoSelectorView.swift")
        return try String(contentsOf: selectorFile, encoding: .utf8)
    }

    private func summarizationEngineSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let engineFile = projectRoot.appendingPathComponent("NoteAI/Summarization/SummarizationEngine.swift")
        return try String(contentsOf: engineFile, encoding: .utf8)
    }

    private func t5tPromptSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let promptFile = projectRoot.appendingPathComponent("NoteAI/Summarization/T5TPrompt.swift")
        return try String(contentsOf: promptFile, encoding: .utf8)
    }

    private func t5tConfigSheetSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let configFile = projectRoot.appendingPathComponent("NoteAI/UI/T5T/T5TConfigSheet.swift")
        return try String(contentsOf: configFile, encoding: .utf8)
    }

    private func settingsSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let settingsFile = projectRoot.appendingPathComponent("NoteAI/UI/Settings/SettingsView.swift")
        return try String(contentsOf: settingsFile, encoding: .utf8)
    }

    private func appDelegateSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let appDelegateFile = projectRoot.appendingPathComponent("NoteAI/App/AppDelegate.swift")
        return try String(contentsOf: appDelegateFile, encoding: .utf8)
    }

    private func richMarkdownEditorSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let editorFile = projectRoot.appendingPathComponent("NoteAI/UI/MarkdownEditor/RichMarkdownEditor.swift")
        return try String(contentsOf: editorFile, encoding: .utf8)
    }

    private func markdownRendererSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let rendererFile = projectRoot.appendingPathComponent("NoteAI/UI/MarkdownEditor/MarkdownRendererView.swift")
        return try String(contentsOf: rendererFile, encoding: .utf8)
    }

    private func themeSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let themeFile = projectRoot.appendingPathComponent("NoteAI/UI/Theme.swift")
        return try String(contentsOf: themeFile, encoding: .utf8)
    }

    func testCommandCenterPanelOrderAppliesSavedOrderAndAppendsMissingPanels() {
        let rawOrder = "v2:upcoming,operationalSnapshot,unknown,upcoming,focusQueue"

        let ordered = CommandCenterPanelOrder.orderedIDs(
            availableIDs: DashboardPanelID.defaultOrder,
            rawValue: rawOrder
        )

        XCTAssertEqual(ordered, [
            .upcoming,
            .operationalSnapshot,
            .focusQueue,
            .suggestedNextMove,
            .recentlyCompleted,
            .setupChecklist,
        ])
    }

    func testCommandCenterPanelOrderIgnoresLegacyUnversionedSavedOrder() {
        let rawOrder = "upcoming,operationalSnapshot,focusQueue"

        let ordered = CommandCenterPanelOrder.orderedIDs(
            availableIDs: DashboardPanelID.defaultOrder,
            rawValue: rawOrder
        )

        XCTAssertEqual(ordered, DashboardPanelID.defaultOrder)
    }

    func testCommandCenterPanelRowsUseCopilotLikePairsWithSetupPinnedFullWidth() {
        let rows = CommandCenterPanelOrder.rows(for: DashboardPanelID.defaultOrder)

        XCTAssertEqual(rows, [
            [.operationalSnapshot, .suggestedNextMove],
            [.focusQueue, .upcoming],
            [.recentlyCompleted],
            [.setupChecklist],
        ])
    }

    func testCommandCenterPanelDropMovesDraggedPanelAfterLaterTarget() {
        let moved = CommandCenterPanelOrder.moveForDrop(
            .operationalSnapshot,
            onto: .upcoming,
            in: DashboardPanelID.defaultOrder
        )

        XCTAssertEqual(moved, [
            .suggestedNextMove,
            .focusQueue,
            .upcoming,
            .operationalSnapshot,
            .recentlyCompleted,
            .setupChecklist,
        ])
        XCTAssertEqual(
            CommandCenterPanelOrder.rawValue(for: moved),
            "v2:suggestedNextMove,focusQueue,upcoming,operationalSnapshot,recentlyCompleted,setupChecklist"
        )
    }

    func testCommandCenterPanelDropMovesDraggedPanelBeforeEarlierTarget() {
        let moved = CommandCenterPanelOrder.moveForDrop(
            .upcoming,
            onto: .suggestedNextMove,
            in: DashboardPanelID.defaultOrder
        )

        XCTAssertEqual(moved, [
            .operationalSnapshot,
            .upcoming,
            .suggestedNextMove,
            .focusQueue,
            .recentlyCompleted,
            .setupChecklist,
        ])
    }

    func testOAuthCallbackRequiresExpectedState() {
        let valid = "GET /?code=abc123&state=state-1 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        let missingState = "GET /?code=abc123 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        let wrongState = "GET /?code=abc123&state=state-2 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"

        XCTAssertEqual(OAuthCallbackParser.authorizationCode(from: valid, expectedState: "state-1"), "abc123")
        XCTAssertNil(OAuthCallbackParser.authorizationCode(from: missingState, expectedState: "state-1"))
        XCTAssertNil(OAuthCallbackParser.authorizationCode(from: wrongState, expectedState: "state-1"))
    }

    func testReadAloudTextResolverPrefersSelectedText() {
        XCTAssertEqual(
            ReadAloudTextResolver.textToRead(fallback: "Read the whole note") { " selected sentence " },
            "selected sentence"
        )
        XCTAssertEqual(
            ReadAloudTextResolver.textToRead(fallback: "Read the whole note") { "   \n" },
            "Read the whole note"
        )
        XCTAssertEqual(
            ReadAloudTextResolver.textToRead(fallback: "Read the whole note") { nil },
            "Read the whole note"
        )
    }

    private func repositoryRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "NoteAITests" {
            url.deleteLastPathComponent()
        }
        url.deleteLastPathComponent()
        return url
    }
}
