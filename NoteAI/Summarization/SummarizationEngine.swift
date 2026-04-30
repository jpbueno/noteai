import Foundation

/// Generates structured meeting summaries by routing to the user's chosen LLM provider/model.
/// Supports OpenRouter (100+ models), Anthropic direct, and OpenAI direct.
final class SummarizationEngine {

    func summarize(transcript: String) async throws -> MeetingSummary {
        let client = try buildClient()
        let model = selectedModelID()
        let template = selectedTemplate()
        let prompt = buildPrompt(transcript: transcript, template: template)
        let responseText = try await client.complete(prompt: prompt, model: model)
        return try AITasks.parseMeetingSummary(responseText)
    }

    /// Generates a follow-up email draft based on a meeting's transcript and summary.
    func draftFollowUp(meeting: Meeting) async throws -> String {
        let client = try buildClient()
        let model = selectedModelID()

        let summaryText = AITasks.formatSummaryForPrompt(meeting.summary)
        let prompt = """
        You are a professional assistant. Based on the meeting summary and transcript below, draft a concise follow-up email.

        The email should:
        - Thank attendees for their time
        - Recap key decisions made
        - List action items with owners and deadlines
        - Note any open questions that need resolution
        - Be professional but not overly formal
        - Be ready to send (include Subject line)

        Format the output as:
        Subject: <subject line>

        <email body>

        MEETING: \(meeting.title)
        DATE: \(meeting.date.formatted(date: .long, time: .shortened))

        SUMMARY:
        \(summaryText)

        TRANSCRIPT (for additional context):
        \(meeting.transcript.prefix(60).map { "[\($0.formattedTimestamp)] \($0.speaker ?? "Speaker"): \($0.text)" }.joined(separator: "\n"))
        """

        return try await client.complete(prompt: prompt, model: model)
    }

    // MARK: - Client construction

    private func buildClient() throws -> LLMClient {
        let provider = selectedProvider()
        let apiKey = resolveAPIKey(for: provider)

        guard !apiKey.isEmpty else {
            throw SummarizationError.noAPIKey
        }

        switch provider {
        case .openRouter:
            return OpenRouterClient(apiKey: apiKey)
        case .anthropic:
            return AnthropicClient(apiKey: apiKey)
        case .openAI:
            return OpenRouterClient(apiKey: apiKey, baseURL: LLMProviderType.openAI.baseURL)
        case .nvidia:
            return OpenRouterClient(apiKey: apiKey, baseURL: LLMProviderType.nvidia.baseURL)
        }
    }

    private func selectedProvider() -> LLMProviderType {
        let raw = UserDefaults.standard.string(forKey: "llmProvider") ?? "openrouter"
        return LLMProviderType(rawValue: raw) ?? .openRouter
    }

    private func selectedModelID() -> String {
        UserDefaults.standard.string(forKey: "llmModel") ?? "deepseek/deepseek-chat-v3"
    }

    private func selectedTemplate() -> MeetingTemplate {
        let raw = UserDefaults.standard.string(forKey: "meetingTemplate") ?? "auto"
        return MeetingTemplate(rawValue: raw) ?? .auto
    }

    private func resolveAPIKey(for provider: LLMProviderType) -> String {
        APIKeyStore.key(for: provider)
    }

    // MARK: - Prompt

    private func buildPrompt(transcript: String, template: MeetingTemplate) -> String {
        """
        You are a meeting summarization assistant. \(template.promptInstruction)

        Analyze the following meeting transcript and produce a structured summary.

        Output ONLY valid JSON with this exact structure:
        \(template.jsonStructure)

        TRANSCRIPT:
        \(transcript)
        """
    }

    // MARK: - Chat

    /// Multi-turn chat with the configured LLM provider.
    func chat(messages: [(role: String, content: String)]) async throws -> String {
        let client = try buildClient()
        let model = selectedModelID()
        return try await client.chat(messages: messages, model: model)
    }

    // MARK: - T5T Generation

