import XCTest
@testable import NoteAI

final class MeetingStoreTests: XCTestCase {
    func testSaveAndFetchMeeting() throws {
        let store = MeetingStore()

        let meeting = Meeting(
            id: UUID(),
            title: "Test Meeting",
            date: Date(),
            duration: 3600,
            transcript: [
                TranscriptSegment(
                    id: 1,
                    text: "Hello, let's start the meeting.",
                    startTime: 0,
                    endTime: 3,
                    speaker: "Alice",
                    confidence: 0.95
                ),
                TranscriptSegment(
                    id: 2,
                    text: "Sounds good, what's on the agenda?",
                    startTime: 3,
                    endTime: 6,
                    speaker: "Bob",
                    confidence: 0.92
                )
            ],
            summary: MeetingSummary(
                decisions: ["Approved Q3 roadmap"],
                actionItems: [
                    ActionItem(task: "Send follow-up email", owner: "Alice", deadline: "2026-03-20")
                ],
                topics: ["Q3 planning", "Budget review"],
                openQuestions: ["When is the next review?"]
            )
        )

        try store.save(meeting: meeting)

        let fetched = try store.fetch(meetingId: meeting.id)
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.title, "Test Meeting")
        XCTAssertEqual(fetched?.transcript.count, 2)
        XCTAssertEqual(fetched?.summary.decisions.count, 1)
        XCTAssertEqual(fetched?.summary.actionItems.count, 1)

        // Cleanup
        try store.delete(meetingId: meeting.id)
        let deleted = try store.fetch(meetingId: meeting.id)
        XCTAssertNil(deleted)
    }

    func testExportAsMarkdown() {
        let meeting = Meeting(
            id: UUID(),
            title: "Sprint Review",
            date: Date(),
            duration: 1800,
            transcript: [
                TranscriptSegment(id: 1, text: "Welcome everyone.", startTime: 0, endTime: 2, speaker: "PM")
            ],
            summary: MeetingSummary(
                decisions: ["Ship v2.0 next week"],
                actionItems: [ActionItem(task: "Update changelog", owner: "Dev", deadline: nil)],
                topics: ["Release planning"],
                openQuestions: []
            )
        )

        let markdown = ExportManager.exportAsMarkdown(meeting)
        XCTAssertTrue(markdown.contains("# Sprint Review"))
        XCTAssertTrue(markdown.contains("Ship v2.0 next week"))
        XCTAssertTrue(markdown.contains("Update changelog"))
        XCTAssertTrue(markdown.contains("Welcome everyone."))
    }
}
