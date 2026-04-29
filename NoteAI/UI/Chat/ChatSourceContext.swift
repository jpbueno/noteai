import Foundation

enum ChatSourceKind: String {
    case meeting
    case note
    case t5t
}

struct ChatSourceLink: Equatable {
    let kind: ChatSourceKind
    let id: UUID

    init?(urlString: String) {
        guard let url = URL(string: urlString),
              url.scheme == "noteai",
              let host = url.host(),
              let kind = ChatSourceKind(rawValue: host)
        else {
            return nil
        }

        let pathID = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let id = UUID(uuidString: pathID) else { return nil }

        self.kind = kind
        self.id = id
    }
}

enum ChatSourceContext {
    private static let maxTextCharacters = 360
    private static let defaultMaxPerType = 6

    static func build(
        meetings: [Meeting],
        notes: [Note],
        t5tReports: [T5TReport],
        maxPerType: Int = defaultMaxPerType
    ) -> String {
        var entries: [SourceEntry] = []
        entries += meetings.prefix(maxPerType).enumerated().map { meetingEntry($0.element, index: $0.offset + 1) }
        entries += notes.prefix(maxPerType).enumerated().map { noteEntry($0.element, index: $0.offset + 1) }
        entries += t5tReports.prefix(maxPerType).enumerated().map { t5tEntry($0.element, index: $0.offset + 1) }

        let sourceBlock = entries.isEmpty
            ? "No NoteAI workspace sources are currently available."
            : entries.map(formatEntry).joined(separator: "\n")

        return """
        You are NoteAI, an intelligent meeting assistant. Use the NoteAI workspace sources below when answering questions about meetings, notes, or T5T reports.

        Rules:
        - If you use a source, cite it with a markdown link using the provided label and noteai:// URL, for example [M1: Roadmap Sync](noteai://meeting/11111111-1111-1111-1111-111111111111).
        - Prefer directly supported answers. If the sources below do not support the answer, say you do not have enough NoteAI source material.
        - Keep answers concise and do not invent meetings, owners, dates, or commitments.

        NoteAI workspace sources:
        \(sourceBlock)
        """
    }

    private struct SourceEntry {
        let prefix: String
        let kind: ChatSourceKind
        let title: String
        let id: UUID
        let text: String
    }

    private static func meetingEntry(_ meeting: Meeting, index: Int) -> SourceEntry {
        let summary = meeting.summary
        let parts = [
            summary.decisions.isEmpty ? "" : "Decisions: \(summary.decisions.joined(separator: "; "))",
            summary.actionItems.isEmpty ? "" : "Actions: \(summary.actionItems.map(\.task).joined(separator: "; "))",
            summary.topics.isEmpty ? "" : "Topics: \(summary.topics.joined(separator: ", "))",
            summary.openQuestions.isEmpty ? "" : "Questions: \(summary.openQuestions.joined(separator: "; "))",
            meeting.transcript.isEmpty ? "" : "Transcript: \(meeting.transcript.map(\.text).joined(separator: " "))"
        ]

        return SourceEntry(
            prefix: "M\(index)",
            kind: .meeting,
            title: meeting.title.isEmpty ? "Untitled meeting" : meeting.title,
            id: meeting.id,
            text: truncate(parts.filter { !$0.isEmpty }.joined(separator: " "))
        )
    }

    private static func noteEntry(_ note: Note, index: Int) -> SourceEntry {
        SourceEntry(
            prefix: "N\(index)",
            kind: .note,
            title: note.title.isEmpty ? "Untitled note" : note.title,
            id: note.id,
            text: truncate(note.content)
        )
    }

    private static func t5tEntry(_ report: T5TReport, index: Int) -> SourceEntry {
        let sectionText = [
            report.sections.insights.map { "Insight: \($0.headline). \($0.explanation)" },
            report.sections.accountUpdates.map { "Account update: \($0.headline). \($0.explanation)" },
            report.sections.futurePlans.map { "Future plan: \($0.headline). \($0.explanation)" }
        ]
        .flatMap { $0 }
        .joined(separator: " ")

        return SourceEntry(
            prefix: "R\(index)",
            kind: .t5t,
            title: report.title.isEmpty ? "Untitled T5T" : report.title,
            id: report.id,
            text: truncate(sectionText)
        )
    }

    private static func formatEntry(_ entry: SourceEntry) -> String {
        "- [\(entry.prefix)] \(kindLabel(entry.kind)): \(entry.title) (\(sourceURL(kind: entry.kind, id: entry.id))) - \(entry.text.isEmpty ? "No excerpt available." : entry.text)"
    }

    private static func kindLabel(_ kind: ChatSourceKind) -> String {
        switch kind {
        case .meeting: return "Meeting"
        case .note: return "Note"
        case .t5t: return "T5T"
        }
    }

    private static func sourceURL(kind: ChatSourceKind, id: UUID) -> String {
        "noteai://\(kind.rawValue)/\(id.uuidString)"
    }

    private static func truncate(_ value: String) -> String {
        let normalized = value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard normalized.count > maxTextCharacters else { return normalized }
        let end = normalized.index(normalized.startIndex, offsetBy: maxTextCharacters - 1)
        return "\(normalized[..<end].trimmingCharacters(in: .whitespaces))..."
    }
}
