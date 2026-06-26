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

enum MemoryCandidateKind: String, Codable, Equatable {
    case personal
    case project
    case customer
    case person
    case writingStyle
    case decision
    case skill
}

enum MemoryCandidateStatus: String, Codable, Equatable {
    case proposed
    case accepted
    case rejected
    case stale
}

struct MemoryCandidate: Identifiable, Codable, Equatable {
    var id: UUID
    var kind: MemoryCandidateKind
    var summary: String
    var evidence: [EvidenceSource]
    var confidence: Double
    var status: MemoryCandidateStatus
    var createdAt: Date

    init(
        id: UUID = UUID(),
        kind: MemoryCandidateKind,
        summary: String,
        evidence: [EvidenceSource],
        confidence: Double,
        status: MemoryCandidateStatus = .proposed,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.summary = summary
        self.evidence = evidence
        self.confidence = confidence
        self.status = status
        self.createdAt = createdAt
    }
}

protocol SourceAdapter {
    var sourceKind: EvidenceSourceKind { get }
}

