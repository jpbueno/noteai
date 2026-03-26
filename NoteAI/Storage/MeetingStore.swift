import Foundation
import GRDB

/// Persists meetings, transcripts, and summaries using SQLite via GRDB.
final class MeetingStore {
    private let dbQueue: DatabaseQueue

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dbDir = appSupport.appendingPathComponent("NoteAI", isDirectory: true)

        try? FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)

        let dbPath = dbDir.appendingPathComponent("meetings.sqlite").path
        do {
            dbQueue = try DatabaseQueue(path: dbPath)
            try createTablesIfNeeded()
        } catch {
            fatalError("Failed to initialize database: \(error)")
        }
    }

    func save(meeting: Meeting) throws {
        let jsonData = try JSONEncoder().encode(meeting)
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO meetings (id, title, date, duration, json_data)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [
                    meeting.id.uuidString,
                    meeting.title,
                    meeting.date.timeIntervalSince1970,
                    meeting.duration,
                    String(data: jsonData, encoding: .utf8)
                ]
            )
        }
    }

    func fetchAll() throws -> [Meeting] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT json_data FROM meetings ORDER BY date DESC"
            )
            return rows.compactMap { row -> Meeting? in
                guard let jsonString: String = row["json_data"],
                      let data = jsonString.data(using: .utf8) else { return nil }
                return try? JSONDecoder().decode(Meeting.self, from: data)
            }
        }
    }

    func fetch(meetingId: UUID) throws -> Meeting? {
        try dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT json_data FROM meetings WHERE id = ?",
                arguments: [meetingId.uuidString]
            )
            guard let jsonString: String = row?["json_data"],
                  let data = jsonString.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(Meeting.self, from: data)
        }
    }

    func delete(meetingId: UUID) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM meetings WHERE id = ?",
                arguments: [meetingId.uuidString]
            )
        }
    }

    func searchTranscripts(query: String) throws -> [Meeting] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT json_data FROM meetings WHERE json_data LIKE ? ORDER BY date DESC",
                arguments: ["%\(query)%"]
            )
            return rows.compactMap { row -> Meeting? in
                guard let jsonString: String = row["json_data"],
                      let data = jsonString.data(using: .utf8) else { return nil }
                return try? JSONDecoder().decode(Meeting.self, from: data)
            }
        }
    }

    // MARK: - Date-range queries

    func fetchMeetings(from start: Date, to end: Date) throws -> [Meeting] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT json_data FROM meetings WHERE date >= ? AND date <= ? ORDER BY date DESC",
                arguments: [start.timeIntervalSince1970, end.timeIntervalSince1970]
            )
            return rows.compactMap { row -> Meeting? in
                guard let jsonString: String = row["json_data"],
                      let data = jsonString.data(using: .utf8) else { return nil }
                return try? JSONDecoder().decode(Meeting.self, from: data)
            }
        }
    }

    func fetchMeetings(ids: [UUID]) throws -> [Meeting] {
        guard !ids.isEmpty else { return [] }
        let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
        let args = ids.map { $0.uuidString }
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT json_data FROM meetings WHERE id IN (\(placeholders)) ORDER BY date DESC",
                arguments: StatementArguments(args)
            )
            return rows.compactMap { row -> Meeting? in
                guard let jsonString: String = row["json_data"],
                      let data = jsonString.data(using: .utf8) else { return nil }
                return try? JSONDecoder().decode(Meeting.self, from: data)
            }
        }
    }

    // MARK: - T5T Reports

    func saveT5TReport(_ report: T5TReport) throws {
        let jsonData = try JSONEncoder().encode(report)
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO t5t_reports (id, created_date, period_start, period_end, status, json_data)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    report.id.uuidString,
                    report.createdDate.timeIntervalSince1970,
                    report.periodStart.timeIntervalSince1970,
                    report.periodEnd.timeIntervalSince1970,
                    report.status.rawValue,
                    String(data: jsonData, encoding: .utf8)
                ]
            )
        }
    }

    func fetchAllT5TReports() throws -> [T5TReport] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT json_data FROM t5t_reports ORDER BY created_date DESC"
            )
            return rows.compactMap { row -> T5TReport? in
                guard let jsonString: String = row["json_data"],
                      let data = jsonString.data(using: .utf8) else { return nil }
                return try? JSONDecoder().decode(T5TReport.self, from: data)
            }
        }
    }

    func deleteT5TReport(id: UUID) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM t5t_reports WHERE id = ?",
                arguments: [id.uuidString]
            )
        }
    }

    // MARK: - T5T Config (singleton)

    func saveT5TConfig(_ config: T5TConfig) throws {
        let jsonData = try JSONEncoder().encode(config)
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO t5t_config (id, json_data) VALUES (1, ?)",
                arguments: [String(data: jsonData, encoding: .utf8)]
            )
        }
    }

    func loadT5TConfig() throws -> T5TConfig? {
        try dbQueue.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT json_data FROM t5t_config WHERE id = 1")
            guard let jsonString: String = row?["json_data"],
                  let data = jsonString.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(T5TConfig.self, from: data)
        }
    }

    // MARK: - Notes

    func saveNote(_ note: Note) throws {
        let jsonData = try JSONEncoder().encode(note)
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO notes (id, title, created_date, modified_date, json_data)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [
                    note.id.uuidString,
                    note.title,
                    note.createdDate.timeIntervalSince1970,
                    note.modifiedDate.timeIntervalSince1970,
                    String(data: jsonData, encoding: .utf8)
                ]
            )
        }
    }

    func fetchAllNotes() throws -> [Note] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT json_data FROM notes ORDER BY modified_date DESC"
            )
            return rows.compactMap { row -> Note? in
                guard let jsonString: String = row["json_data"],
                      let data = jsonString.data(using: .utf8) else { return nil }
                return try? JSONDecoder().decode(Note.self, from: data)
            }
        }
    }

    func deleteNote(id: UUID) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM notes WHERE id = ?",
                arguments: [id.uuidString]
            )
        }
    }

    func fetchNotes(from start: Date, to end: Date) throws -> [Note] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT json_data FROM notes WHERE modified_date >= ? AND modified_date <= ? ORDER BY modified_date DESC",
                arguments: [start.timeIntervalSince1970, end.timeIntervalSince1970]
            )
            return rows.compactMap { row -> Note? in
                guard let jsonString: String = row["json_data"],
                      let data = jsonString.data(using: .utf8) else { return nil }
                return try? JSONDecoder().decode(Note.self, from: data)
            }
        }
    }

    // MARK: - Tasks

    func saveTask(_ task: TaskItem) throws {
        let jsonData = try JSONEncoder().encode(task)
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO tasks (id, title, created_date, modified_date, status, json_data)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    task.id.uuidString,
                    task.title,
                    task.createdDate.timeIntervalSince1970,
                    task.modifiedDate.timeIntervalSince1970,
                    task.status.rawValue,
                    String(data: jsonData, encoding: .utf8)
                ]
            )
        }
    }

    func fetchAllTasks() throws -> [TaskItem] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT json_data FROM tasks ORDER BY created_date DESC"
            )
            return rows.compactMap { row -> TaskItem? in
                guard let jsonString: String = row["json_data"],
                      let data = jsonString.data(using: .utf8) else { return nil }
                return try? JSONDecoder().decode(TaskItem.self, from: data)
            }
        }
    }

    func deleteTask(id: UUID) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM tasks WHERE id = ?",
                arguments: [id.uuidString]
            )
        }
    }

    // MARK: - Private

    private func createTablesIfNeeded() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS meetings (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    date REAL NOT NULL,
                    duration REAL NOT NULL,
                    json_data TEXT NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS t5t_reports (
                    id TEXT PRIMARY KEY,
                    created_date REAL NOT NULL,
                    period_start REAL NOT NULL,
                    period_end REAL NOT NULL,
                    status TEXT NOT NULL DEFAULT 'draft',
                    json_data TEXT NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS t5t_config (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    json_data TEXT NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS notes (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    created_date REAL NOT NULL,
                    modified_date REAL NOT NULL,
                    json_data TEXT NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS tasks (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    created_date REAL NOT NULL,
                    modified_date REAL NOT NULL,
                    status TEXT NOT NULL DEFAULT 'pending',
                    json_data TEXT NOT NULL
                )
                """)
        }
    }
}
