import Foundation

enum LibraryOperations {
    static func filter(meetings: [Meeting], query rawQuery: String) -> [Meeting] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return meetings }

        return meetings.filter { meeting in
            meeting.title.lowercased().contains(query) ||
            meeting.summary.topics.contains { $0.lowercased().contains(query) } ||
            meeting.summary.decisions.contains { $0.lowercased().contains(query) } ||
            meeting.summary.actionItems.contains { $0.task.lowercased().contains(query) } ||
            meeting.transcript.contains { $0.text.lowercased().contains(query) }
        }
    }

    static func meetingsInRange(_ meetings: [Meeting], start: Date, end: Date) -> [Meeting] {
        meetings.filter { $0.date >= start && $0.date <= end }
    }
}
