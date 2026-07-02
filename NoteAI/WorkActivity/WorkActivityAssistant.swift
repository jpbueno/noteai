import Foundation

enum WorkActivitySource: String, CaseIterable {
    case noteAI
    case outlook
    case slack
    case teams

    var displayName: String {
        switch self {
        case .noteAI: return "NoteAI local records"
        case .outlook: return "Outlook email"
        case .slack: return "Slack"
        case .teams: return "Teams"
        }
    }

    var statusName: String {
        switch self {
        case .noteAI: return "NoteAI local records"
        case .outlook: return "Outlook email search"
        case .slack: return "Slack source search"
        case .teams: return "Teams source search"
        }
    }
}

struct WorkActivityDateRange: Equatable {
    let interval: DateInterval
    let label: String

    init(start: Date, end: Date, label: String) {
        self.interval = DateInterval(start: start, end: end)
        self.label = label
    }

    func contains(_ date: Date) -> Bool {
        date >= interval.start && date <= interval.end
    }
}

struct WorkActivityQuery: Equatable {
    let prompt: String
    let range: WorkActivityDateRange
    let limit: Int
}

struct WorkActivityRecord: Equatable {
    let date: Date
    let source: WorkActivitySource
    let kind: String
    let title: String
    let detail: String?
}

enum WorkActivitySourceResultStatus: Equatable {
    case searched
    case skipped(String)
    case failed(String)
}

struct WorkActivitySourceResult: Equatable {
    let source: WorkActivitySource
    let status: WorkActivitySourceResultStatus
    let records: [WorkActivityRecord]
    let coverageNote: String?

    init(
        source: WorkActivitySource,
        status: WorkActivitySourceResultStatus,
        records: [WorkActivityRecord] = [],
        coverageNote: String? = nil
    ) {
        self.source = source
        self.status = status
        self.records = records
        self.coverageNote = coverageNote
    }
}

protocol WorkActivitySourceAdapter {
    var source: WorkActivitySource { get }
    func searchWorkActivity(_ query: WorkActivityQuery) async -> WorkActivitySourceResult
}

struct NoteAIWorkActivitySourceAdapter: WorkActivitySourceAdapter {
    let source: WorkActivitySource = .noteAI
    var tasks: [TaskItem]
    var todos: [TodoItem]
    var meetings: [Meeting]
    var notes: [Note]
    var t5tReports: [T5TReport]

    func searchWorkActivity(_ query: WorkActivityQuery) async -> WorkActivitySourceResult {
        let range = query.range
        let taskRecords = tasks
            .filter { range.contains($0.activityDate) }
            .map { WorkActivityRecord(date: $0.activityDate, source: source, kind: "Task", title: WorkActivityText.cleanTitle($0.title, fallback: "Untitled task"), detail: WorkActivityText.cleanOptional($0.description)) }

        let todoRecords = todos
            .filter { range.contains($0.dueDate ?? max($0.createdDate, $0.modifiedDate)) }
            .map { WorkActivityRecord(date: $0.dueDate ?? max($0.createdDate, $0.modifiedDate), source: source, kind: "Todo", title: WorkActivityText.cleanTitle($0.title, fallback: "Untitled todo"), detail: WorkActivityText.cleanOptional($0.description)) }

        let meetingRecords = meetings
            .filter { range.contains($0.date) }
            .map { WorkActivityRecord(date: $0.date, source: source, kind: "Meeting", title: WorkActivityText.cleanTitle($0.title, fallback: "Untitled meeting"), detail: $0.formattedDuration) }

        let noteRecords = notes
            .filter { range.contains(max($0.createdDate, $0.modifiedDate)) }
            .map { WorkActivityRecord(date: max($0.createdDate, $0.modifiedDate), source: source, kind: "Note", title: WorkActivityText.cleanTitle($0.title, fallback: "Untitled note"), detail: WorkActivityText.notePreview($0.content)) }

        let reportRecords = t5tReports
            .filter { range.contains($0.createdDate) }
            .map { WorkActivityRecord(date: $0.createdDate, source: source, kind: "T5T", title: WorkActivityText.cleanTitle($0.title, fallback: "Untitled T5T"), detail: $0.periodLabel) }

        return WorkActivitySourceResult(
            source: source,
            status: .searched,
            records: taskRecords + todoRecords + meetingRecords + noteRecords + reportRecords
        )
    }
}

struct OutlookWorkActivitySourceAdapter: WorkActivitySourceAdapter {
    let source: WorkActivitySource = .outlook
    var search: (DateInterval, Int) async throws -> AIPIMSearchResult

    init(search: @escaping (DateInterval, Int) async throws -> AIPIMSearchResult) {
        self.search = search
    }

