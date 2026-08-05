import Foundation

/// Generates structured meeting summaries by routing to the user's chosen LLM provider/model.
/// Supports OpenRouter (100+ models), Anthropic direct, and OpenAI direct.
final class SummarizationEngine {
    private let requestContextOverride: LLMRequestContext?
    private let templateOverride: MeetingTemplate?

    init() {
        requestContextOverride = nil
        templateOverride = nil
    }

    init(
        client: LLMClient,
        provider: LLMProviderType,
        model: String,
        template: MeetingTemplate = .auto
    ) {
        requestContextOverride = LLMRequestContext(provider: provider, model: model, client: client)
        templateOverride = template
    }

    func summarize(transcript: String) async throws -> MeetingSummary {
        let request = try buildRequestContext()
        let template = selectedTemplate()
        let prompt = buildPrompt(transcript: transcript, template: template)

        do {
            let responseText = try await complete(prompt: prompt, context: request)
            return try AITasks.parseMeetingSummary(responseText)
        } catch {
            guard shouldRecoverStructuredSummary(from: error) else {
                throw error
            }
        }

        let recoveryPrompt = buildRecoveryPrompt(transcript: transcript, template: template)
        do {
            let responseText = try await complete(prompt: recoveryPrompt, context: request)
            return try AITasks.parseMeetingSummary(responseText)
        } catch {
            guard shouldRecoverStructuredSummary(from: error) else {
                throw error
            }
            throw SummarizationError.parseError
        }
    }

    func regenerateSection(_ section: MeetingSummarySection, meeting: Meeting) async throws -> MeetingSummarySectionContent {
        let request = try buildRequestContext()
        let prompt = buildSectionPrompt(section: section, meeting: meeting)
        let responseText = try await complete(prompt: prompt, context: request)
        return try AITasks.parseMeetingSummarySection(responseText, section: section)
    }

    /// Generates a follow-up email draft based on a meeting's transcript and summary.
    func draftFollowUp(meeting: Meeting) async throws -> String {
        let request = try buildRequestContext()

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
        \(MeetingCaptureWorkflow.transcriptText(
            from: Array(meeting.transcript.prefix(60)),
            speakerLabels: meeting.speakerLabels,
            speakerProfiles: meeting.speakerProfiles
        ))
        """

        return try await complete(prompt: prompt, context: request)
    }

    // MARK: - Client construction

    private struct LLMRequestContext {
        let provider: LLMProviderType
        let model: String
        let client: LLMClient
    }

    private func buildRequestContext() throws -> LLMRequestContext {
        if let requestContextOverride {
            return requestContextOverride
        }

        let provider = selectedProvider()
        let model = selectedModelID()
        let apiKey = resolveAPIKey(for: provider)

        guard !apiKey.isEmpty else {
            throw SummarizationError.noAPIKey
        }

        let client: LLMClient
        switch provider {
        case .openRouter:
            client = OpenRouterClient(apiKey: apiKey)
        case .anthropic:
            client = AnthropicClient(apiKey: apiKey)
        case .openAI:
            client = OpenRouterClient(apiKey: apiKey, baseURL: LLMProviderType.openAI.baseURL)
        case .nvidia:
            client = OpenRouterClient(apiKey: apiKey, baseURL: LLMProviderType.nvidia.baseURL)
        }
        return LLMRequestContext(provider: provider, model: model, client: client)
    }

    private func complete(prompt: String, context: LLMRequestContext) async throws -> String {
        let models = LLMFallbackPolicy.candidateModels(provider: context.provider, primaryModel: context.model)
        var lastError: Error?

        for (index, model) in models.enumerated() {
            do {
                return try await context.client.complete(prompt: prompt, model: model)
            } catch {
                lastError = error
                let hasFallback = index < models.count - 1
                guard hasFallback, LLMFallbackPolicy.shouldRetry(error, provider: context.provider) else {
                    throw error
                }
                print("[SummarizationEngine] \(context.provider.displayName) model \(model) failed with retryable error: \(error.localizedDescription). Trying \(models[index + 1]).")
            }
        }

        throw lastError ?? SummarizationError.apiError(statusCode: 0, message: "No model response")
    }

    private func chat(messages: [(role: String, content: String)], context: LLMRequestContext) async throws -> String {
        let models = LLMFallbackPolicy.candidateModels(provider: context.provider, primaryModel: context.model)
        var lastError: Error?

        for (index, model) in models.enumerated() {
            do {
                return try await context.client.chat(messages: messages, model: model)
            } catch {
                lastError = error
                let hasFallback = index < models.count - 1
                guard hasFallback, LLMFallbackPolicy.shouldRetry(error, provider: context.provider) else {
                    throw error
                }
                print("[SummarizationEngine] \(context.provider.displayName) chat model \(model) failed with retryable error: \(error.localizedDescription). Trying \(models[index + 1]).")
            }
        }

        throw lastError ?? SummarizationError.apiError(statusCode: 0, message: "No chat response")
    }

    private func selectedProvider() -> LLMProviderType {
        let raw = UserDefaults.standard.string(forKey: "llmProvider") ?? "openrouter"
        return LLMProviderType(rawValue: raw) ?? .openRouter
    }

    private func selectedModelID() -> String {
        UserDefaults.standard.string(forKey: "llmModel") ?? "deepseek/deepseek-chat-v3"
    }

    private func selectedTemplate() -> MeetingTemplate {
        if let templateOverride {
            return templateOverride
        }

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

        Keep the response concise so the JSON is complete:
        - At most 5 decisions, 8 action items, 8 topics, and 5 open questions
        - Keep every string under 160 characters
        - Use empty arrays when a section does not apply
        - Do not quote long passages from the transcript

        Output ONLY valid JSON with this exact structure:
        \(template.jsonStructure)

        TRANSCRIPT:
        \(transcript)
        """
    }

