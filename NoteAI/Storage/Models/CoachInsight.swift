import Foundation

enum CoachInsightType: String, Codable, CaseIterable {
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
enum CoachRole: String, Codable {
    case user
    case assistant
}

struct CoachInsight: Identifiable, Codable, Equatable {
    let id: UUID
    let timestamp: Date
    let type: CoachInsightType
    let content: String
    var role: CoachRole?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        type: CoachInsightType,
        content: String,
        role: CoachRole? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.type = type
        self.content = content
        self.role = role
    }
}