    /// Generates a T5T (Top 5 Things) report from multiple meetings in a reporting period.
    func generateT5T(meetings: [Meeting], notes: [Note] = [], todos: [TodoItem] = [], config: T5TConfig, periodStart: Date, periodEnd: Date) async throws -> T5TSections {
        let client = try buildClient()
        let model = selectedModelID()

        let dateFmt = DateFormatter()
        dateFmt.dateStyle = .medium

        // Build per-meeting summaries for the prompt
        var meetingBlocks: [String] = []
        for meeting in meetings {
            var block = "MEETING: \(meeting.title)\n"
            block += "DATE: \(meeting.date.formatted(date: .abbreviated, time: .shortened))\n"
            block += "DURATION: \(meeting.formattedDuration)\n"
            block += AITasks.formatSummaryForPrompt(meeting.summary)
            meetingBlocks.append(block)
        }
        let meetingsText = meetingBlocks.joined(separator: "\n\n---\n\n")

        // Build note blocks
        var noteBlocks: [String] = []
        for note in notes {
            var block = "NOTE: \(note.title)\n"
            block += "DATE: \(note.modifiedDate.formatted(date: .abbreviated, time: .shortened))\n"
            if !note.tags.isEmpty {
                block += "TAGS: \(note.tags.joined(separator: ", "))\n"
            }
            // Truncate long notes to ~2000 chars to stay within token budget
            let content = note.content.prefix(2000)
            block += "CONTENT:\n\(content)"
            noteBlocks.append(block)
        }
        let notesText = noteBlocks.isEmpty ? "" : "\n\nNOTES:\n" + noteBlocks.joined(separator: "\n\n---\n\n")

        // Build todo blocks — these are the primary source for T5T per the web app
        var todoBlocks: [String] = []
        for todo in todos {
            var block = "- "
            block += todo.completed ? "[DONE] " : "[OPEN] "
            block += todo.title
            if let due = todo.dueDate {
                let dueFmt = DateFormatter()
                dueFmt.dateStyle = .medium
                block += " (due \(dueFmt.string(from: due)))"
            }
            if !todo.description.isEmpty {
                block += "\n  " + String(todo.description.prefix(400))
            }
            todoBlocks.append(block)
        }
        let todosText = todoBlocks.isEmpty ? "" : "\n\nTODOS:\n" + todoBlocks.joined(separator: "\n")

        let prompt = """
        You are an NVIDIA engineer's executive communication assistant. Generate a "Top 5 Things" (T5T) status report from the meeting notes below.

        T5T FORMAT RULES (from Jensen Huang):
        - T5T is NVIDIA's internal bi-weekly status report read by leadership including Jensen
        - It must be plain spoken, using "newspaper-style headlines" — verb-driven action phrases, not just nouns
        - Each entry has a BOLD HEADLINE (action-oriented, e.g. "Enabled Crusoe to Onboard and Benchmark Nemotron") followed by a 2-3 sentence explanation paragraph
        - Total output should be half to one page when read on a phone
        - Focus on top priorities being actively worked on — this is a "priority list", NOT a "to-do list"
        - Include: workload context, usage descriptions, acceleration libraries or tools used, teams driving the work
        - Share insights, what worked and what didn't, changes in strategy or direction
        - Do NOT cut-and-paste or repeat items — synthesize across meetings

        THREE SECTIONS (omit any section with no relevant content — return empty array):

        1. "insights" — Insights, Management Escalations & Help Needed, Market & Competition
           Relevant competitive product info, strategic changes, threats or opportunities, escalations

        2. "accountUpdates" — Industry Business Development / Account Updates
           Work on business development, ecosystem building, account/partner engagement
           Include account/partner name, project status, key wins/losses & why

        3. "futurePlans" — Future Plans
           What you plan to accomplish in the next weeks, your priorities

        ENGINEER'S ROLE:
        \(config.vertical) | \(config.region) | \(config.jobFunction)

        REPORTING PERIOD: \(dateFmt.string(from: periodStart)) to \(dateFmt.string(from: periodEnd))

        MEETING SUMMARIES:
        \(meetingsText)
        \(notesText)
        \(todosText)

        OUTPUT: Valid JSON only, with this exact structure:
        {
          "insights": [{"headline": "...", "explanation": "..."}],
          "accountUpdates": [{"headline": "...", "explanation": "..."}],
          "futurePlans": [{"headline": "...", "explanation": "..."}]
        }

        Aim for 3-5 total entries across all sections. Quality over quantity. Omit a section (empty array) if no meeting content maps to it.
        """

        let responseText = try await client.complete(prompt: prompt, model: model)
        return try AITasks.parseT5TSections(responseText)
    }

    // MARK: - Helpers

    private func formatSummaryForPrompt(_ summary: MeetingSummary) -> String {
        AITasks.formatSummaryForPrompt(summary)
    }

    // MARK: - Response parsing

    private func parseSummary(from text: String) throws -> MeetingSummary {
        try AITasks.parseMeetingSummary(text)
    }

    private func extractJSON(from text: String) -> String {
        AITasks.extractJSON(from: text)
    }
}

enum SummarizationError: LocalizedError {
    case noAPIKey
    case apiError(statusCode: Int, message: String)
    case parseError
    case invalidURL(String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "No API key configured. Set it in Settings or via the appropriate environment variable."
        case .apiError(let code, let message):
            return "API error (\(code)): \(message)"
        case .parseError:
            return "Failed to parse summary from LLM response"
        case .invalidURL(let url):
            return "Invalid API URL: \(url)"
        }
    }
}