    private func buildRecoveryPrompt(transcript: String, template: MeetingTemplate) -> String {
        """
        RECOVERY ATTEMPT: The previous structured summary was incomplete or invalid.

        Summarize the meeting again in an extra-compact form. \(template.promptInstruction)
        - At most 4 decisions, 6 action items, 6 topics, and 4 open questions
        - Keep every string under 120 characters
        - Use empty arrays when a section does not apply
        - Do not include commentary, Markdown, code fences, or transcript quotations

        Output ONLY one complete valid JSON object with this exact structure:
        \(template.jsonStructure)

        TRANSCRIPT:
        \(transcript)
        """
    }

    private func shouldRecoverStructuredSummary(from error: Error) -> Bool {
        guard let summarizationError = error as? SummarizationError else {
            return error is DecodingError
        }

        if case .parseError = summarizationError {
            return true
        }
        if case .responseTruncated = summarizationError {
            return true
        }
        return false
    }

    private func buildSectionPrompt(section: MeetingSummarySection, meeting: Meeting) -> String {
        let transcriptText = MeetingCaptureWorkflow.summaryInput(
            from: meeting.transcript,
            speakerLabels: meeting.speakerLabels,
            speakerProfiles: meeting.speakerProfiles
        )
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
        let request = try buildRequestContext()
        return try await chat(messages: messages, context: request)
    }

    // MARK: - T5T Generation

    /// Generates a T5T (Top 5 Things) report from durable task records in a reporting period.
    func generateT5T(meetings: [Meeting], notes: [Note] = [], tasks: [TaskItem] = [], config: T5TConfig, periodStart: Date, periodEnd: Date) async throws -> T5TSections {
        let request = try buildRequestContext()
        let prompt = T5TPrompt.buildPrompt(
            tasks: tasks,
            config: config,
            periodStart: periodStart,
            periodEnd: periodEnd
        )

        let responseText = try await complete(prompt: prompt, context: request)
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
    case responseTruncated
    case invalidURL(String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "No API key configured. Set it in Settings or via the appropriate environment variable."
        case .apiError(let code, let message):
            return "API error (\(code)): \(SummarizationError.readableAPIMessage(from: message))"
        case .parseError:
            return "The model returned an incomplete or invalid summary. NoteAI retried once, but could not decode it."
        case .responseTruncated:
            return "The model stopped before completing the summary response."
        case .invalidURL(let url):
            return "Invalid API URL: \(url)"
        }
    }

    var statusCode: Int? {
        if case .apiError(let code, _) = self { return code }
        return nil
    }

    var apiMessage: String? {
        if case .apiError(_, let message) = self { return message }
        return nil
    }

    static func readableAPIMessage(from message: String) -> String {
        guard let data = message.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return message
        }

        if let detail = root["detail"] as? String { return detail }
        if let message = root["message"] as? String { return message }
        if let error = root["error"] as? String { return error }
        if let error = root["error"] as? [String: Any] {
            if let message = error["message"] as? String { return message }
            if let detail = error["detail"] as? String { return detail }
        }
        return message
    }
}

enum LLMFallbackPolicy {
    static let nvidiaOpus47 = "aws/anthropic/bedrock-claude-opus-4-7"
    static let nvidiaOpus46 = "azure/anthropic/claude-opus-4-6"
    static let nvidiaNemotronSuper = "nvcf/nvidia/llama-3.3-nemotron-super-49b-v1.5"

    static func candidateModels(provider: LLMProviderType, primaryModel: String) -> [String] {
        guard provider == .nvidia else { return [primaryModel] }

        let fallbacks: [String]
        if primaryModel == nvidiaOpus47 {
            fallbacks = [nvidiaOpus46, nvidiaNemotronSuper]
        } else {
            fallbacks = [nvidiaNemotronSuper]
        }

        return ([primaryModel] + fallbacks).reduce(into: [String]()) { models, model in
            if !models.contains(model) {
                models.append(model)
            }
        }
    }

    static func shouldRetry(_ error: Error, provider: LLMProviderType) -> Bool {
        guard provider == .nvidia else { return false }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return [
                NSURLErrorTimedOut,
                NSURLErrorCannotFindHost,
                NSURLErrorCannotConnectToHost,
                NSURLErrorNetworkConnectionLost,
                NSURLErrorDNSLookupFailed,
                NSURLErrorNotConnectedToInternet,
            ].contains(nsError.code)
        }

        guard let summaryError = error as? SummarizationError,
              case .apiError(let statusCode, let rawMessage) = summaryError else {
            return false
        }

        if [429, 500, 502, 503, 504].contains(statusCode) {
            return true
        }

        let message = SummarizationError.readableAPIMessage(from: rawMessage).lowercased()
        return message.contains("serviceunavailable")
            || message.contains("service unavailable")
            || message.contains("bedrock is unable")
            || message.contains("temporarily unavailable")
            || message.contains("overloaded")
            || message.contains("rate limit")
    }
}