    func searchWorkActivity(_ query: WorkActivityQuery) async -> WorkActivitySourceResult {
        do {
            let result = try await search(query.range.interval, min(query.limit, 25))
            let records = result.items.map { item in
                WorkActivityRecord(
                    date: item.timestamp,
                    source: source,
                    kind: "Outlook email",
                    title: WorkActivityText.cleanTitle(item.title, fallback: "Outlook conversation"),
                    detail: WorkActivityText.cleanOptional(item.body)
                )
            }
            return WorkActivitySourceResult(
                source: source,
                status: .searched,
                records: records,
                coverageNote: result.isPartial ? "Outlook returned bounded message previews; results may be partial." : nil
            )
        } catch {
            return AIPIMWorkActivityFailure.result(source: source, error: error)
        }
    }
}

struct SlackWorkActivitySourceAdapter: WorkActivitySourceAdapter {
    let source: WorkActivitySource = .slack
    var search: (DateInterval, Int) async throws -> AIPIMSearchResult

    init(search: @escaping (DateInterval, Int) async throws -> AIPIMSearchResult) {
        self.search = search
    }

    func searchWorkActivity(_ query: WorkActivityQuery) async -> WorkActivitySourceResult {
        do {
            let result = try await search(query.range.interval, min(query.limit, 100))
            let records = result.items.map {
                WorkActivityRecord(
                    date: $0.timestamp,
                    source: source,
                    kind: "Slack message",
                    title: WorkActivityText.cleanTitle($0.title, fallback: "Slack message"),
                    detail: WorkActivityText.cleanOptional($0.body)
                )
            }
            return WorkActivitySourceResult(
                source: source,
                status: .searched,
                records: records,
                coverageNote: result.isPartial ? "Slack returned a bounded first page; results may be partial." : nil
            )
        } catch {
            return AIPIMWorkActivityFailure.result(source: source, error: error)
        }
    }
}

struct TeamsWorkActivitySourceAdapter: WorkActivitySourceAdapter {
    let source: WorkActivitySource = .teams
    var search: (DateInterval, Int, Int) async throws -> AIPIMSearchResult

    init(search: @escaping (DateInterval, Int, Int) async throws -> AIPIMSearchResult) {
        self.search = search
    }

    func searchWorkActivity(_ query: WorkActivityQuery) async -> WorkActivitySourceResult {
        do {
            let result = try await search(query.range.interval, min(query.limit, 100), 50)
            let records = result.items.map {
                WorkActivityRecord(
                    date: $0.timestamp,
                    source: source,
                    kind: "Teams chat",
                    title: WorkActivityText.cleanTitle($0.title, fallback: "Teams message"),
                    detail: WorkActivityText.cleanOptional($0.body)
                )
            }
            return WorkActivitySourceResult(
                source: source,
                status: .searched,
                records: records,
                coverageNote: "Teams chat coverage is partial; Teams channels are not included."
            )
        } catch {
            return AIPIMWorkActivityFailure.result(source: source, error: error)
        }
    }
}

private enum AIPIMWorkActivityFailure {
    static func result(source: WorkActivitySource, error: Error) -> WorkActivitySourceResult {
        if let aipimError = error as? AIPIMError {
            switch aipimError {
            case .unavailable:
                return WorkActivitySourceResult(
                    source: source,
                    status: .skipped("\(source.statusName) requires ai-pim-utils. Install it from the Account settings help")
                )
            case .authenticationRequired:
                return WorkActivitySourceResult(
                    source: source,
                    status: .skipped("\(source.statusName) requires sign-in from Account settings")
                )
            default:
                return WorkActivitySourceResult(
                    source: source,
                    status: .failed("\(source.statusName) failed: \(aipimError.localizedDescription)")
                )
            }
        }

        return WorkActivitySourceResult(
            source: source,
            status: .failed("\(source.statusName) failed without exposing source output")
        )
    }
}

struct WorkActivityAggregator {
    var adapters: [any WorkActivitySourceAdapter]
    var sourceStatus: AssistantSourceStatus

    func response(
        for prompt: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) async -> String? {
        guard let query = WorkActivityAssistant.workActivityQuery(for: prompt, now: now, calendar: calendar) else {
            return nil
        }

        var results: [WorkActivitySourceResult] = []
        for adapter in adapters {
            results.append(await adapter.searchWorkActivity(query))
        }
        results.append(contentsOf: skippedExplicitSources(for: prompt.lowercased(), existingResults: results))

        return WorkActivityAssistant.formatWorkActivityResponse(
            prompt: prompt.lowercased(),
            range: query.range,
            results: results
        )
    }

