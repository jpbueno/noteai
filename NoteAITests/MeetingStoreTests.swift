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

    func testPlainTextExportIncludesAllEditedSummarySections() {
        var summary = MeetingSummary(
            decisions: ["Keep edited decision"],
            actionItems: [ActionItem(task: "Follow up with customer", owner: "Ana", deadline: "2026-05-08")],
            topics: ["Edited topic"],
            openQuestions: ["Edited question?"],
            wasSummarized: true
        )
        summary.mark(.decisions, state: .userEdited, modifiedAt: Date(timeIntervalSince1970: 10))
        summary.mark(.topics, state: .userEdited, modifiedAt: Date(timeIntervalSince1970: 20))
        let meeting = Meeting(
            id: UUID(),
            title: "Edited Summary Export",
            date: Date(),
            duration: 60,
            transcript: [],
            summary: summary
        )

        let text = ExportManager.exportAsPlainText(meeting)

        XCTAssertTrue(text.contains("Keep edited decision"))
        XCTAssertTrue(text.contains("Follow up with customer"))
        XCTAssertTrue(text.contains("Edited topic"))
        XCTAssertTrue(text.contains("Edited question?"))
    }

    func testMarkdownExportIncludesSharedSourceFieldsAndTaskList() {
        let meetingID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        var meeting = Meeting(
            id: meetingID,
            title: "Q3 / Launch: Readout?",
            date: Date(timeIntervalSince1970: 0),
            duration: 3661,
            transcript: [
                TranscriptSegment(id: 1, text: "We approved launch.", startTime: 0, endTime: 2, speaker: "Ana", confidence: 0.95),
                TranscriptSegment(id: 2, text: "I will update the brief.", startTime: 65, endTime: 68, speaker: nil, confidence: 0.9)
            ],
            summary: MeetingSummary(
                decisions: ["Launch next week"],
                actionItems: [
                    ActionItem(task: "Update launch brief", owner: "Dev", deadline: "2026-05-01", isCompleted: false),
                    ActionItem(task: "Publish notes", owner: nil, deadline: nil, isCompleted: true)
                ],
                topics: ["Launch", "Readout"],
                openQuestions: ["Who sends the customer note?"],
                wasSummarized: true
            )
        )
        meeting.setSpeakerLabel(speakerID: "speaker-1", displayName: "JP")

        let markdown = ExportManager.exportAsMarkdown(meeting)

        XCTAssertTrue(markdown.contains("**Source:** `noteai://meeting/11111111-1111-1111-1111-111111111111`"))
        XCTAssertTrue(markdown.contains("**Segments:** 2"))
        XCTAssertTrue(markdown.contains("- [ ] Update launch brief — **Dev** (by 2026-05-01)"))
        XCTAssertTrue(markdown.contains("- [x] Publish notes"))
        XCTAssertTrue(markdown.contains("**[01:05] JP:** I will update the brief."))
        XCTAssertEqual(ExportManager.markdownFilename(for: meeting), "Q3 - Launch- Readout.md")
    }

    func testSpeakerLabelsPersistWithMeetingJSON() throws {
        let store = MeetingStore()
        var meeting = Meeting(
            id: UUID(),
            title: "Speaker Label Persistence",
            date: Date(timeIntervalSince1970: 0),
            duration: 60,
            transcript: [
                TranscriptSegment(id: 1, text: "Hello from the fallback speaker.", startTime: 0, speaker: "speaker-1", confidence: 0.9)
            ],
            summary: MeetingSummary()
        )
        meeting.setSpeakerLabel(speakerID: "speaker-1", displayName: "JP")

        try store.save(meeting: meeting)
        let fetched = try XCTUnwrap(store.fetch(meetingId: meeting.id))

        XCTAssertEqual(fetched.speakerLabels["speaker-1"], "JP")
        XCTAssertEqual(fetched.speakerDisplayName(for: fetched.transcript[0]), "JP")

        try store.delete(meetingId: meeting.id)
    }

    func testLegacyMeetingDecodesWithEmptySpeakerLabels() throws {
        let data = """
        {"id":"11111111-1111-1111-1111-111111111111","title":"Legacy","date":0,"duration":60,"transcript":[],"summary":{"decisions":[],"actionItems":[],"topics":[],"openQuestions":[],"wasSummarized":false}}
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let meeting = try decoder.decode(Meeting.self, from: data)

        XCTAssertEqual(meeting.speakerLabels, [:])
    }

    func testPDFExportCreatesShareableMeetingRecord() throws {
        let meeting = Meeting(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            title: "PDF Export Review",
            date: Date(timeIntervalSince1970: 0),
            duration: 120,
            transcript: [
                TranscriptSegment(id: 1, text: "Review the PDF export.", startTime: 3, endTime: 5, speaker: "PM", confidence: 0.95)
            ],
            summary: MeetingSummary(
                decisions: ["Ship PDF export"],
                actionItems: [ActionItem(task: "Verify generated PDF", owner: "QA", deadline: nil)],
                topics: ["Export"],
                openQuestions: [],
                wasSummarized: true
            )
        )

        let pdfData = try ExportManager.exportAsPDFData(meeting)

        XCTAssertGreaterThan(pdfData.count, 100)
        XCTAssertEqual(String(data: pdfData.prefix(4), encoding: .ascii), "%PDF")
        XCTAssertEqual(ExportManager.pdfFilename(for: meeting), "PDF Export Review.pdf")
    }
}
