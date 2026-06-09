import Foundation
import Combine

/// Manages AI assistant chat state, LLM communication, and action execution.
@MainActor
final class ChatManager: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isTyping = false
    @Published var lastError: String?
    @Published var setupMessage: String?

    private let summarizationEngine = SummarizationEngine()
    weak var meetingManager: MeetingManager?
    private var currentChatTask: _Concurrency.Task<Void, Never>?
    private var pendingOutlookTaskCandidates: [OutlookTaskCandidate] = []

    private enum ChatError: Error {
        case timeout
    }

    private let systemPrompt = """
    You are NoteAI Assistant, an AI helper embedded in a macOS productivity app. You help the user manage meetings, notes, tasks, todos, and T5T (Top 5 Things) reports.

    When the user asks you to perform an action, include a JSON action block in your response like this:
    ```json
    {"action": "action_name", "param": "value"}
    ```

    Available actions:
    - create_note: {"action":"create_note", "title":"...", "content":"...", "tags":["..."]}
    - create_task: {"action":"create_task", "title":"...", "description":"...", "status":"open|completed", "work_date":"YYYY-MM-DD or ISO-8601", "source":{"kind":"email", "provider":"outlook", "thread_id":"...", "message_id":"...", "subject":"...", "sender":"...", "date":"ISO-8601", "url":"..."}}
    - create_tasks: {"action":"create_tasks", "tasks":[{"title":"...", "description":"...", "status":"open|completed", "work_date":"YYYY-MM-DD or ISO-8601", "source":{"kind":"email", "provider":"outlook", "thread_id":"...", "message_id":"...", "subject":"...", "sender":"...", "date":"ISO-8601", "url":"..."}}]}
    - create_todo: {"action":"create_todo", "title":"...", "due_date":"YYYY-MM-DD or ISO-8601"}
    - list_tasks: {"action":"list_tasks", "after":"YYYY-MM-DD or MM/DD/YYYY", "before":"YYYY-MM-DD or MM/DD/YYYY", "status":"open|completed|all", "include_completed":true, "include_source":true} — lists durable Tasks as copy-ready Markdown with date lines and indented bullets
    - list_todos: {"action":"list_todos", "status":"open|completed|all"} — lists lightweight reminder todos
    - search_outlook_tasks: {"action":"search_outlook_tasks", "query":"customer, project, topic, sender, or keywords", "after":"YYYY-MM-DD or MM/DD/YYYY", "before":"YYYY-MM-DD or MM/DD/YYYY", "sender":"optional sender filter", "limit":10} — searches Outlook via Microsoft Graph on explicit user request and returns task candidates for review; do not create tasks until the user approves them
    - approve_outlook_tasks: {"action":"approve_outlook_tasks", "selection":"all"} or {"action":"approve_outlook_tasks", "indexes":[1,2,3]} — creates durable Tasks from the most recent Outlook candidates after user approval
    - create_t5t: {"action":"create_t5t"} — generates a full T5T report from durable Tasks using JP's default NVIDIA Top 5 Things style.
    - search: {"action":"search", "query":"..."} — searches meetings and notes
    - list_meetings: {"action":"list_meetings"} — shows recent meetings
    - list_notes: {"action":"list_notes"} — shows recent notes
    - list_t5t: {"action":"list_t5t"} — shows T5T reports
    - delete_note: {"action":"delete_note", "title":"..."}
    - delete_meeting: {"action":"delete_meeting", "title":"..."}

    Rules:
    - Always respond conversationally AND include the action block when taking an action
    - For create actions, confirm what you created
    - For list actions, format the results nicely
    - For search, show matching results
    - If no action is needed, just chat normally
    - When asked to create a T5T report, use create_t5t (NOT create_note); T5Ts are generated from durable Tasks, not meetings or notes
    - When asked to create a task or todo, use create_task or create_todo (NOT create_note); task requests use create_task and todo requests use create_todo
    - When converting Outlook email conversations into work items, use create_tasks to create durable Tasks and preserve available email source metadata
    - When asked to search Outlook or email conversations, use search_outlook_tasks first and ask the user to approve candidates before creating tasks
    - After the user approves Outlook candidates, use approve_outlook_tasks; do not store full email bodies by default
    - When asked to list tasks, use list_tasks and read from durable Tasks
    - When asked to list todos, use list_todos and read from lightweight Todos
    - Be concise and helpful
    """

    init() {
        messages.append(ChatMessage(role: .assistant, content: "How can I help you today? I can create notes, todos, T5T reports, search your meetings, and more."))
        refreshConfigurationPreflight()
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        refreshConfigurationPreflight()

        if let setupMessage {
            lastError = setupMessage
            messages.append(ChatMessage(role: .assistant, content: setupMessage))
            return
        }

        messages.append(ChatMessage(role: .user, content: trimmed))

        if handleLocalTaskOrTodoListRequest(trimmed) {
            return
        }

        isTyping = true
        lastError = nil

        let chatTask = _Concurrency.Task { @MainActor in
            do {
                let sourceContext = meetingManager.map {
                    ChatSourceContext.build(
                        meetings: $0.meetings,
                        notes: $0.notes,
                        t5tReports: $0.t5tReports
                    )
                } ?? ""
                var llmMessages: [(role: String, content: String)] = [
                    (role: "system", content: sourceContext.isEmpty ? systemPrompt : "\(systemPrompt)\n\n\(sourceContext)")
                ]
                for msg in messages.suffix(20) {
                    llmMessages.append((role: msg.role.rawValue, content: msg.content))
                }

                let response = try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask {
                        try await self.summarizationEngine.chat(messages: llmMessages)
                    }
                    group.addTask {
                        try await _Concurrency.Task.sleep(nanoseconds: 60_000_000_000)
                        throw ChatError.timeout
                    }
                    let result = try await group.next()!
                    group.cancelAll()
                    return result
                }

                let actionResult = await executeActions(from: response)

                var displayText = response
                while let range = displayText.range(of: "```json\n", options: .caseInsensitive),
                      let endRange = displayText.range(of: "\n```", range: range.upperBound..<displayText.endIndex) {
                    displayText.removeSubrange(range.lowerBound...endRange.upperBound)
                }
                displayText = displayText.trimmingCharacters(in: .whitespacesAndNewlines)

                if !displayText.isEmpty {
                    messages.append(ChatMessage(role: .assistant, content: displayText))
                }
                if let result = actionResult {
                    messages.append(ChatMessage(role: .system, content: result))
                }
            } catch is CancellationError {
                // Cancelled, do nothing
            } catch ChatError.timeout {
                messages.append(ChatMessage(role: .assistant, content: "Request timed out. Please try again."))
            } catch {
                lastError = error.localizedDescription
                messages.append(ChatMessage(role: .assistant, content: "Sorry, I encountered an error: \(error.localizedDescription)"))
            }
            isTyping = false
        }
        currentChatTask = chatTask
    }

    func refreshConfigurationPreflight() {
        let provider = selectedProvider()
        setupMessage = AIConfigurationPreflight.copilotSetupMessage(
            provider: provider,
            providerKeyConfigured: !APIKeyStore.key(for: provider).isEmpty
        )
    }

    func clearChat() {
        currentChatTask?.cancel()
        currentChatTask = nil
        isTyping = false
        messages.removeAll()
        messages.append(ChatMessage(role: .assistant, content: "Chat cleared. How can I help?"))
    }

    // MARK: - Action Parsing & Execution

    private func executeActions(from response: String) async -> String? {
        guard let manager = meetingManager else { return nil }

        // Extract JSON from ```json ... ``` blocks
        guard let start = response.range(of: "```json\n", options: .caseInsensitive),
              let end = response.range(of: "\n```", range: start.upperBound..<response.endIndex) else {
            return nil
        }

        let jsonString = String(response[start.upperBound..<end.lowerBound])
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = json["action"] as? String else {
            return nil
        }

        switch action {
        case "create_note":
            let title = json["title"] as? String ?? "Untitled"
            let content = json["content"] as? String ?? ""
            let tags = json["tags"] as? [String] ?? []
            let note = manager.createNote(title: title, content: content, tags: tags)
            NotificationCenter.default.post(name: .navigateToNote, object: note.id)
            return "Created note: \(title)"

        case "create_task":
            let draft = AssistantTaskActionParser.taskDraft(from: json)
            manager.createTask(
                title: draft.title,
                description: draft.description,
                status: draft.status,
                workDate: draft.workDate,
                sourceMetadata: draft.sourceMetadata
            )
            if draft.hadUnrecognizedWorkDate {
                return "Created task: \(draft.title). Work date was not recognized."
            }
            return "Created task: \(draft.title)"

        case "create_tasks":
            let drafts = AssistantTaskActionParser.taskDrafts(from: json)
            guard !drafts.isEmpty else { return "No tasks were created." }
            for draft in drafts {
                manager.createTask(
                    title: draft.title,
                    description: draft.description,
                    status: draft.status,
                    workDate: draft.workDate,
                    sourceMetadata: draft.sourceMetadata
                )
            }
            let warning = drafts.contains(where: \.hadUnrecognizedWorkDate) ? " Some work dates were not recognized." : ""
            return "Created \(drafts.count) tasks.\(warning)"

        case "create_todo":
            let title = todoTitle(from: json["title"])
            let dueDateText = (json["due_date"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let dueDate = parseTodoDueDate(dueDateText)
            manager.createTodo(title: title, dueDate: dueDate)
            if let dueDateText, !dueDateText.isEmpty, dueDate == nil {
                return "Created todo: \(title). Due date was not recognized."
            }
            return "Created todo: \(title)"

        case "list_tasks":
            let filters = AssistantTaskListFormatter.filters(from: json)
            return AssistantTaskListFormatter.format(tasks: manager.tasks, filters: filters)

        case "list_todos":
            let filters = AssistantTodoListFormatter.filters(from: json)
            return AssistantTodoListFormatter.format(todos: manager.todos, filters: filters)

        case "search_outlook_tasks":
            do {
                let search = AssistantOutlookActionParser.searchRequest(from: json)
                let auth = OutlookGraphAuthManager()
                let client = OutlookGraphClient(accessTokenProvider: {
                    try await auth.validAccessToken()
                })
                let candidates = try await client.searchTaskCandidates(search)
                pendingOutlookTaskCandidates = candidates
                return AssistantOutlookCandidateFormatter.format(candidates: candidates)
            } catch {
                return "Outlook search failed: \(error.localizedDescription)"
            }

        case "approve_outlook_tasks":
            let selectedCandidates = AssistantOutlookActionParser.selectedCandidates(
                from: json,
                candidates: pendingOutlookTaskCandidates
            )
            guard !selectedCandidates.isEmpty else {
                return pendingOutlookTaskCandidates.isEmpty
                    ? "No pending Outlook task candidates. Search Outlook first."
                    : "No matching Outlook task candidates were selected."
            }
            for candidate in selectedCandidates {
                manager.createTask(
                    title: candidate.title,
                    description: candidate.description,
                    status: .open,
                    workDate: candidate.workDate,
                    sourceMetadata: candidate.sourceMetadata
                )
            }
            pendingOutlookTaskCandidates.removeAll()
            return "Created \(selectedCandidates.count) Outlook-sourced tasks."

        case "create_t5t":
            let end = Date()
            let start = Calendar.current.date(byAdding: .day, value: -14, to: end)!
            let tasks = manager.tasks

            do {
                let sections = try await summarizationEngine.generateT5T(
                    meetings: [],
                    notes: [],
                    tasks: tasks,
                    config: manager.t5tConfig,
                    periodStart: start,
                    periodEnd: end
                )

                let report = T5TReport(
                    id: UUID(),
                    title: manager.t5tDefaultTitle,
                    createdDate: Date(),
                    periodStart: start,
                    periodEnd: end,
                    meetingIDs: [],
                    noteIDs: [],
                    taskIDs: tasks.map(\.id),
                    sections: sections,
                    status: .draft
                )
                manager.addT5TReport(report)
                let entryCount = sections.insights.count + sections.accountUpdates.count + sections.futurePlans.count
                return "Generated T5T report with \(entryCount) entries: \(report.title)"
            } catch {
                return "Failed to generate T5T: \(error.localizedDescription)"
            }

        case "list_t5t":
            let items = manager.t5tReports.prefix(10).map { "\($0.title) (\($0.periodLabel))" }
            return items.isEmpty ? "No T5T reports yet." : items.joined(separator: "\n")

        case "delete_meeting":
            let title = (json["title"] as? String ?? "").lowercased()
            if let meeting = manager.meetings.first(where: { $0.title.lowercased().contains(title) }) {
                manager.deleteMeeting(meeting)
                return "Deleted meeting: \(meeting.title)"
            }
            return "Meeting not found: \(title)"

        case "search":
            let query = (json["query"] as? String ?? "").lowercased()
            var results: [String] = []
            let matchingMeetings = manager.meetings.filter { $0.title.lowercased().contains(query) }
            let matchingNotes = manager.notes.filter { $0.title.lowercased().contains(query) || $0.content.lowercased().contains(query) }
            for m in matchingMeetings.prefix(5) { results.append("Meeting: \(m.title)") }
            for n in matchingNotes.prefix(5) { results.append("Note: \(n.title)") }
            return results.isEmpty ? "No results for '\(query)'" : results.joined(separator: "\n")

        case "list_meetings":
            let items = manager.meetings.prefix(10).map { "\($0.title) (\($0.formattedDuration))" }
            return items.isEmpty ? "No meetings yet." : items.joined(separator: "\n")

        case "list_notes":
            let items = manager.notes.prefix(10).map { $0.title }
            return items.isEmpty ? "No notes yet." : items.joined(separator: "\n")

        case "delete_note":
            let title = (json["title"] as? String ?? "").lowercased()
            if let note = manager.notes.first(where: { $0.title.lowercased().contains(title) }) {
                manager.deleteNote(note)
                return "Deleted note: \(note.title)"
            }
            return "Note not found: \(title)"

        default:
            return nil
        }
    }

    private func todoTitle(from value: Any?) -> String {
        let title = (value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Untitled todo" : title
    }

    private func handleLocalTaskOrTodoListRequest(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        let isListRequest = lowercased.contains("list") || lowercased.contains("show")
        let asksForTasks = lowercased.contains("task")
        let asksForTodos = lowercased.contains("todo")
        guard isListRequest, (asksForTasks || asksForTodos), let manager = meetingManager else {
            return false
        }

        let output: String
        if asksForTasks {
            let filters = AssistantTaskListFormatter.filters(fromPrompt: text)
            output = AssistantTaskListFormatter.format(tasks: manager.tasks, filters: filters)
        } else {
            let filters = AssistantTodoListFormatter.filters(fromPrompt: text)
            output = AssistantTodoListFormatter.format(todos: manager.todos, filters: filters)
        }
        messages.append(ChatMessage(role: .assistant, content: output))
        return true
    }

    private func parseTodoDueDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }

        let isoFormatter = ISO8601DateFormatter()
        if let date = isoFormatter.date(from: value) {
            return date
        }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter.date(from: value)
    }

    private func selectedProvider() -> LLMProviderType {
        let raw = UserDefaults.standard.string(forKey: "llmProvider") ?? LLMProviderType.openRouter.rawValue
        return LLMProviderType(rawValue: raw) ?? .openRouter
    }
}

