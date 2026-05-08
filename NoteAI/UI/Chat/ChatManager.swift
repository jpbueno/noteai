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
    - create_task: {"action":"create_task", "title":"...", "description":"...", "status":"open|completed", "work_date":"YYYY-MM-DD or ISO-8601"}
    - create_todo: {"action":"create_todo", "title":"...", "due_date":"YYYY-MM-DD or ISO-8601"}
    - list_tasks: {"action":"list_tasks", "after":"YYYY-MM-DD or MM/DD/YYYY", "before":"YYYY-MM-DD or MM/DD/YYYY", "status":"open|completed|all", "include_completed":true} — lists tasks as copy-ready Markdown with title and description content
    - list_todos: {"action":"list_todos", "status":"open|completed|all"} — lists lightweight reminder todos
    - create_t5t: {"action":"create_t5t", "input":"..."} — generates a full T5T report. Put ALL the user's input text in the "input" field so the AI can use it to generate the report sections.
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
    - When asked to create a T5T report, use create_t5t (NOT create_note)
    - When asked to create a task or todo, use create_task or create_todo (NOT create_note); task requests use create_task and todo requests use create_todo
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
            let title = taskTitle(from: json["title"])
            let description = (json["description"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let status = parseTaskStatus(json["status"] as? String)
            let workDateText = (json["work_date"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let workDate = parseTodoDueDate(workDateText)
            manager.createTask(title: title, description: description, status: status, workDate: workDate)
            if let workDateText, !workDateText.isEmpty, workDate == nil {
                return "Created task: \(title). Work date was not recognized."
            }
            return "Created task: \(title)"

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

        case "create_t5t":
            let inputText = json["input"] as? String ?? ""
            let end = Date()
            let start = Calendar.current.date(byAdding: .day, value: -14, to: end)!

            let meetings = manager.meetingsInRange(start: start, end: end)
            let notes = manager.notes
            let tasks = manager.tasks

            do {
                let sections = try await summarizationEngine.generateT5T(
                    meetings: meetings,
                    notes: inputText.isEmpty ? notes : [Note(title: "Input", content: inputText)],
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
                    meetingIDs: meetings.map(\.id),
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

    private func taskTitle(from value: Any?) -> String {
        let title = (value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Untitled task" : title
    }

    private func parseTaskStatus(_ value: String?) -> TaskItem.Status {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "completed", "complete", "done":
            return .completed
        default:
            return .open
        }
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
    }

    static func filters(from json: [String: Any]) -> Filters {
        let after = parseDate(json["after"] as? String)
        let before = parseDate(json["before"] as? String)
        let status = status(
            from: json["status"] as? String,
            includeCompleted: json["include_completed"] as? Bool
        )
        return Filters(after: after, before: before, status: status)
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
            let taskEntries = tasksForDate.map(formatGroupedTask).joined(separator: "\n")
            return dateHeader + "\n" + taskEntries
        }.joined(separator: "\n")
        return title + "\n\n" + entries
    }

    private static func formatGroupedTask(_ task: TaskItem) -> String {
        let title = task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Untitled task"
            : task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = "  - " + title

        let descriptionLines = task.description
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { "    " + $0 }

        if descriptionLines.isEmpty {
            return line
        }
        return ([line] + descriptionLines).joined(separator: "\n")
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
