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
    var sectionMetadata: [String: SummarySectionEditMetadata]

    init(
        decisions: [String] = [],
        actionItems: [ActionItem] = [],
        topics: [String] = [],
        openQuestions: [String] = [],
        wasSummarized: Bool = false,
        sectionMetadata: [String: SummarySectionEditMetadata]? = nil
    ) {
        self.decisions = decisions
        self.actionItems = actionItems
        self.topics = topics
        self.openQuestions = openQuestions
        self.wasSummarized = wasSummarized
        self.sectionMetadata = Self.normalizedSectionMetadata(
            sectionMetadata,
            defaultModifiedAt: Date()
        )
    }

    enum CodingKeys: String, CodingKey {
        case decisions
        case actionItems
        case topics
        case openQuestions
        case wasSummarized
        case sectionMetadata
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        decisions = try container.decodeIfPresent([String].self, forKey: .decisions) ?? []
        actionItems = try container.decodeIfPresent([ActionItem].self, forKey: .actionItems) ?? []
        topics = try container.decodeIfPresent([String].self, forKey: .topics) ?? []
        openQuestions = try container.decodeIfPresent([String].self, forKey: .openQuestions) ?? []
        wasSummarized = try container.decodeIfPresent(Bool.self, forKey: .wasSummarized) ?? false
        let decodedMetadata = try container.decodeIfPresent(
            [String: SummarySectionEditMetadata].self,
            forKey: .sectionMetadata
        )
        sectionMetadata = Self.normalizedSectionMetadata(
            decodedMetadata,
            defaultModifiedAt: Date(timeIntervalSince1970: 0)
        )
    }

    func metadata(for section: MeetingSummarySection) -> SummarySectionEditMetadata {
        sectionMetadata[section.rawValue] ?? SummarySectionEditMetadata(
            state: .generated,
            modifiedAt: Date(timeIntervalSince1970: 0)
        )
    }

    mutating func mark(_ section: MeetingSummarySection, state: SummarySectionEditState, modifiedAt: Date = Date()) {
        sectionMetadata[section.rawValue] = SummarySectionEditMetadata(state: state, modifiedAt: modifiedAt)
    }

    mutating func replace(
        _ section: MeetingSummarySection,
        with content: MeetingSummarySectionContent,
        state: SummarySectionEditState,
        modifiedAt: Date = Date()
    ) {
        switch (section, content) {
        case (.decisions, .decisions(let values)):
            decisions = values
        case (.actionItems, .actionItems(let values)):
            actionItems = values
        case (.topics, .topics(let values)):
            topics = values
        case (.openQuestions, .openQuestions(let values)):
            openQuestions = values
        default:
            return
        }
        wasSummarized = true
        mark(section, state: state, modifiedAt: modifiedAt)
    }

    var isEmpty: Bool {
        decisions.isEmpty && actionItems.isEmpty && topics.isEmpty && openQuestions.isEmpty
    }

    private static func normalizedSectionMetadata(
        _ metadata: [String: SummarySectionEditMetadata]?,
        defaultModifiedAt: Date
    ) -> [String: SummarySectionEditMetadata] {
        var normalized = metadata ?? [:]
        for section in MeetingSummarySection.allCases where normalized[section.rawValue] == nil {
            normalized[section.rawValue] = SummarySectionEditMetadata(
                state: .generated,
                modifiedAt: defaultModifiedAt
            )
        }
        return normalized
    }
}

enum MeetingSummarySection: String, CaseIterable, Identifiable, Codable {
    case decisions
    case actionItems
    case topics
    case openQuestions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .decisions: return "Key Decisions"
        case .actionItems: return "Action Items"
        case .topics: return "Topics Discussed"
        case .openQuestions: return "Open Questions"
        }
    }

    var jsonStructure: String {
        switch self {
        case .decisions:
            return #"{"decisions":["..."]}"#
        case .actionItems:
            return #"{"actionItems":[{"task":"...","owner":"...","deadline":"..."}]}"#
        case .topics:
            return #"{"topics":["..."]}"#
        case .openQuestions:
            return #"{"openQuestions":["..."]}"#
        }
    }
}

enum SummarySectionEditState: String, Codable {
    case generated
    case userEdited
}

struct SummarySectionEditMetadata: Codable, Equatable {
    var state: SummarySectionEditState
    var modifiedAt: Date
}

enum MeetingSummarySectionContent {
    case decisions([String])
    case actionItems([ActionItem])
    case topics([String])
    case openQuestions([String])
}

struct ActionItem: Identifiable, Codable, Equatable {
    let id: String
    var task: String
    var owner: String?
    var deadline: String?
    var isCompleted: Bool

    init(id: String? = nil, task: String, owner: String? = nil, deadline: String? = nil, isCompleted: Bool = false) {
        let trimmedID = id?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = trimmedID?.isEmpty == false
            ? trimmedID!
            : Self.stableID(task: task, owner: owner, deadline: deadline)
        self.task = task
        self.owner = Self.trimmedOptional(owner)
        self.deadline = Self.trimmedOptional(deadline)
        self.isCompleted = isCompleted
    }

    enum CodingKeys: String, CodingKey {
        case id
        case task
        case owner
        case deadline
        case isCompleted
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let task = try container.decodeIfPresent(String.self, forKey: .task) ?? ""
        let owner = Self.trimmedOptional(try container.decodeIfPresent(String.self, forKey: .owner))
        let deadline = Self.trimmedOptional(try container.decodeIfPresent(String.self, forKey: .deadline))
        let decodedID = Self.trimmedOptional(try container.decodeIfPresent(String.self, forKey: .id))

        if let decodedID, UUID(uuidString: decodedID) == nil {
            id = decodedID
        } else {
            id = Self.stableID(task: task, owner: owner, deadline: deadline)
        }
        self.task = task
        self.owner = owner
        self.deadline = deadline
        isCompleted = try container.decodeIfPresent(Bool.self, forKey: .isCompleted) ?? false
    }

    static func stableID(task: String, owner: String? = nil, deadline: String? = nil) -> String {
        let taskKey = normalizedField(task)
        let ownerKey = normalizedField(owner)
        let deadlineKey = normalizedField(deadline)
        return "action:\(taskKey.isEmpty ? "untitled" : taskKey)|owner:\(ownerKey)|deadline:\(deadlineKey)"
    }

    private static func normalizedField(_ value: String?) -> String {
        guard let value else { return "" }
        return value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func trimmedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