struct AssistantTaskDraft: Equatable {
    var title: String
    var description: String
    var status: TaskItem.Status
    var workDate: Date?
    var sourceMetadata: TaskItem.SourceMetadata?
    var hadUnrecognizedWorkDate: Bool
}

enum AssistantTaskActionParser {
    static func taskDraft(from json: [String: Any]) -> AssistantTaskDraft {
        draft(from: json)
    }

    static func taskDrafts(from json: [String: Any]) -> [AssistantTaskDraft] {
        guard let rawTasks = json["tasks"] as? [[String: Any]] else {
            return [taskDraft(from: json)]
        }
        return rawTasks.map(draft)
    }

    private static func draft(from json: [String: Any]) -> AssistantTaskDraft {
        let workDateText = stringValue(json["work_date"] ?? json["date"])
        let workDate = parseDate(workDateText)
        return AssistantTaskDraft(
            title: title(from: json["title"]),
            description: stringValue(json["description"]) ?? "",
            status: status(from: stringValue(json["status"])),
            workDate: workDate,
            sourceMetadata: sourceMetadata(from: json),
            hadUnrecognizedWorkDate: workDateText != nil && workDate == nil
        )
    }

    private static func sourceMetadata(from json: [String: Any]) -> TaskItem.SourceMetadata? {
        let source = json["source"] as? [String: Any] ?? json
        let kind = TaskItem.SourceKind(rawValue: stringValue(source["kind"] ?? source["source_kind"])?.lowercased() ?? "") ?? .unknown
        let metadata = TaskItem.SourceMetadata(
            kind: kind,
            provider: stringValue(source["provider"] ?? source["source_provider"]),
            threadID: stringValue(source["thread_id"] ?? source["threadID"] ?? source["thread"] ?? source["source_thread_id"]),
            messageID: stringValue(source["message_id"] ?? source["messageID"] ?? source["source_message_id"]),
            subject: stringValue(source["subject"] ?? source["source_subject"]),
            sender: stringValue(source["sender"] ?? source["from"] ?? source["source_sender"]),
            sentDate: parseDate(stringValue(source["date"] ?? source["sent_date"] ?? source["message_date"] ?? source["source_date"])),
            url: stringValue(source["url"] ?? source["web_url"] ?? source["source_url"])
        )
        return metadata.hasAnyValue ? metadata : nil
    }

