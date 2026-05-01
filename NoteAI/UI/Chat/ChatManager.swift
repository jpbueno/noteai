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
    You are NoteAI Assistant, an AI helper embedded in a macOS productivity app. You help the user manage meetings, notes, todos, and T5T (Top 5 Things) reports.

    When the user asks you to perform an action, include a JSON action block in your response like this:
    ```json
    {"action": "action_name", "param": "value"}
    ```

    Available actions:
    - create_note: {"action":"create_note", "title":"...", "content":"...", "tags":["..."]}
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
    - Be concise and helpful
    """

    init() {
        messages.append(ChatMessage(role: .assistant, content: "How can I help you today? I can create notes, T5T reports, search your meetings, and more."))
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

        case "create_t5t":
            let inputText = json["input"] as? String ?? ""
            let end = Date()
            let start = Calendar.current.date(byAdding: .day, value: -14, to: end)!

            let meetings = manager.meetingsInRange(start: start, end: end)
            let notes = manager.notes
            let todos = manager.todos

            do {
                let sections = try await summarizationEngine.generateT5T(
                    meetings: meetings,
                    notes: inputText.isEmpty ? notes : [Note(title: "Input", content: inputText)],
                    todos: todos,
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

    private func selectedProvider() -> LLMProviderType {
        let raw = UserDefaults.standard.string(forKey: "llmProvider") ?? LLMProviderType.openRouter.rawValue
        return LLMProviderType(rawValue: raw) ?? .openRouter
    }
}
