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

        XCTAssertGreaterThanOrEqual(wide.sidebarWidth, 220)
        XCTAssertLessThanOrEqual(wide.sidebarWidth, 244)
        XCTAssertGreaterThanOrEqual(wide.contentMaxWidth, 1320)
        XCTAssertLessThanOrEqual(wide.scale, 1)
        XCTAssertLessThanOrEqual(wide.titleFontSize, 28)
        XCTAssertLessThanOrEqual(wide.metricValueFontSize, 20)
        XCTAssertLessThanOrEqual(wide.sectionTitleFontSize, 13)
        XCTAssertLessThanOrEqual(wide.bodyFontSize, 11)
        XCTAssertLessThanOrEqual(wide.smallFontSize, 10)
        XCTAssertLessThanOrEqual(wide.tinyFontSize, 9)
        XCTAssertLessThanOrEqual(wide.controlHeight, 35)
        XCTAssertLessThanOrEqual(wide.actionButtonHeight, 38)
    }

    func testCommandCenterPanelOrderAppliesSavedOrderAndAppendsMissingPanels() {
        let rawOrder = "upcoming,operationalSnapshot,unknown,upcoming,focusQueue"

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

    func testCommandCenterPanelColumnsUseCopilotLikeTwoColumnStacks() {
        let columns = CommandCenterPanelOrder.columns(for: DashboardPanelID.defaultOrder)

        XCTAssertEqual(columns.leading, [
            .operationalSnapshot,
            .focusQueue,
            .recentlyCompleted,
        ])
        XCTAssertEqual(columns.trailing, [
            .suggestedNextMove,
            .upcoming,
            .setupChecklist,
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
            "suggestedNextMove,focusQueue,upcoming,operationalSnapshot,recentlyCompleted,setupChecklist"
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
}