    private static func title(from value: Any?) -> String {
        let title = stringValue(value) ?? ""
        return title.isEmpty ? "Untitled task" : title
    }

    private static func status(from value: String?) -> TaskItem.Status {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "completed", "complete", "done":
            return .completed
        default:
            return .open
        }
    }

    private static func stringValue(_ value: Any?) -> String? {
        let trimmed = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }

        let isoFormatter = ISO8601DateFormatter()
        if let date = isoFormatter.date(from: value) {
            return date
        }

        for format in ["yyyy-MM-dd", "MM/dd/yyyy", "M/d/yyyy"] {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = format
            formatter.isLenient = false
            if let date = formatter.date(from: value) {
                return date
            }
        }
        return nil
    }
}

enum AssistantOutlookActionParser {
    static func searchRequest(from json: [String: Any]) -> OutlookMailSearchRequest {
        OutlookMailSearchRequest(
            query: stringValue(json["query"] ?? json["q"] ?? json["keywords"]) ?? "",
            after: parseDate(stringValue(json["after"] ?? json["from"])),
            before: parseDate(stringValue(json["before"] ?? json["to"])),
            sender: stringValue(json["sender"] ?? json["from_sender"]),
            limit: intValue(json["limit"]) ?? 10
        )
    }

    static func selectedCandidates(from json: [String: Any], candidates: [OutlookTaskCandidate]) -> [OutlookTaskCandidate] {
        if let selection = stringValue(json["selection"])?.lowercased(),
           selection == "all" || selection == "approved" {
            return candidates
        }

        let indexes = intArray(json["indexes"] ?? json["index"] ?? json["selected"])
        guard !indexes.isEmpty else { return [] }

        return indexes.compactMap { index in
            let zeroBased = index - 1
            guard candidates.indices.contains(zeroBased) else { return nil }
            return candidates[zeroBased]
        }
    }

