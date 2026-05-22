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

    func regenerateSection(_ section: MeetingSummarySection, meeting: Meeting) async throws -> MeetingSummarySectionContent {
        let client = try buildClient()
        let model = selectedModelID()
        let prompt = buildSectionPrompt(section: section, meeting: meeting)
        let responseText = try await client.complete(prompt: prompt, model: model)
        return try AITasks.parseMeetingSummarySection(responseText, section: section)
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

    private func buildSectionPrompt(section: MeetingSummarySection, meeting: Meeting) -> String {
        let transcriptText = MeetingCaptureWorkflow.transcriptText(from: meeting.transcript)
        let currentSummary = AITasks.formatSummaryForPrompt(meeting.summary)

        return """
        You are a meeting summarization assistant. Regenerate only the "\(section.title)" section for the meeting below.

        Preserve the same semantic shape as the existing structured summary. Do not rewrite, mention, or include any other summary section.
        For action items, include concrete follow-ups only, with optional owner and deadline when present.

        Output ONLY valid JSON with this exact structure:
        \(section.jsonStructure)

        MEETING: \(meeting.title)
        DATE: \(meeting.date.formatted(date: .long, time: .shortened))

        CURRENT SUMMARY CONTEXT:
        \(currentSummary)

        TRANSCRIPT:
        \(transcriptText)
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

    /// Generates a T5T (Top 5 Things) report from durable task records in a reporting period.
    func generateT5T(meetings: [Meeting], notes: [Note] = [], tasks: [TaskItem] = [], config: T5TConfig, periodStart: Date, periodEnd: Date) async throws -> T5TSections {
        let client = try buildClient()
        let model = selectedModelID()
        let prompt = T5TPrompt.buildPrompt(
            tasks: tasks,
            config: config,
            periodStart: periodStart,
            periodEnd: periodEnd
        )

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
