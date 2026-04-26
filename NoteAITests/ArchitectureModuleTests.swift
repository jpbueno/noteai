import XCTest
@testable import NoteAI

final class ArchitectureModuleTests: XCTestCase {
    func testLibraryOperationsFilterAcrossMeetingsNotesAndTasks() {
        let meeting = Meeting(
            id: UUID(),
            title: "Roadmap Sync",
            date: Date(),
            duration: 120,
            transcript: [TranscriptSegment(text: "Discussed Grace roadmap")],
            summary: MeetingSummary(decisions: ["Ship preview"], topics: ["Inference"])
        )
        let note = Note(title: "Customer Notes", content: "Blackwell rollout", tags: ["account"])
        let task = TaskItem(title: "Draft follow-up", rawInput: "Send Grace notes", tags: ["email"])

        let result = LibraryOperations.filter(
            meetings: [meeting],
            notes: [note],
            tasks: [task],
            query: "grace"
        )

        XCTAssertEqual(result.meetings.map(\.id), [meeting.id])
        XCTAssertEqual(result.notes.count, 0)
        XCTAssertEqual(result.tasks.map(\.id), [task.id])
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

    func testOAuthCallbackRequiresExpectedState() {
        let valid = "GET /?code=abc123&state=state-1 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        let missingState = "GET /?code=abc123 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        let wrongState = "GET /?code=abc123&state=state-2 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"

        XCTAssertEqual(OAuthCallbackParser.authorizationCode(from: valid, expectedState: "state-1"), "abc123")
        XCTAssertNil(OAuthCallbackParser.authorizationCode(from: missingState, expectedState: "state-1"))
        XCTAssertNil(OAuthCallbackParser.authorizationCode(from: wrongState, expectedState: "state-1"))
    }
}