    private static func stringValue(_ value: Any?) -> String? {
        let trimmed = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private static func intArray(_ value: Any?) -> [Int] {
        if let values = value as? [Int] { return values }
        if let values = value as? [NSNumber] { return values.map(\.intValue) }
        if let value = intValue(value) { return [value] }
        if let values = value as? [String] {
            return values.compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        return []
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }

        let isoFormatter = ISO8601DateFormatter()
        if let date = isoFormatter.date(from: value) {
            return date
        }

        for format in ["yyyy-MM-dd", "MM/dd/yyyy", "M/d/yyyy"] {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = format
            formatter.isLenient = false
            if let date = formatter.date(from: value) {
                return date
            }
        }
        return nil
    }
}

enum AssistantOutlookCandidateFormatter {
    static func format(candidates: [OutlookTaskCandidate]) -> String {
        guard !candidates.isEmpty else {
            return "No Outlook task candidates found."
        }

        let entries = candidates.enumerated().map { offset, candidate in
            var lines = [
                "\(offset + 1). \(candidate.title)",
            ]
            if let workDate = candidate.workDate {
                lines.append("   Date: \(displayDate(workDate))")
            }
            if let sender = candidate.sourceMetadata.sender {
                lines.append("   From: \(sender)")
            }
            if !candidate.description.isEmpty {
                lines.append("   \(candidate.description)")
            }
            return lines.joined(separator: "\n")
        }

        return """
        Outlook task candidates

        \(entries.joined(separator: "\n\n"))

        Reply with which candidates to create, or approve all.
        """
    }

