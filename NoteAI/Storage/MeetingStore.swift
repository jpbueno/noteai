import Foundation
import GRDB

/// Persists meetings, transcripts, and summaries using SQLite via GRDB.
final class MeetingStore {
    private let dbQueue: DatabaseQueue

    convenience init(namespace: String = AppEnvironment.storageNamespace) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = appSupport.appendingPathComponent(namespace, isDirectory: true)

        do {
            try self.init(directoryURL: directory)
        } catch {
            fatalError("Failed to initialize database: \(error)")
        }
    }

    init(directoryURL: URL) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        dbQueue = try DatabaseQueue(path: directoryURL.appendingPathComponent("meetings.sqlite").path)
        try createTablesIfNeeded()
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

    private func createTablesIfNeeded() throws {
        try dbQueue.write { database in
            try database.execute(sql: """
                CREATE TABLE IF NOT EXISTS meetings (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    date REAL NOT NULL,
                    duration REAL NOT NULL,
                    json_data TEXT NOT NULL
                )
                """)
        }
    }
}
