import Foundation

struct Note: Identifiable, Codable {
    let id: UUID
    var title: String
    var content: String
    var tags: [String]
    let createdDate: Date
    var modifiedDate: Date
    var sourceMeetingID: UUID?

    init(id: UUID = UUID(), title: String = "Untitled", content: String = "", tags: [String] = [], sourceMeetingID: UUID? = nil, createdDate: Date = Date(), modifiedDate: Date = Date()) {
        self.id = id
        self.title = title
        self.content = content
        self.tags = tags
        self.createdDate = createdDate
        self.modifiedDate = modifiedDate
        self.sourceMeetingID = sourceMeetingID
    }

    var formattedCreatedDate: String {
        createdDate.formatted(date: .abbreviated, time: .shortened)
    }

    var formattedModifiedDate: String {
        modifiedDate.formatted(date: .abbreviated, time: .shortened)
    }
}
