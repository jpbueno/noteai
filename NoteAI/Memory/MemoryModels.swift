import Foundation

enum EvidenceSourceKind: String, Codable, Equatable {
    case teamsTranscriptPaste
    case outlookEmail
    case slackMessage
    case googleDriveDocument
    case noteAIRecord
    case codeActivity
}

struct EvidenceSource: Identifiable, Codable, Equatable {
    var id: UUID
    var kind: EvidenceSourceKind
    var title: String
    var externalID: String?
    var capturedAt: Date

    init(
        id: UUID = UUID(),
        kind: EvidenceSourceKind,
        title: String,
        externalID: String?,
        capturedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.externalID = externalID
        self.capturedAt = capturedAt
    }
}

