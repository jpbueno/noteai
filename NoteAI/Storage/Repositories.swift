import Foundation

protocol MeetingRepository {
    func save(meeting: Meeting) throws
    func fetchAllMeetings() throws -> [Meeting]
    func fetch(meetingId: UUID) throws -> Meeting?
    func delete(meetingId: UUID) throws
}

protocol NoteRepository {
    func saveNote(_ note: Note) throws
    func fetchAllNotes() throws -> [Note]
    func deleteNote(id: UUID) throws
}

protocol TaskRepository {
    func saveTask(_ task: TaskItem) throws
    func fetchAllTasks() throws -> [TaskItem]
    func deleteTask(id: UUID) throws
}

protocol T5TRepository {
    func saveT5TReport(_ report: T5TReport) throws
    func fetchAllT5TReports() throws -> [T5TReport]
    func deleteT5TReport(id: UUID) throws
    func saveT5TConfig(_ config: T5TConfig) throws
    func loadT5TConfig() throws -> T5TConfig?
}

extension MeetingStore: MeetingRepository, NoteRepository, TaskRepository, T5TRepository {
    func fetchAllMeetings() throws -> [Meeting] {
        try fetchAll()
    }
}

