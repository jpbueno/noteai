import XCTest
@testable import NoteAI

final class ArchitectureModuleTests: XCTestCase {
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

    func testMeetingCaptureWorkflowFormatsTranscriptAndFallbackSummary() {
        let segments = [
            TranscriptSegment(id: 1, text: "Hello there", startTime: 3, speaker: "Alice", confidence: 0.9),
            TranscriptSegment(id: 2, text: "Follow up next week", startTime: 65, speaker: nil, confidence: 0.9),
        ]

        let text = MeetingCaptureWorkflow.transcriptText(from: segments)
        let fallback = MeetingCaptureWorkflow.failedSummary(errorDescription: "No key")

        XCTAssertTrue(text.contains("[00:03] Alice: Hello there"))
        XCTAssertTrue(text.contains("[01:05] Speaker: Follow up next week"))
        XCTAssertEqual(fallback.topics, ["Summarization failed: No key"])
        XCTAssertFalse(fallback.wasSummarized)
    }

    func testTranscriptImportParserReadsTeamsStyleSpeakerBlocks() {
        let raw = """
        Sarah Chen
        0:01
        We should review the deployment plan before Friday.

        JP Santana 0:08
        I will summarize the risks and send the next steps.
        """

        let segments = TranscriptImportParser.parse(raw)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].speaker, "Sarah Chen")
        XCTAssertEqual(segments[0].startTime, 1, accuracy: 0.01)
        XCTAssertEqual(segments[0].text, "We should review the deployment plan before Friday.")
        XCTAssertEqual(segments[1].speaker, "JP Santana")
        XCTAssertEqual(segments[1].startTime, 8, accuracy: 0.01)
        XCTAssertEqual(segments[1].text, "I will summarize the risks and send the next steps.")
    }

    func testTranscriptImportParserPreservesTextWithoutSpeakerOrTimestamp() {
        let raw = """
        This is pasted text without Teams speaker metadata.
        It should still become a useful transcript segment.
        """

        let segments = TranscriptImportParser.parse(raw)

        XCTAssertEqual(segments.count, 1)
        XCTAssertNil(segments[0].speaker)
        XCTAssertEqual(segments[0].startTime, 0, accuracy: 0.01)
        XCTAssertEqual(segments[0].text, "This is pasted text without Teams speaker metadata. It should still become a useful transcript segment.")
    }

    func testSourceGroundedMemoryCandidateTracksEvidenceWithoutConnectorAccess() {
        let evidence = EvidenceSource(
            kind: .teamsTranscriptPaste,
            title: "Customer Sync",
            externalID: nil,
            capturedAt: Date(timeIntervalSince1970: 1_780_000_000)
        )

        let candidate = MemoryCandidate(
            kind: .project,
            summary: "DigitalOcean is validating KAI Scheduler bin-packing.",
            evidence: [evidence],
            confidence: 0.82
        )

        XCTAssertEqual(candidate.status, .proposed)
        XCTAssertEqual(candidate.evidence.first?.kind, .teamsTranscriptPaste)
        XCTAssertEqual(candidate.confidence, 0.82, accuracy: 0.001)
        XCTAssertNil(candidate.evidence.first?.externalID)
    }

    func testV6UsesSeparateLocalNamespace() {
        XCTAssertTrue(AppEnvironment.isV6(bundleIdentifier: "com.noteai.app.v6", displayName: "NoteAI v6"))
        XCTAssertEqual(
            AppEnvironment.storageNamespace(bundleIdentifier: "com.noteai.app.v6", displayName: "NoteAI v6"),
            "NoteAI-v6"
        )
        XCTAssertEqual(
            AppEnvironment.storageNamespace(bundleIdentifier: "com.noteai.app", displayName: "NoteAI"),
            "NoteAI"
        )
    }

    func testMeetingCaptureWorkflowPreservesImportedTranscriptEvidence() {
        let evidence = EvidenceSource(kind: .teamsTranscriptPaste, title: "Teams Transcript", externalID: nil)
        let meeting = MeetingCaptureWorkflow.makeMeeting(
            title: "Imported Call",
            startedAt: Date(timeIntervalSince1970: 1_780_000_000),
            transcript: [TranscriptSegment(text: "Discussed the customer plan.")],
            summary: MeetingSummary(topics: ["Customer plan"], wasSummarized: true),
            sourceEvidence: evidence
        )

        XCTAssertEqual(meeting.sourceEvidence?.kind, .teamsTranscriptPaste)
        XCTAssertEqual(meeting.sourceEvidence?.title, "Teams Transcript")
        XCTAssertEqual(meeting.transcript.first?.text, "Discussed the customer plan.")
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

    func testCommandCenterLayoutAdaptsWithoutInflatingTypography() {
        let compact = CommandCenterLayout.metrics(forWindowWidth: 980)
        let wide = CommandCenterLayout.metrics(forWindowWidth: 1700)

        XCTAssertLessThan(compact.scale, wide.scale)
        XCTAssertLessThan(compact.sidebarWidth, wide.sidebarWidth)
        XCTAssertLessThan(compact.commandSearchMaxWidth, wide.commandSearchMaxWidth)
        XCTAssertLessThan(compact.contentMaxWidth, wide.contentMaxWidth)
        XCTAssertLessThan(compact.onboardingMinimumCardWidth, wide.onboardingMinimumCardWidth)

        XCTAssertGreaterThanOrEqual(wide.sidebarWidth, 260)
        XCTAssertGreaterThanOrEqual(wide.contentMaxWidth, 1320)
        XCTAssertLessThanOrEqual(wide.titleFontSize, 35)
        XCTAssertLessThanOrEqual(wide.metricValueFontSize, 26)
        XCTAssertLessThanOrEqual(wide.sectionTitleFontSize, 16)
        XCTAssertLessThanOrEqual(wide.bodyFontSize, 14)
        XCTAssertLessThanOrEqual(wide.smallFontSize, 12)
        XCTAssertLessThanOrEqual(wide.tinyFontSize, 10)
        XCTAssertLessThanOrEqual(wide.controlHeight, 42)
        XCTAssertLessThanOrEqual(wide.actionButtonHeight, 44)
        XCTAssertLessThanOrEqual(wide.sidebarRecordButtonHeight, 38)
        XCTAssertLessThan(wide.sidebarRecordButtonHeight, wide.actionButtonHeight)
    }

    func testCommandCenterSidebarBrandAlignsWithSidebarContent() {
        let compact = CommandCenterLayout.metrics(forWindowWidth: 980)
        let wide = CommandCenterLayout.metrics(forWindowWidth: 1700)

        XCTAssertGreaterThanOrEqual(compact.sidebarBrandLeadingInset, 12)
        XCTAssertLessThanOrEqual(compact.sidebarBrandLeadingInset, 16)
        XCTAssertLessThanOrEqual(compact.sidebarBrandLeadingInset, compact.sidebarWidth * 0.36)
        XCTAssertEqual(compact.sidebarBrandLeadingInset, wide.sidebarBrandLeadingInset)
        XCTAssertGreaterThanOrEqual(compact.sidebarBrandHeaderTopPadding, 26)
        XCTAssertGreaterThanOrEqual(compact.sidebarBrandHeaderBottomPadding, 15)
        XCTAssertGreaterThanOrEqual(compact.sidebarBrandHeaderHeight, 74)
    }

    func testSidebarRecordingControlsDoNotRenderStaticSourceCards() throws {
        let source = try meetingLibrarySource()

        XCTAssertFalse(source.contains("recordingSourceCard("))
        XCTAssertFalse(source.contains("Native capture"))
        XCTAssertFalse(source.contains("subtitle: \"Ready\""))
    }

    func testCommandCenterPanelOrderIgnoresLegacySavedOrderAndUsesOrganizedDefault() {
        let rawOrder = "upcoming,operationalSnapshot,unknown,upcoming,focusQueue"

        let ordered = CommandCenterPanelOrder.orderedIDs(
            availableIDs: DashboardPanelID.defaultOrder,
            rawValue: rawOrder
        )

        XCTAssertEqual(ordered, [
            .operationalSnapshot,
            .suggestedNextMove,
            .focusQueue,
            .upcoming,
            .recentlyCompleted,
            .setupChecklist,
        ])
    }

    func testCommandCenterPanelOrderAppliesCurrentSavedOrderAndAppendsMissingPanels() {
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

    func testCommandCenterPanelRowsKeepSetupPanelAtBottomFullWidth() {
        let rows = CommandCenterPanelOrder.rows(for: [
            .setupChecklist,
            .operationalSnapshot,
            .suggestedNextMove,
            .focusQueue,
            .upcoming,
            .recentlyCompleted,
        ])

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

    func testAssistantDrawerUsesNonInteractiveMessageRendering() {
        XCTAssertFalse(ChatPanelPerformancePolicy.messageTextSelectionEnabled)
        XCTAssertFalse(ChatPanelPerformancePolicy.animatedAutoScrollEnabled)
    }

    private func meetingLibrarySource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let sidebarFile = projectRoot.appendingPathComponent("NoteAI/UI/MeetingLibrary/MeetingLibraryView.swift")
        return try String(contentsOf: sidebarFile, encoding: .utf8)
    }
}
