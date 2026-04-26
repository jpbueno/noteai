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

        let raw = try JSONDecoder().decode(RawSummary.self, from: jsonData)
        return MeetingSummary(
            decisions: raw.decisions,
            actionItems: raw.actionItems.map {
                ActionItem(task: $0.task, owner: $0.owner, deadline: $0.deadline)
            },
            topics: raw.topics,
            openQuestions: raw.openQuestions,
            wasSummarized: true
        )
    }

    static func parseT5TSections(_ text: String) throws -> T5TSections {
        let jsonString = extractJSON(from: text)
        guard let jsonData = jsonString.data(using: .utf8) else {
            throw SummarizationError.parseError
        }

        let raw = try JSONDecoder().decode(RawT5TSections.self, from: jsonData)
        return T5TSections(
            insights: (raw.insights ?? []).map { T5TEntry(headline: $0.headline, explanation: $0.explanation) },
            accountUpdates: (raw.accountUpdates ?? []).map { T5TEntry(headline: $0.headline, explanation: $0.explanation) },
            futurePlans: (raw.futurePlans ?? []).map { T5TEntry(headline: $0.headline, explanation: $0.explanation) }
        )
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
}

private struct RawSummary: Decodable {
    let decisions: [String]
    let actionItems: [RawActionItem]
    let topics: [String]
    let openQuestions: [String]
}

private struct RawActionItem: Decodable {
    let task: String
    let owner: String?
    let deadline: String?
}

private struct RawT5TSections: Decodable {
    let insights: [RawT5TEntry]?
    let accountUpdates: [RawT5TEntry]?
    let futurePlans: [RawT5TEntry]?
}

private struct RawT5TEntry: Decodable {
    let headline: String
    let explanation: String
}