    private func skippedExplicitSources(
        for prompt: String,
        existingResults: [WorkActivitySourceResult]
    ) -> [WorkActivitySourceResult] {
        let existingSources = Set(existingResults.map(\.source))
        var skipped: [WorkActivitySourceResult] = []

        if (prompt.contains("outlook") || prompt.contains("email")),
           !existingSources.contains(.outlook),
           sourceStatus.outlook != .connected {
            skipped.append(WorkActivitySourceResult(source: .outlook, status: .skipped(sourceStatus.outlook.description(for: WorkActivitySource.outlook.statusName))))
        }

        if prompt.contains("slack"), !existingSources.contains(.slack) {
            skipped.append(WorkActivitySourceResult(source: .slack, status: .skipped(sourceStatus.slack.description(for: WorkActivitySource.slack.statusName))))
        }

        if (prompt.contains("teams") || prompt.contains("microsoft teams")), !existingSources.contains(.teams) {
            skipped.append(WorkActivitySourceResult(source: .teams, status: .skipped(sourceStatus.teams.description(for: WorkActivitySource.teams.statusName))))
        }

        return skipped
    }
}

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

        let localResult = awaitSyncLocalWorkActivity(
            prompt: lowercased,
            tasks: tasks,
            todos: todos,
            meetings: meetings,
            notes: notes,
            t5tReports: t5tReports,
            range: range
        )

        return workActivityResponse(
            prompt: lowercased,
            sourceStatus: sourceStatus,
            range: range,
            localResult: localResult
        )
    }

    static func isT5TReadyRequest(_ prompt: String) -> Bool {
        asksForT5TReadyUpdates(prompt.lowercased())
    }

    static func workActivityQuery(
        for prompt: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> WorkActivityQuery? {
        let lowercased = prompt.lowercased()
        guard asksForWorkActivity(lowercased) else { return nil }
        return WorkActivityQuery(prompt: lowercased, range: dateRange(for: lowercased, now: now, calendar: calendar), limit: 18)
    }

    static func formatWorkActivityResponse(
        prompt: String,
        range: WorkActivityDateRange,
        results: [WorkActivitySourceResult]
    ) -> String {
        var lines = [
            "Work activity \(range.label)",
            "",
            sourceSummaryLine(results)
        ]

        let skippedMessages = results.compactMap { result -> String? in
            if case .skipped(let message) = result.status { return WorkActivityText.trimTrailingSentencePunctuation(message) }
            return nil
        }
        if !skippedMessages.isEmpty {
            lines.append("Sources skipped: \(skippedMessages.joined(separator: "; ")).")
        }

        let failureMessages = results.compactMap { result -> String? in
            if case .failed(let message) = result.status { return WorkActivityText.trimTrailingSentencePunctuation(message) }
            return nil
        }
        if !failureMessages.isEmpty {
            lines.append("Source errors: \(failureMessages.joined(separator: "; ")).")
        }

        let coverageNotes = results.compactMap(\.coverageNote).uniqued()
        if !coverageNotes.isEmpty {
            lines.append("Source coverage: \(coverageNotes.joined(separator: " "))")
        }

        let records = results
            .flatMap(\.records)
            .sorted { lhs, rhs in
                if lhs.date == rhs.date { return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending }
                return lhs.date > rhs.date
            }

        guard !records.isEmpty else {
            lines.append("")
            lines.append("No work activity found for this period.")
            return lines.joined(separator: "\n")
        }

        lines.append("")
        for record in records.prefix(18) {
            lines.append("- \(record.kind): \(record.title)")
            if let detail = record.detail {
                lines.append("  \(detail)")
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func sourceSummaryLine(_ results: [WorkActivitySourceResult]) -> String {
        let searchedSources = results
            .filter {
                if case .searched = $0.status { return true }
                return false
            }
            .map(\.source.displayName)

        guard !searchedSources.isEmpty else {
            return "Sources searched: none."
        }

        return "Sources searched: \(searchedSources.joined(separator: ", "))."
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
        prompt: String,
        sourceStatus: AssistantSourceStatus,
        range: WorkActivityDateRange,
        localResult: WorkActivitySourceResult
    ) -> String {
        var results = [localResult]
        if (prompt.contains("outlook") || prompt.contains("email")), sourceStatus.outlook != .connected {
            results.append(WorkActivitySourceResult(source: .outlook, status: .skipped(sourceStatus.outlook.description(for: WorkActivitySource.outlook.statusName))))
        }

        return formatWorkActivityResponse(prompt: prompt, range: range, results: results)
    }

    private static func awaitSyncLocalWorkActivity(
        prompt: String,
        tasks: [TaskItem],
        todos: [TodoItem],
        meetings: [Meeting],
        notes: [Note],
        t5tReports: [T5TReport],
        range: WorkActivityDateRange
    ) -> WorkActivitySourceResult {
        var records: [WorkActivityRecord] = []
        records.append(contentsOf: tasks
            .filter { range.contains($0.activityDate) }
            .map { WorkActivityRecord(date: $0.activityDate, source: .noteAI, kind: "Task", title: cleanTitle($0.title, fallback: "Untitled task"), detail: cleanOptional($0.description)) })
        records.append(contentsOf: todos
            .filter { range.contains($0.dueDate ?? max($0.createdDate, $0.modifiedDate)) }
            .map { WorkActivityRecord(date: $0.dueDate ?? max($0.createdDate, $0.modifiedDate), source: .noteAI, kind: "Todo", title: cleanTitle($0.title, fallback: "Untitled todo"), detail: cleanOptional($0.description)) })
        records.append(contentsOf: meetings
            .filter { range.contains($0.date) }
            .map { WorkActivityRecord(date: $0.date, source: .noteAI, kind: "Meeting", title: cleanTitle($0.title, fallback: "Untitled meeting"), detail: $0.formattedDuration) })
        records.append(contentsOf: notes
            .filter { range.contains(max($0.createdDate, $0.modifiedDate)) }
            .map { WorkActivityRecord(date: max($0.createdDate, $0.modifiedDate), source: .noteAI, kind: "Note", title: cleanTitle($0.title, fallback: "Untitled note"), detail: notePreview($0.content)) })
        records.append(contentsOf: t5tReports
            .filter { range.contains($0.createdDate) }
            .map { WorkActivityRecord(date: $0.createdDate, source: .noteAI, kind: "T5T", title: cleanTitle($0.title, fallback: "Untitled T5T"), detail: $0.periodLabel) })
        return WorkActivitySourceResult(source: .noteAI, status: .searched, records: records)
    }

    private static func t5TReadyResponse(tasks: [TaskItem], range: WorkActivityDateRange) -> String {
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

    private static func dateRange(for prompt: String, now: Date, calendar: Calendar) -> WorkActivityDateRange {
        var calendar = calendar
        calendar.timeZone = .current

        if prompt.contains("today") {
            let start = calendar.startOfDay(for: now)
            return WorkActivityDateRange(start: start, end: now, label: "today")
        }

        if prompt.contains("this month") || prompt.contains("month") {
            let components = calendar.dateComponents([.year, .month], from: now)
            let start = calendar.date(from: components) ?? calendar.startOfDay(for: now)
            return WorkActivityDateRange(start: start, end: now, label: "this month")
        }

        if prompt.contains("this week") || prompt.contains("week") {
            let start = calendar.dateInterval(of: .weekOfYear, for: now)?.start
                ?? calendar.date(byAdding: .day, value: -7, to: now)
                ?? now
            return WorkActivityDateRange(start: start, end: now, label: "this week")
        }

        let start = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        return WorkActivityDateRange(start: start, end: now, label: "in the last 7 days")
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

}

private enum WorkActivityText {
    static func cleanTitle(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    static func cleanOptional(_ value: String) -> String? {
        let trimmed = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n\n+", with: "\n", options: .regularExpression)
        return trimmed.isEmpty ? nil : clipped(trimmed)
    }

    static func notePreview(_ content: String) -> String? {
        cleanOptional(content)?
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    static func clipped(_ value: String, limit: Int = 240) -> String {
        guard value.count > limit else { return value }
        let end = value.index(value.startIndex, offsetBy: limit)
        return String(value[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    static func trimTrailingSentencePunctuation(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
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
        summaryLine(for: "")
    }

    func summaryLine(for prompt: String) -> String {
        let normalizedPrompt = prompt.lowercased()
        var parts = ["Sources: NoteAI local records."]

        if outlook == .connected || normalizedPrompt.contains("outlook") || normalizedPrompt.contains("email") {
            parts.append(outlook.description(for: "Outlook email search"))
        }

        if normalizedPrompt.contains("slack") {
            parts.append(slack.description(for: "Slack source search"))
        }

        if normalizedPrompt.contains("teams") || normalizedPrompt.contains("microsoft teams") {
            parts.append(teams.description(for: "Teams source search"))
        }

        return parts.joined(separator: " ")
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
            outlook: aipimStatus(.outlook),
            slack: aipimStatus(.slack),
            teams: aipimStatus(.teams)
        )
    }

    private static func aipimStatus(_ source: AIPIMSource) -> AssistantExternalSourceState {
        AIPIMExecutableDiscovery().executableURL(for: source) == nil ? .notAvailable : .needsSignIn
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
