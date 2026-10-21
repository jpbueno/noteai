import Foundation

enum AITasks {
    static func extractJSON(from text: String) -> String {
        if let start = text.range(of: "```json", options: .caseInsensitive),
           let end = text.range(of: "```", range: start.upperBound..<text.endIndex) {
            return String(text[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let start = text.range(of: "```"),
           let end = text.range(of: "```", range: start.upperBound..<text.endIndex) {
            return String(text[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let start = text.firstIndex(of: "{"),
           let end = text.lastIndex(of: "}") {
            return String(text[start...end])
        }
        return text
    }

    static func parseMeetingSummary(_ text: String) throws -> MeetingSummary {
        let jsonString = extractJSON(from: text)
        guard let jsonData = jsonString.data(using: .utf8) else {
            throw SummarizationError.parseError
        }

        let raw: RawSummary
        do {
            raw = try JSONDecoder().decode(RawSummary.self, from: jsonData)
        } catch {
            throw SummarizationError.parseError
        }
        return MeetingSummary(
            decisions: raw.decisions,
            actionItems: actionItems(from: raw.actionItems),
            topics: raw.topics,
            openQuestions: raw.openQuestions,
            wasSummarized: true
        )
    }

    static func parseMeetingSummarySection(_ text: String, section: MeetingSummarySection) throws -> MeetingSummarySectionContent {
        let jsonString = extractJSON(from: text)
        guard let jsonData = jsonString.data(using: .utf8) else {
            throw SummarizationError.parseError
        }

        switch section {
        case .decisions:
            let raw = try JSONDecoder().decode(RawDecisionsSection.self, from: jsonData)
            return .decisions(raw.decisions)
        case .actionItems:
            let raw = try JSONDecoder().decode(RawActionItemsSection.self, from: jsonData)
            return .actionItems(actionItems(from: raw.actionItems))
        case .topics:
            let raw = try JSONDecoder().decode(RawTopicsSection.self, from: jsonData)
            return .topics(raw.topics)
        case .openQuestions:
            let raw = try JSONDecoder().decode(RawOpenQuestionsSection.self, from: jsonData)
            return .openQuestions(raw.openQuestions)
        }
    }

    static func formatSummaryForPrompt(_ summary: MeetingSummary) -> String {
        var parts: [String] = []
        if !summary.decisions.isEmpty {
            parts.append("Decisions: " + summary.decisions.joined(separator: "; "))
        }
        if !summary.actionItems.isEmpty {
            let items = summary.actionItems.map { item in
                var line = item.task
                if let owner = item.owner { line += " (\(owner))" }
                if let deadline = item.deadline { line += " by \(deadline)" }
                return line
            }
            parts.append("Action Items: " + items.joined(separator: "; "))
        }
        if !summary.topics.isEmpty {
            parts.append("Topics: " + summary.topics.joined(separator: "; "))
        }
        if !summary.openQuestions.isEmpty {
            parts.append("Open Questions: " + summary.openQuestions.joined(separator: "; "))
        }
        return parts.joined(separator: "\n")
    }

    private static func actionItems(from rawItems: [RawActionItem]) -> [ActionItem] {
        var seenIDs = Set<String>()
        var items: [ActionItem] = []

        for raw in rawItems {
            let item = ActionItem(task: raw.task, owner: raw.owner, deadline: raw.deadline)
            guard !seenIDs.contains(item.id) else { continue }
            seenIDs.insert(item.id)
            items.append(item)
        }

        return items
    }
}

private struct RawSummary: Decodable {
    let decisions: [String]
    let actionItems: [RawActionItem]
    let topics: [String]
    let openQuestions: [String]
}

private struct RawDecisionsSection: Decodable {
    let decisions: [String]
}

private struct RawActionItemsSection: Decodable {
    let actionItems: [RawActionItem]
}

private struct RawTopicsSection: Decodable {
    let topics: [String]
}

private struct RawOpenQuestionsSection: Decodable {
    let openQuestions: [String]
}

private struct RawActionItem: Decodable {
    let task: String
    let owner: String?
    let deadline: String?
}