    private static func displayDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM/dd/yyyy"
        return formatter.string(from: date)
    }
}

enum AssistantTaskListFormatter {
    enum Status: String, Equatable {
        case open
        case completed
        case all
    }

    struct Filters: Equatable {
        var after: Date?
        var before: Date?
        var status: Status = .all
        var includeSource: Bool = false

        init(after: Date? = nil, before: Date? = nil, status: Status = .all, includeSource: Bool = false) {
            self.after = after
            self.before = before
            self.status = status
            self.includeSource = includeSource
        }
    }

    static func filters(from json: [String: Any]) -> Filters {
        let after = parseDate(json["after"] as? String)
        let before = parseDate(json["before"] as? String)
        let status = status(
            from: json["status"] as? String,
            includeCompleted: json["include_completed"] as? Bool
        )
        return Filters(after: after, before: before, status: status, includeSource: json["include_source"] as? Bool ?? false)
    }

    static func filters(fromPrompt prompt: String) -> Filters {
        let after = firstDate(in: prompt, afterKeyword: "after") ?? firstDate(in: prompt, afterKeyword: "since")
        let before = firstDate(in: prompt, afterKeyword: "before")
        let lowercased = prompt.lowercased()
        let status: Status
        if lowercased.contains("open") || lowercased.contains("incomplete") || lowercased.contains("pending") {
            status = .open
        } else if lowercased.contains("completed") || lowercased.contains("done") {
            status = .completed
        } else {
            status = .all
        }
        return Filters(after: after, before: before, status: status)
    }

