import Foundation

struct Meeting: Identifiable, Codable {
    let id: UUID
    var title: String
    let date: Date
    let duration: TimeInterval
    var transcript: [TranscriptSegment]
    var summary: MeetingSummary

    var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        if minutes >= 60 {
            let hours = minutes / 60
            let mins = minutes % 60
            return "\(hours)h \(mins)m"
        }
        return "\(minutes)m \(seconds)s"
    }
}

struct TranscriptSegment: Identifiable, Codable {
    let id: Int
    let text: String
    let startTime: Float
    let endTime: Float
    let speaker: String?
    let confidence: Float

    init(id: Int = 0, text: String, startTime: Float = 0, endTime: Float = 0, speaker: String? = nil, confidence: Float = 0) {
        self.id = id
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.speaker = speaker
        self.confidence = confidence
    }

    var formattedTimestamp: String {
        let totalSeconds = Int(startTime)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var timestamp: TimeInterval { Double(startTime) }
}

struct MeetingSummary: Codable {
    var decisions: [String]
    var actionItems: [ActionItem]
    var topics: [String]
    var openQuestions: [String]
    var wasSummarized: Bool

    init(decisions: [String] = [], actionItems: [ActionItem] = [], topics: [String] = [], openQuestions: [String] = [], wasSummarized: Bool = false) {
        self.decisions = decisions
        self.actionItems = actionItems
        self.topics = topics
        self.openQuestions = openQuestions
        self.wasSummarized = wasSummarized
    }

    var isEmpty: Bool {
        decisions.isEmpty && actionItems.isEmpty && topics.isEmpty && openQuestions.isEmpty
    }
}

struct ActionItem: Identifiable, Codable {
    let id: String
    let task: String
    let owner: String?
    let deadline: String?
    var isCompleted: Bool

    init(id: String = UUID().uuidString, task: String, owner: String? = nil, deadline: String? = nil, isCompleted: Bool = false) {
        self.id = id
        self.task = task
        self.owner = owner
        self.deadline = deadline
        self.isCompleted = isCompleted
    }
}

enum MeetingTemplate: String, CaseIterable, Identifiable, Codable {
    case auto
    case general
    case standup
    case sales
    case oneOnOne
    case brainstorm

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Auto-Detect"
        case .general: return "General Meeting"
        case .standup: return "Stand-up"
        case .sales: return "Sales / Customer Call"
        case .oneOnOne: return "1:1"
        case .brainstorm: return "Brainstorm"
        }
    }

    var icon: String {
        switch self {
        case .auto: return "sparkles"
        case .general: return "person.3"
        case .standup: return "figure.stand"
        case .sales: return "chart.line.uptrend.xyaxis"
        case .oneOnOne: return "person.2"
        case .brainstorm: return "lightbulb"
        }
    }

    var promptInstruction: String {
        switch self {
        case .auto: return "Detect the meeting type and adapt your output format accordingly."
        case .general: return "Format as a standard meeting summary with decisions, action items, topics discussed, and open questions."
        case .standup: return "Format as a stand-up summary: what each person completed, what they're working on next, and any blockers."
        case .sales: return "Format as a sales call summary: customer pain points, objections raised, commitments made, and deal signals."
        case .oneOnOne: return "Format as a 1:1 summary: feedback shared, career development topics, and personal action items."
        case .brainstorm: return "Format as a brainstorm summary: all ideas proposed, directions chosen, and research tasks assigned."
        }
    }

    var jsonStructure: String {
        """
        {"decisions": ["..."], "actionItems": [{"task": "...", "owner": "...", "deadline": "..."}], "topics": ["..."], "openQuestions": ["..."]}
        """
    }
}
