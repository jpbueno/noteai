import Foundation

enum WorkActivityAssistant {
    static func response(
        for prompt: String,
        tasks: [TaskItem],
        todos: [TodoItem],
        meetings: [Meeting],
        notes: [Note],
        t5tReports: [T5TReport],
        sourceStatus: AssistantSourceStatus = .localOnly,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String? {
        let lowercased = prompt.lowercased()
        let range = dateRange(for: lowercased, now: now, calendar: calendar)

        if asksForT5TReadyUpdates(lowercased) {
            return t5TReadyResponse(tasks: tasks, range: range)
        }

        guard asksForWorkActivity(lowercased) else { return nil }

        return workActivityResponse(
            tasks: tasks,
            todos: todos,
            meetings: meetings,
            notes: notes,
            t5tReports: t5tReports,
            sourceStatus: sourceStatus,
            range: range
        )
    }

    private static func asksForT5TReadyUpdates(_ prompt: String) -> Bool {
        (prompt.contains("t5t") || prompt.contains("top 5")) &&
        (prompt.contains("ready") || prompt.contains("update") || prompt.contains("source") || prompt.contains("draft"))
    }

    private static func asksForWorkActivity(_ prompt: String) -> Bool {
        let workPhrases = [
            "what did i work",
            "what i worked",
            "worked on",
            "working on",
            "most important projects",
            "projects i've worked",
            "projects i worked",
            "work activity",
            "work summary",
            "what have i done",
            "what did i do"
        ]
        return workPhrases.contains { prompt.contains($0) }
    }

    private static func workActivityResponse(
        tasks: [TaskItem],
        todos: [TodoItem],
        meetings: [Meeting],
        notes: [Note],
        t5tReports: [T5TReport],
        sourceStatus: AssistantSourceStatus,
        range: ActivityDateRange
    ) -> String {
        var lines = [
            "Work activity \(range.label)",
            "",
            sourceStatus.summaryLine
        ]

        let taskRecords = tasks
            .filter { range.contains($0.activityDate) }
            .map { ActivityRecord(date: $0.activityDate, kind: "Task", title: cleanTitle($0.title, fallback: "Untitled task"), detail: cleanOptional($0.description)) }

        let todoRecords = todos
            .filter { range.contains($0.dueDate ?? max($0.createdDate, $0.modifiedDate)) }
            .map { ActivityRecord(date: $0.dueDate ?? max($0.createdDate, $0.modifiedDate), kind: "Todo", title: cleanTitle($0.title, fallback: "Untitled todo"), detail: cleanOptional($0.description)) }

        let meetingRecords = meetings
            .filter { range.contains($0.date) }
            .map { ActivityRecord(date: $0.date, kind: "Meeting", title: cleanTitle($0.title, fallback: "Untitled meeting"), detail: $0.formattedDuration) }

        let noteRecords = notes
            .filter { range.contains(max($0.createdDate, $0.modifiedDate)) }
            .map { ActivityRecord(date: max($0.createdDate, $0.modifiedDate), kind: "Note", title: cleanTitle($0.title, fallback: "Untitled note"), detail: notePreview($0.content)) }

        let reportRecords = t5tReports
            .filter { range.contains($0.createdDate) }
            .map { ActivityRecord(date: $0.createdDate, kind: "T5T", title: cleanTitle($0.title, fallback: "Untitled T5T"), detail: $0.periodLabel) }

        let records = (taskRecords + todoRecords + meetingRecords + noteRecords + reportRecords)
            .sorted { lhs, rhs in
                if lhs.date == rhs.date { return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending }
                return lhs.date > rhs.date
            }

        guard !records.isEmpty else {
            lines.append("")
            lines.append("No local NoteAI work activity found for this period.")
            return lines.joined(separator: "\n")
        }

        lines.append("")
        for record in records.prefix(16) {
            lines.append("- \(record.kind): \(record.title)")
            if let detail = record.detail {
                lines.append("  \(detail)")
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func t5TReadyResponse(tasks: [TaskItem], range: ActivityDateRange) -> String {
        let matchingTasks = tasks
            .filter { range.contains($0.activityDate) }
            .sorted { lhs, rhs in
                if lhs.activityDate == rhs.activityDate {
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
                return lhs.activityDate > rhs.activityDate
            }

        var lines = [
            "T5T-ready task updates \(range.label)",
            "",
            "Sources: durable NoteAI Tasks only."
        ]

        guard !matchingTasks.isEmpty else {
            lines.append("")
            lines.append("No task updates found for this period.")
            return lines.joined(separator: "\n")
        }

        lines.append("")
        for task in matchingTasks.prefix(12) {
            lines.append(cleanTitle(task.title, fallback: "Untitled task"))
            if let description = cleanOptional(task.description) {
                lines.append("- \(description)")
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func dateRange(for prompt: String, now: Date, calendar: Calendar) -> ActivityDateRange {
        var calendar = calendar
        calendar.timeZone = .current

        if prompt.contains("today") {
            let start = calendar.startOfDay(for: now)
            return ActivityDateRange(start: start, end: now, label: "today")
        }

        if prompt.contains("this month") || prompt.contains("month") {
            let components = calendar.dateComponents([.year, .month], from: now)
            let start = calendar.date(from: components) ?? calendar.startOfDay(for: now)
            return ActivityDateRange(start: start, end: now, label: "this month")
        }

        if prompt.contains("this week") || prompt.contains("week") {
            let start = calendar.dateInterval(of: .weekOfYear, for: now)?.start
                ?? calendar.date(byAdding: .day, value: -7, to: now)
                ?? now
            return ActivityDateRange(start: start, end: now, label: "this week")
        }

        let start = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        return ActivityDateRange(start: start, end: now, label: "in the last 7 days")
    }

    private static func cleanTitle(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static func cleanOptional(_ value: String) -> String? {
        let trimmed = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n\n+", with: "\n", options: .regularExpression)
        return trimmed.isEmpty ? nil : clipped(trimmed)
    }

    private static func notePreview(_ content: String) -> String? {
        cleanOptional(content)?
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private static func clipped(_ value: String, limit: Int = 240) -> String {
        guard value.count > limit else { return value }
        let end = value.index(value.startIndex, offsetBy: limit)
        return String(value[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    private struct ActivityRecord {
        let date: Date
        let kind: String
        let title: String
        let detail: String?
    }

    private struct ActivityDateRange {
        let interval: DateInterval
        let label: String

        init(start: Date, end: Date, label: String) {
            self.interval = DateInterval(start: start, end: end)
            self.label = label
        }

        func contains(_ date: Date) -> Bool {
            interval.contains(date)
        }
    }
}

struct AssistantSourceStatus: Equatable {
    var outlook: AssistantExternalSourceState
    var slack: AssistantExternalSourceState
    var teams: AssistantExternalSourceState

    static let localOnly = AssistantSourceStatus(
        outlook: .needsConfiguration,
        slack: .notAvailable,
        teams: .notAvailable
    )

    var summaryLine: String {
        [
            "Sources: NoteAI local records.",
            outlook.description(for: "Outlook email search"),
            slack.description(for: "Slack source search"),
            teams.description(for: "Teams source search")
        ].joined(separator: " ")
    }
}

enum AssistantExternalSourceState: Equatable {
    case connected
    case needsSignIn
    case needsConfiguration
    case notAvailable

    func description(for sourceName: String) -> String {
        switch self {
        case .connected:
            return "\(sourceName) is connected for explicit searches."
        case .needsSignIn:
            return "\(sourceName) is configured but not signed in."
        case .needsConfiguration:
            return "\(sourceName) needs setup before it can be used."
        case .notAvailable:
            return "\(sourceName) is not connected in this build."
        }
    }
}

enum AssistantSourceStatusProvider {
    static func currentStatus() -> AssistantSourceStatus {
        AssistantSourceStatus(
            outlook: outlookStatus(),
            slack: .notAvailable,
            teams: .notAvailable
        )
    }

    private static func outlookStatus() -> AssistantExternalSourceState {
        guard OutlookGraphSettings.hasClientConfiguration else {
            return .needsConfiguration
        }

        return OutlookGraphTokenStore.isSignedIn ? .connected : .needsSignIn
    }
}
