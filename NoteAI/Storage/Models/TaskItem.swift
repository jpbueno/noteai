import Foundation

struct TaskItem: Identifiable, Codable {
    let id: UUID
    var title: String
    var description: String
    var rawInput: String
    var tags: [String]
    var status: Status
    let createdDate: Date
    var modifiedDate: Date
    var sourceMeetingID: UUID?
    var sourceNoteID: UUID?

    enum Status: String, Codable {
        case pending
        case completed
    }

    init(id: UUID = UUID(), title: String = "", description: String = "", rawInput: String = "", tags: [String] = [], status: Status = .pending, sourceMeetingID: UUID? = nil, sourceNoteID: UUID? = nil) {
        self.id = id
        self.title = title
        self.description = description
        self.rawInput = rawInput
        self.tags = tags
        self.status = status
        self.createdDate = Date()
        self.modifiedDate = Date()
        self.sourceMeetingID = sourceMeetingID
        self.sourceNoteID = sourceNoteID
    }

    var formattedDate: String {
        createdDate.formatted(date: .abbreviated, time: .shortened)
    }
}
