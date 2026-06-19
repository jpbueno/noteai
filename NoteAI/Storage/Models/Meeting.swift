import Foundation

struct Meeting: Identifiable, Codable {
    let id: UUID
    var title: String
    let date: Date
    let duration: TimeInterval
    var transcript: [TranscriptSegment]
    var summary: MeetingSummary
    var speakerLabels: [String: String]
    var speakerProfiles: [String: SpeakerProfile]

    init(
        id: UUID,
        title: String,
        date: Date,
        duration: TimeInterval,
        transcript: [TranscriptSegment],
        summary: MeetingSummary,
        speakerLabels: [String: String] = [:],
        speakerProfiles: [String: SpeakerProfile] = [:]
    ) {
        self.id = id
        self.title = title
        self.date = date
        self.duration = duration
        self.transcript = transcript
        self.summary = summary
        self.speakerLabels = TranscriptSpeakerLabels.normalizedLabels(speakerLabels)
        self.speakerProfiles = TranscriptSpeakerLabels.normalizedProfiles(speakerProfiles)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case date
        case duration
        case transcript
        case summary
        case speakerLabels
        case speakerProfiles
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        date = try container.decode(Date.self, forKey: .date)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        transcript = try container.decodeIfPresent([TranscriptSegment].self, forKey: .transcript) ?? []
        summary = try container.decode(MeetingSummary.self, forKey: .summary)
        speakerLabels = TranscriptSpeakerLabels.normalizedLabels(
            try container.decodeIfPresent([String: String].self, forKey: .speakerLabels) ?? [:]
        )
        speakerProfiles = TranscriptSpeakerLabels.normalizedProfiles(
            try container.decodeIfPresent([String: SpeakerProfile].self, forKey: .speakerProfiles) ?? [:]
        )
    }

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

    func speakerID(for segment: TranscriptSegment) -> String {
        TranscriptSpeakerLabels.speakerID(for: segment)
    }

    func speakerDisplayName(for segment: TranscriptSegment) -> String {
        let id = speakerID(for: segment)
        return TranscriptSpeakerLabels.displayName(for: id, labels: speakerLabels, profiles: speakerProfiles)
    }

    mutating func setSpeakerLabel(speakerID: String, displayName: String) {
        speakerLabels = TranscriptSpeakerLabels.settingLabel(
            displayName,
            for: speakerID,
            in: speakerLabels
        )
        let id = TranscriptSpeakerLabels.normalizedSpeakerID(speakerID) ?? TranscriptSpeakerLabels.fallbackSpeakerID
        if let label = TranscriptSpeakerLabels.normalizedLabel(displayName) {
            speakerProfiles[id] = TranscriptSpeakerLabels.profile(
                speakerProfiles[id] ?? SpeakerProfile(speakerID: id),
                settingName: label
            )
        } else if let existing = speakerProfiles[id] {
            speakerProfiles[id] = TranscriptSpeakerLabels.profile(existing, settingName: nil)
        }
        speakerProfiles = TranscriptSpeakerLabels.normalizedProfiles(speakerProfiles)
    }

    mutating func setSpeakerProfile(_ profile: SpeakerProfile) {
        speakerProfiles = TranscriptSpeakerLabels.settingProfile(profile, in: speakerProfiles)
        if let id = TranscriptSpeakerLabels.normalizedSpeakerID(profile.speakerID) {
            speakerLabels = TranscriptSpeakerLabels.settingLabel(
                profile.name ?? "",
                for: id,
                in: speakerLabels
            )
        }
    }

    func speakerProfile(for speakerID: String) -> SpeakerProfile {
        let id = TranscriptSpeakerLabels.normalizedSpeakerID(speakerID) ?? TranscriptSpeakerLabels.fallbackSpeakerID
        return speakerProfiles[id] ?? SpeakerProfile(speakerID: id, name: speakerLabels[id])
    }
}

struct SpeakerProfile: Identifiable, Codable, Equatable {
    var id: String { speakerID }
    let speakerID: String
    var name: String?
    var role: String?
    var company: String?
    var notes: String?

    init(
        speakerID: String,
        name: String? = nil,
        role: String? = nil,
        company: String? = nil,
        notes: String? = nil
    ) {
        self.speakerID = TranscriptSpeakerLabels.normalizedSpeakerID(speakerID) ?? TranscriptSpeakerLabels.fallbackSpeakerID
        self.name = TranscriptSpeakerLabels.normalizedLabel(name)
        self.role = TranscriptSpeakerLabels.normalizedLabel(role)
        self.company = TranscriptSpeakerLabels.normalizedLabel(company)
        self.notes = TranscriptSpeakerLabels.normalizedLabel(notes)
    }

    var hasUserMetadata: Bool {
        name != nil || role != nil || company != nil || notes != nil
    }

    func displayName(defaultName: String) -> String {
        name ?? defaultName
    }

    func summaryLine(defaultName: String) -> String? {
        guard hasUserMetadata else { return nil }
        let displayName = displayName(defaultName: defaultName)
        let affiliation = [role, company]
            .compactMap { $0 }
            .joined(separator: ", ")
        let suffix = [affiliation, notes]
            .compactMap { value -> String? in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: ". ")

        if suffix.isEmpty {
            return displayName
        }
        return "\(displayName) — \(suffix)."
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

    func withSpeaker(_ speaker: String) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            text: text,
            startTime: startTime,
            endTime: endTime,
            speaker: speaker,
            confidence: confidence
        )
    }
}

