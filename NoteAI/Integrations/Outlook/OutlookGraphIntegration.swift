import Foundation

struct OutlookMessageSummary: Equatable, Identifiable {
    let id: String
    let conversationID: String?
    let subject: String
    let sender: String
    let sentDate: Date?
    let bodyPreview: String
    let webLink: String?
}

struct OutlookTaskCandidate: Equatable, Identifiable {
    let id: String
    let title: String
    let description: String
    let workDate: Date?
    let sourceMetadata: TaskItem.SourceMetadata

    static func from(message: OutlookMessageSummary) -> OutlookTaskCandidate {
        let title = cleanSubject(message.subject)
        let description = message.bodyPreview
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .clipped(to: 8_000)
        return OutlookTaskCandidate(
            id: message.id,
            title: title.isEmpty ? "Follow up on Outlook conversation" : title,
            description: description,
            workDate: message.sentDate,
            sourceMetadata: TaskItem.SourceMetadata(
                kind: .email,
                provider: "outlook",
                threadID: message.conversationID,
                messageID: message.id,
                subject: message.subject,
                sender: message.sender,
                sentDate: message.sentDate,
                url: message.webLink
            )
        )
    }

    private static func cleanSubject(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"(?i)^\s*(re|fw|fwd):\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct OutlookMailSearchRequest: Equatable {
    var query: String
    var after: Date?
    var before: Date?
    var sender: String?
    var limit: Int

    init(
        query: String,
        after: Date? = nil,
        before: Date? = nil,
        sender: String? = nil,
        limit: Int = 10
    ) {
        self.query = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .clipped(to: 500)
        self.after = after
        self.before = before
        self.sender = sender?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .clipped(to: 320)
        self.limit = min(max(limit, 1), 25)
    }
}

private extension String {
    func clipped(to limit: Int) -> String {
        guard count > limit else { return self }
        return String(prefix(limit))
    }
}
