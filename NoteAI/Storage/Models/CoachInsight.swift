import Foundation

enum CoachInsightType: String, Codable, CaseIterable, Sendable {
    case keyInsight = "key_insight"
    case talkingPoint = "talking_point"
    case technicalAnswer = "technical_answer"
    case actionItem = "action_item"
    case followUp = "follow_up"

    var label: String {
        switch self {
        case .keyInsight: return "Insight"
        case .talkingPoint: return "Talking Point"
        case .technicalAnswer: return "Technical"
        case .actionItem: return "Action Item"
        case .followUp: return "Follow Up"
        }
    }

    var systemImage: String {
        switch self {
        case .keyInsight: return "lightbulb.fill"
        case .talkingPoint: return "bubble.left.fill"
        case .technicalAnswer: return "chevron.left.forwardslash.chevron.right"
        case .actionItem: return "checkmark.circle.fill"
        case .followUp: return "clock.fill"
        }
    }
}

/// A "role" for a coach-stream entry. When nil, the entry is an auto-generated
/// insight; otherwise it's a chat message from the user or SA. Mirrors the
/// web `CoachInsight.role` field.
enum CoachRole: String, Codable, Sendable {
    case user
    case assistant
}

enum CoachInsightBasis: String, Codable, Sendable {
    case transcript
    case domainKnowledge = "domain_knowledge"
    case recommendation
}

enum CoachInsightPriority: String, Codable, CaseIterable, Comparable, Sendable {
    case low
    case medium
    case high
    case critical

    private var rank: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        case .critical: return 3
        }
    }

    static func < (lhs: CoachInsightPriority, rhs: CoachInsightPriority) -> Bool {
        lhs.rank < rhs.rank
    }
}

enum CoachInsightLifecycle: String, Codable, Sendable {
    case active
    case dismissed
    case resolved
    case expired
}

struct CoachEvidenceReference: Codable, Equatable, Sendable {
    let segmentID: Int
    let startTime: Float
    let endTime: Float
}

struct CoachInsight: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let timestamp: Date
    let type: CoachInsightType
    let content: String
    var role: CoachRole?
    let sessionID: UUID?
    let basis: CoachInsightBasis?
    let evidence: [CoachEvidenceReference]
    let topic: String?
    let priority: CoachInsightPriority
    var lifecycle: CoachInsightLifecycle

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        type: CoachInsightType,
        content: String,
        role: CoachRole? = nil,
        sessionID: UUID? = nil,
        basis: CoachInsightBasis? = nil,
        evidence: [CoachEvidenceReference] = [],
        topic: String? = nil,
        priority: CoachInsightPriority = .medium,
        lifecycle: CoachInsightLifecycle = .active
    ) {
        self.id = id
        self.timestamp = timestamp
        self.type = type
        self.content = content
        self.role = role
        self.sessionID = sessionID
        self.basis = basis
        self.evidence = evidence
        self.topic = topic
        self.priority = priority
        self.lifecycle = lifecycle
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case timestamp
        case type
        case content
        case role
        case sessionID
        case basis
        case evidence
        case topic
        case priority
        case lifecycle
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        type = try container.decode(CoachInsightType.self, forKey: .type)
        content = try container.decode(String.self, forKey: .content)
        role = try container.decodeIfPresent(CoachRole.self, forKey: .role)
        sessionID = try container.decodeIfPresent(UUID.self, forKey: .sessionID)
        basis = try container.decodeIfPresent(CoachInsightBasis.self, forKey: .basis)
        evidence = try container.decodeIfPresent([CoachEvidenceReference].self, forKey: .evidence) ?? []
        topic = try container.decodeIfPresent(String.self, forKey: .topic)
        priority = try container.decodeIfPresent(CoachInsightPriority.self, forKey: .priority) ?? .medium
        lifecycle = try container.decodeIfPresent(CoachInsightLifecycle.self, forKey: .lifecycle) ?? .active
    }
}
