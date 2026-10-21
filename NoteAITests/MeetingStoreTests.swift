import XCTest
import GRDB
@testable import NoteAI

final class MeetingStoreTests: XCTestCase {
    private func temporaryStoreDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteAI-MeetingStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func makeStore() throws -> MeetingStore {
        try MeetingStore(directoryURL: temporaryStoreDirectory())
    }

    func testFreshStoreCreatesOnlyMeetingStorage() throws {
        let directory = try temporaryStoreDirectory()
        let store = try MeetingStore(directoryURL: directory)
        let database = try DatabaseQueue(path: directory.appendingPathComponent("meetings.sqlite").path)

        let tables = try database.read { database in
            try String.fetchAll(database, sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
        }

        XCTAssertEqual(tables, ["meetings"])
        XCTAssertTrue(try store.fetchAll().isEmpty)
    }

    func testOpeningStorePreservesRetiredTablesAndExistingMeetings() throws {
        let directory = try temporaryStoreDirectory()
        let database = try DatabaseQueue(path: directory.appendingPathComponent("meetings.sqlite").path)
        let legacyTodo = """
        {"id":"22222222-2222-2222-2222-222222222222","title":"Completed historical task","description":"Preserve this work record exactly as it was saved.","completed":true,"createdDate":0,"modifiedDate":0}
        """
        let legacyMeeting = """
        {"id":"11111111-1111-1111-1111-111111111111","title":"Archived meeting","date":0,"duration":60,"transcript":[{"id":1,"text":"Keep the beta plan.","startTime":0,"endTime":3,"speaker":"speaker-1","confidence":0.9}],"summary":{"decisions":["Keep beta"],"actionItems":[{"id":"legacy-action","task":"Follow up","owner":"JP","deadline":null,"isCompleted":true}],"topics":["Beta"],"openQuestions":[],"wasSummarized":true},"speakerLabels":{"speaker-1":"JP"}}
        """
        let retiredTables = ["notes", "t5t_config", "t5t_reports", "tasks", "todos"]

        try database.write { database in
            try database.execute(sql: "CREATE TABLE meetings (id TEXT PRIMARY KEY, title TEXT NOT NULL, date REAL NOT NULL, duration REAL NOT NULL, json_data TEXT NOT NULL)")
            try database.execute(sql: "CREATE TABLE notes (id TEXT PRIMARY KEY, title TEXT NOT NULL, created_date REAL NOT NULL, modified_date REAL NOT NULL, json_data TEXT NOT NULL)")
            try database.execute(sql: "CREATE TABLE t5t_config (id INTEGER PRIMARY KEY CHECK (id = 1), json_data TEXT NOT NULL)")
            try database.execute(sql: "CREATE TABLE t5t_reports (id TEXT PRIMARY KEY, created_date REAL NOT NULL, period_start REAL NOT NULL, period_end REAL NOT NULL, status TEXT NOT NULL DEFAULT 'draft', json_data TEXT NOT NULL)")
            try database.execute(sql: "CREATE TABLE tasks (id TEXT PRIMARY KEY, title TEXT NOT NULL, created_date REAL NOT NULL, modified_date REAL NOT NULL, status TEXT NOT NULL DEFAULT 'open', work_date REAL, completed_date REAL, source_meeting_id TEXT, source_action_item_id TEXT, source_note_id TEXT, json_data TEXT NOT NULL)")
            try database.execute(sql: "CREATE TABLE todos (id TEXT PRIMARY KEY, title TEXT NOT NULL, created_date REAL NOT NULL, modified_date REAL NOT NULL, completed INTEGER NOT NULL DEFAULT 0, due_date REAL, json_data TEXT NOT NULL)")
            try database.execute(sql: "INSERT INTO meetings VALUES (?, ?, ?, ?, ?)", arguments: ["11111111-1111-1111-1111-111111111111", "Archived meeting", 0, 60, legacyMeeting])
            try database.execute(sql: "INSERT INTO notes VALUES ('note-1', 'Historical note', 0, 0, '{\"content\":\"Preserved note\"}')")
            try database.execute(sql: "INSERT INTO t5t_config VALUES (1, '{\"subjectLine\":\"Historical report\"}')")
            try database.execute(sql: "INSERT INTO t5t_reports VALUES ('report-1', 0, 0, 60, 'finalized', '{\"title\":\"Historical report\"}')")
            try database.execute(sql: "INSERT INTO tasks (id, title, created_date, modified_date, status, json_data) VALUES ('task-1', 'Historical task', 0, 0, 'completed', '{\"title\":\"Historical task\"}')")
            try database.execute(sql: "INSERT INTO todos VALUES (?, ?, 0, 0, 1, NULL, ?)", arguments: ["22222222-2222-2222-2222-222222222222", "Completed historical task", legacyTodo])
        }

        let originalSchemas = try database.read { database in
            try String.fetchAll(database, sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name != 'meetings' ORDER BY name")
        }
        let originalRows = try database.read { database in
            try retiredTables.map { table in
                try Row.fetchAll(database, sql: "SELECT * FROM \(table) ORDER BY id")
            }
        }

        let store = try MeetingStore(directoryURL: directory)
        let meetingID = try XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        var meeting = try XCTUnwrap(store.fetch(meetingId: meetingID))
        XCTAssertEqual(meeting.summary.actionItems.first?.id, "legacy-action")
        XCTAssertEqual(meeting.summary.actionItems.first?.isCompleted, true)
        XCTAssertEqual(meeting.speakerDisplayName(for: meeting.transcript[0]), "JP")

        meeting.title = "Reviewed archived meeting"
        try store.save(meeting: meeting)
        let reopenedStore = try MeetingStore(directoryURL: directory)
        let reopenedMeeting = try XCTUnwrap(reopenedStore.fetch(meetingId: meetingID))
        XCTAssertEqual(reopenedMeeting.title, "Reviewed archived meeting")
        XCTAssertEqual(reopenedMeeting.summary.decisions, ["Keep beta"])
        XCTAssertEqual(reopenedMeeting.summary.actionItems.first?.id, "legacy-action")
        XCTAssertEqual(reopenedMeeting.summary.actionItems.first?.task, "Follow up")
        XCTAssertEqual(reopenedMeeting.summary.actionItems.first?.owner, "JP")
        XCTAssertEqual(reopenedMeeting.summary.actionItems.first?.isCompleted, true)
        XCTAssertEqual(reopenedMeeting.speakerDisplayName(for: reopenedMeeting.transcript[0]), "JP")
        XCTAssertEqual(try reopenedStore.fetchAll().count, 1)

        let preservedSchemas = try database.read { database in
            try String.fetchAll(database, sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name != 'meetings' ORDER BY name")
        }
        let preservedRows = try database.read { database in
            try retiredTables.map { table in
                try Row.fetchAll(database, sql: "SELECT * FROM \(table) ORDER BY id")
            }
        }
        XCTAssertEqual(preservedSchemas, originalSchemas)
        XCTAssertEqual(preservedRows, originalRows)
    }

    func testSaveAndFetchMeeting() throws {
        let store = try makeStore()

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
        let store = try makeStore()
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

    func testSpeakerProfilesPersistWithMeetingJSONAndDriveDisplayNames() throws {
        let store = try makeStore()
        var meeting = Meeting(
            id: UUID(),
            title: "Speaker Profile Persistence",
            date: Date(timeIntervalSince1970: 0),
            duration: 60,
            transcript: [
                TranscriptSegment(id: 1, text: "We should prioritize the beta.", startTime: 0, speaker: "speaker-remote", confidence: 0.9)
            ],
            summary: MeetingSummary(),
            speakerLabels: ["speaker-remote": "Customer"]
        )

        meeting.setSpeakerProfile(
            SpeakerProfile(
                speakerID: "speaker-remote",
                name: "Sarah Chen",
                role: "VP of Product",
                company: "Acme",
                notes: "Decision maker for the beta plan."
            )
        )

        try store.save(meeting: meeting)
        let fetched = try XCTUnwrap(store.fetch(meetingId: meeting.id))

        XCTAssertEqual(fetched.speakerProfiles["speaker-remote"]?.name, "Sarah Chen")
        XCTAssertEqual(fetched.speakerProfiles["speaker-remote"]?.role, "VP of Product")
        XCTAssertEqual(fetched.speakerProfiles["speaker-remote"]?.company, "Acme")
        XCTAssertEqual(fetched.speakerProfiles["speaker-remote"]?.notes, "Decision maker for the beta plan.")
        XCTAssertEqual(fetched.speakerDisplayName(for: fetched.transcript[0]), "Sarah Chen")

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
        XCTAssertEqual(meeting.speakerProfiles, [:])
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