enum TranscriptSpeakerLabels {
    static let fallbackSpeakerID = "speaker-1"
    static let localSpeakerID = "speaker-local"
    static let remoteSpeakerID = "speaker-remote"

    static func assignPlaceholders(
        to transcript: [TranscriptSegment],
        fallbackSpeakerID: String = fallbackSpeakerID
    ) -> [TranscriptSegment] {
        transcript.map { segment in
            let id = speakerID(for: segment, fallbackSpeakerID: fallbackSpeakerID)
            return segment.speaker == id ? segment : segment.withSpeaker(id)
        }
    }

    static func speakerID(
        for segment: TranscriptSegment,
        fallbackSpeakerID: String = fallbackSpeakerID
    ) -> String {
        normalizedSpeakerID(segment.speaker)
            ?? normalizedSpeakerID(fallbackSpeakerID)
            ?? Self.fallbackSpeakerID
    }

    static func displayName(for speakerID: String, labels: [String: String]) -> String {
        let id = normalizedSpeakerID(speakerID) ?? fallbackSpeakerID
        if let override = normalizedLabel(labels[id]) {
            return override
        }
        return defaultDisplayName(for: id)
    }

    static func displayName(
        for speakerID: String,
        labels: [String: String],
        profiles: [String: SpeakerProfile]
    ) -> String {
        let id = normalizedSpeakerID(speakerID) ?? fallbackSpeakerID
        let defaultName = displayName(for: id, labels: labels)
        return profiles[id]?.displayName(defaultName: defaultName) ?? defaultName
    }

    static func normalizedLabels(_ labels: [String: String]) -> [String: String] {
        labels.reduce(into: [:]) { result, entry in
            guard let id = normalizedSpeakerID(entry.key),
                  let label = normalizedLabel(entry.value) else { return }
            result[id] = label
        }
    }

    static func settingLabel(_ displayName: String, for speakerID: String, in labels: [String: String]) -> [String: String] {
        guard let id = normalizedSpeakerID(speakerID) else { return normalizedLabels(labels) }
        var next = normalizedLabels(labels)
        if let label = normalizedLabel(displayName) {
            next[id] = label
        } else {
            next.removeValue(forKey: id)
        }
        return next
    }

    static func normalizedProfiles(_ profiles: [String: SpeakerProfile]) -> [String: SpeakerProfile] {
        profiles.reduce(into: [:]) { result, entry in
            let candidateID = normalizedSpeakerID(entry.value.speakerID) ?? normalizedSpeakerID(entry.key)
            guard let id = candidateID else { return }
            let profile = SpeakerProfile(
                speakerID: id,
                name: entry.value.name,
                role: entry.value.role,
                company: entry.value.company,
                notes: entry.value.notes
            )
            if profile.hasUserMetadata {
                result[id] = profile
            }
        }
    }

    static func settingProfile(_ profile: SpeakerProfile, in profiles: [String: SpeakerProfile]) -> [String: SpeakerProfile] {
        guard let id = normalizedSpeakerID(profile.speakerID) else { return normalizedProfiles(profiles) }
        var next = normalizedProfiles(profiles)
        let normalized = SpeakerProfile(
            speakerID: id,
            name: profile.name,
            role: profile.role,
            company: profile.company,
            notes: profile.notes
        )
        if normalized.hasUserMetadata {
            next[id] = normalized
        } else {
            next.removeValue(forKey: id)
        }
        return next
    }

    static func profile(_ profile: SpeakerProfile, settingName name: String?) -> SpeakerProfile {
        SpeakerProfile(
            speakerID: profile.speakerID,
            name: name,
            role: profile.role,
            company: profile.company,
            notes: profile.notes
        )
    }

    static func untaggedSpeakerIDs(
        in transcript: [TranscriptSegment],
        labels: [String: String] = [:],
        profiles: [String: SpeakerProfile],
        deferredSpeakerIDs: Set<String>
    ) -> [String] {
        var seen = Set<String>()
        var ids: [String] = []

        for segment in transcript {
            let id = speakerID(for: segment)
            guard id.lowercased() != "system",
                  !deferredSpeakerIDs.contains(id),
                  !seen.contains(id),
                  !isTagged(speakerID: id, labels: labels, profiles: profiles) else {
                continue
            }
            seen.insert(id)
            ids.append(id)
        }

        return ids
    }

    static func isTagged(speakerID: String, labels: [String: String], profiles: [String: SpeakerProfile]) -> Bool {
        let id = normalizedSpeakerID(speakerID) ?? fallbackSpeakerID
        if profiles[id]?.hasUserMetadata == true {
            return true
        }
        return normalizedLabel(labels[id]) != nil
    }

    static func normalizedSpeakerID(_ speaker: String?) -> String? {
        guard let speaker else { return nil }
        let trimmed = speaker.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func normalizedLabel(_ label: String?) -> String? {
        guard let label else { return nil }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func defaultDisplayName(for speakerID: String) -> String {
        let lowercased = speakerID.lowercased()
        switch lowercased {
        case localSpeakerID:
            return "You"
        case remoteSpeakerID:
            return "Remote audio"
        default:
            break
        }

        if lowercased.hasPrefix("\(remoteSpeakerID)-"),
           let number = Int(lowercased.dropFirst("\(remoteSpeakerID)-".count)) {
            return "Remote speaker \(number)"
        }

        if lowercased.hasPrefix("speaker-"),
           let number = Int(lowercased.dropFirst("speaker-".count)) {
            return "Speaker \(number)"
        }
        return speakerID
    }
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