    static func format(tasks: [TaskItem], filters: Filters) -> String {
        let filteredTasks = tasks
            .filter { matches($0, filters: filters) }
            .sorted { $0.activityDate < $1.activityDate }

        let title = header(for: filters)
        guard !filteredTasks.isEmpty else {
            return "No \(title.lowercased()) found."
        }

        let groupedTasks = Dictionary(grouping: filteredTasks) { Calendar.current.startOfDay(for: $0.activityDate) }
        let entries = groupedTasks.keys.sorted().map { date in
            let tasksForDate = groupedTasks[date] ?? []
            let dateHeader = "- " + slashDate(date)
            let taskEntries = tasksForDate.map { formatGroupedTask($0, includeSource: filters.includeSource) }.joined(separator: "\n")
            return dateHeader + "\n" + taskEntries
        }.joined(separator: "\n")
        return title + "\n\n" + entries
    }

    private static func formatGroupedTask(_ task: TaskItem, includeSource: Bool) -> String {
        let title = task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Untitled task"
            : task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = "  - " + title

        var detailLines = task.description
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if includeSource, let source = task.sourceMetadata {
            detailLines.append(contentsOf: sourceLines(for: source))
        }

        if detailLines.isEmpty {
            return line
        }
        return ([line] + detailLines.map { "    " + $0 }).joined(separator: "\n")
    }

    private static func sourceLines(for source: TaskItem.SourceMetadata) -> [String] {
        var prefix = source.providerDisplayName
        if source.kind == .email {
            prefix += " email"
        }

        var line = "Source: \(prefix)"
        if let sender = source.sender {
            line += " from \(sender)"
        }
        if let subject = source.subject {
            line += "\(source.sender == nil ? " " : ", ")\"\(subject)\""
        }
        if let sentDate = source.sentDate {
            line += " (\(slashDate(sentDate)))"
        }

        var lines = [line]
        if let url = source.url {
            lines.append("Link: \(url)")
        }
        return lines
    }

    private static func matches(_ task: TaskItem, filters: Filters) -> Bool {
        switch filters.status {
        case .open where task.isCompleted:
            return false
        case .completed where !task.isCompleted:
            return false
        default:
            break
        }

        let activity = task.activityDate
        if let after = filters.after, activity < Calendar.current.startOfDay(for: after) {
            return false
        }
        if let before = filters.before, activity > endOfDay(for: before) {
            return false
        }
        return true
    }

