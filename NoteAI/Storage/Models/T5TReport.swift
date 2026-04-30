import Foundation

struct T5TReport: Identifiable, Codable {
    let id: UUID
    var title: String
    let createdDate: Date
    var periodStart: Date
    var periodEnd: Date
    var meetingIDs: [UUID]
    var noteIDs: [UUID] = []
    var todoIDs: [UUID] = []
    var sections: T5TSections
    var status: Status

    enum Status: String, Codable {
        case draft
        case finalized
    }

    // Make optional source fields decode-safe for reports saved before they existed.
    enum CodingKeys: String, CodingKey {
        case id, title, createdDate, periodStart, periodEnd
        case meetingIDs, noteIDs, todoIDs
        case sections, status
    }

    init(
        id: UUID,
        title: String,
        createdDate: Date,
        periodStart: Date,
        periodEnd: Date,
        meetingIDs: [UUID],
        noteIDs: [UUID] = [],
        todoIDs: [UUID] = [],
        sections: T5TSections,
        status: Status
    ) {
        self.id = id
        self.title = title
        self.createdDate = createdDate
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.meetingIDs = meetingIDs
        self.noteIDs = noteIDs
        self.todoIDs = todoIDs
        self.sections = sections
        self.status = status
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        createdDate = try c.decode(Date.self, forKey: .createdDate)
        periodStart = try c.decode(Date.self, forKey: .periodStart)
        periodEnd = try c.decode(Date.self, forKey: .periodEnd)
        meetingIDs = try c.decode([UUID].self, forKey: .meetingIDs)
        noteIDs = (try? c.decode([UUID].self, forKey: .noteIDs)) ?? []
        todoIDs = (try? c.decode([UUID].self, forKey: .todoIDs)) ?? []
        sections = try c.decode(T5TSections.self, forKey: .sections)
        status = try c.decode(Status.self, forKey: .status)
    }

    var periodLabel: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"
        return "\(fmt.string(from: periodStart))–\(fmt.string(from: periodEnd))"
    }

    var emailBody: String {
        var parts: [String] = []

        if !sections.insights.isEmpty {
            parts.append("Insights, Management Escalations & Help Needed, Market & Competition")
            for entry in sections.insights {
                parts.append("• \(entry.headline)\n  \(entry.explanation)")
            }
        }

        if !sections.accountUpdates.isEmpty {
            parts.append("\nIndustry Business Development / Account Updates")
            for entry in sections.accountUpdates {
                parts.append("• \(entry.headline)\n  \(entry.explanation)")
            }
        }

        if !sections.futurePlans.isEmpty {
            parts.append("\nFuture Plans")
            for entry in sections.futurePlans {
                parts.append("• \(entry.headline)\n  \(entry.explanation)")
            }
        }

        return parts.joined(separator: "\n")
    }
}

struct T5TSections: Codable, Equatable {
    var insights: [T5TEntry]
    var accountUpdates: [T5TEntry]
    var futurePlans: [T5TEntry]

    var isEmpty: Bool {
        insights.isEmpty && accountUpdates.isEmpty && futurePlans.isEmpty
    }

    static let empty = T5TSections(insights: [], accountUpdates: [], futurePlans: [])
}

struct T5TEntry: Identifiable, Codable, Equatable {
    let id: UUID
    var headline: String
    var explanation: String

    init(id: UUID = UUID(), headline: String, explanation: String) {
        self.id = id
        self.headline = headline
        self.explanation = explanation
    }
}

struct T5TConfig: Codable, Equatable {
    var vertical: String
    var region: String
    var jobFunction: String
    var subjectLine: String

    var isComplete: Bool {
        !vertical.isEmpty && !region.isEmpty && !jobFunction.isEmpty
    }

    static let empty = T5TConfig(vertical: "", region: "", jobFunction: "", subjectLine: "")
}
