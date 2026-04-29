import XCTest
@testable import NoteAI

final class ChatSourceContextTests: XCTestCase {
    func testContextLabelsWorkspaceSourcesWithSharedLinks() {
        let meetingID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let noteID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let reportID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

        let context = ChatSourceContext.build(
            meetings: [
                Meeting(
                    id: meetingID,
                    title: "Roadmap Sync",
                    date: Date(timeIntervalSince1970: 0),
                    duration: 1800,
                    transcript: [TranscriptSegment(text: "Grace Blackwell rollout is blocked on QA.")],
                    summary: MeetingSummary(decisions: ["Ship the rollout preview"], topics: ["Grace Blackwell"])
                )
            ],
            notes: [
                Note(id: noteID, title: "Customer Brief", content: "Crusoe wants benchmarks before the readout.")
            ],
            t5tReports: [
                T5TReport(
                    id: reportID,
                    title: "Top 5 Things",
                    createdDate: Date(timeIntervalSince1970: 0),
                    periodStart: Date(timeIntervalSince1970: 0),
                    periodEnd: Date(timeIntervalSince1970: 86_400),
                    meetingIDs: [],
                    sections: T5TSections(
                        insights: [],
                        accountUpdates: [T5TEntry(headline: "Crusoe benchmarking", explanation: "Enabled benchmark planning.")],
                        futurePlans: []
                    ),
                    status: .draft
                )
            ]
        )

        XCTAssertTrue(context.contains("[M1] Meeting: Roadmap Sync (noteai://meeting/\(meetingID.uuidString))"))
        XCTAssertTrue(context.contains("[N1] Note: Customer Brief (noteai://note/\(noteID.uuidString))"))
        XCTAssertTrue(context.contains("[R1] T5T: Top 5 Things (noteai://t5t/\(reportID.uuidString))"))
        XCTAssertTrue(context.contains("cite it with a markdown link"))
        XCTAssertTrue(context.localizedCaseInsensitiveContains("do not have enough NoteAI source material"))
        XCTAssertFalse(context.localizedCaseInsensitiveContains("tasks"))
        XCTAssertFalse(context.contains("noteai://task/"))
    }

    func testSourceLinkParserReadsSharedLinksWithoutLegacyTasks() {
        let id = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!

        XCTAssertEqual(ChatSourceLink(urlString: "noteai://meeting/\(id.uuidString)")?.kind, .meeting)
        XCTAssertEqual(ChatSourceLink(urlString: "noteai://note/\(id.uuidString)")?.kind, .note)
        XCTAssertEqual(ChatSourceLink(urlString: "noteai://t5t/\(id.uuidString)")?.kind, .t5t)
        XCTAssertNil(ChatSourceLink(urlString: "noteai://task/\(id.uuidString)"))
        XCTAssertNil(ChatSourceLink(urlString: "https://example.com"))
    }
}
