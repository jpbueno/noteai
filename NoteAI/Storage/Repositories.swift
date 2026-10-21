import Foundation

protocol MeetingRepository {
    func save(meeting: Meeting) throws
    func fetchAllMeetings() throws -> [Meeting]
    func fetch(meetingId: UUID) throws -> Meeting?
    func delete(meetingId: UUID) throws
}

extension MeetingStore: MeetingRepository {
    func fetchAllMeetings() throws -> [Meeting] {
        try fetchAll()
    }
}