    private static func header(for filters: Filters) -> String {
        var parts: [String] = []
        switch filters.status {
        case .open:
            parts.append("Open tasks")
        case .completed:
            parts.append("Completed tasks")
        case .all:
            parts.append("Tasks")
        }
        if let after = filters.after {
            parts.append("after \(displayDate(after))")
        }
        if let before = filters.before {
            parts.append("before \(displayDate(before))")
        }
        return parts.joined(separator: " ")
    }

    private static func status(from value: String?, includeCompleted: Bool?) -> Status {
        if includeCompleted == true {
            return .all
        }
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else {
            return includeCompleted == false ? .open : .all
        }
        switch value {
        case "open", "pending", "incomplete":
            return .open
        case "completed", "complete", "done":
            return .completed
        default:
            return .all
        }
    }

    private static func firstDate(in prompt: String, afterKeyword keyword: String) -> Date? {
        let pattern = "(?i)\\b\(keyword)\\s+([0-9]{1,2}/[0-9]{1,2}/[0-9]{4}|[0-9]{4}-[0-9]{2}-[0-9]{2})"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: prompt, range: NSRange(prompt.startIndex..., in: prompt)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: prompt) else {
            return nil
        }
        return parseDate(String(prompt[range]))
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let rawValue = value?.trimmingCharacters(in: .whitespacesAndNewlines), !rawValue.isEmpty else {
            return nil
        }

        let isoFormatter = ISO8601DateFormatter()
        if let date = isoFormatter.date(from: rawValue) {
            return date
        }

        for format in ["yyyy-MM-dd", "MM/dd/yyyy", "M/d/yyyy"] {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = format
            formatter.isLenient = false
            if let date = formatter.date(from: rawValue) {
                return date
            }
        }
        return nil
    }

    private static func displayDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: date)
    }

    private static func slashDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM/dd/yyyy"
        return formatter.string(from: date)
    }

    private static func endOfDay(for date: Date) -> Date {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: DateComponents(day: 1, second: -1), to: start) ?? date
    }
}

enum AssistantTodoListFormatter {
    enum Status: String, Equatable {
        case open
        case completed
        case all
    }

    struct Filters: Equatable {
        var status: Status = .all
    }

    static func filters(from json: [String: Any]) -> Filters {
        Filters(status: status(from: json["status"] as? String))
    }

    static func filters(fromPrompt prompt: String) -> Filters {
        let lowercased = prompt.lowercased()
        if lowercased.contains("open") || lowercased.contains("incomplete") || lowercased.contains("pending") {
            return Filters(status: .open)
        }
        if lowercased.contains("completed") || lowercased.contains("done") {
            return Filters(status: .completed)
        }
        return Filters(status: .all)
    }

    static func format(todos: [TodoItem], filters: Filters) -> String {
        let filteredTodos = todos
            .filter { matches($0, filters: filters) }
            .sorted { ($0.dueDate ?? $0.createdDate) < ($1.dueDate ?? $1.createdDate) }

        let title = header(for: filters)
        guard !filteredTodos.isEmpty else {
            return "No \(title.lowercased()) found."
        }

        let entries = filteredTodos.map { todo -> String in
            let title = todo.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Untitled todo"
                : todo.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if let label = todo.dueDateLabel, !todo.completed {
                return "- \(title) (\(label))"
            }
            return "- \(title)"
        }
        return title + "\n\n" + entries.joined(separator: "\n")
    }

    private static func matches(_ todo: TodoItem, filters: Filters) -> Bool {
        switch filters.status {
        case .open:
            return !todo.completed
        case .completed:
            return todo.completed
        case .all:
            return true
        }
    }

    private static func header(for filters: Filters) -> String {
        switch filters.status {
        case .open:
            return "Open todos"
        case .completed:
            return "Completed todos"
        case .all:
            return "Todos"
        }
    }

    private static func status(from value: String?) -> Status {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "open", "pending", "incomplete":
            return .open
        case "completed", "complete", "done":
            return .completed
        default:
            return .all
        }
    }
}
