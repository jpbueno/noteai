import Foundation

/// Client for the OpenRouter API (OpenAI-compatible chat completions format).
/// Also used for direct OpenAI API calls since the format is identical.
struct OpenRouterClient: LLMClient {
    let apiKey: String
    let baseURL: String
    let appName: String
    let siteURL: String

    init(
        apiKey: String,
        baseURL: String = "https://openrouter.ai/api/v1/chat/completions",
        appName: String = "NoteAI",
        siteURL: String = "https://noteai.app"
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.appName = appName
        self.siteURL = siteURL
    }

    func complete(prompt: String, model: String) async throws -> String {
        guard let url = URL(string: baseURL) else {
            throw SummarizationError.invalidURL(baseURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        // OpenRouter-specific headers (ignored by OpenAI)
        request.setValue(appName, forHTTPHeaderField: "X-Title")
        request.setValue(siteURL, forHTTPHeaderField: "HTTP-Referer")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SummarizationError.apiError(statusCode: 0, message: "No HTTP response")
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SummarizationError.apiError(statusCode: httpResponse.statusCode, message: body)
        }

        return try Self.responseText(from: data)
    }

    func chat(messages: [(role: String, content: String)], model: String) async throws -> String {
        guard let url = URL(string: baseURL) else {
            throw SummarizationError.invalidURL(baseURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(appName, forHTTPHeaderField: "X-Title")
        request.setValue(siteURL, forHTTPHeaderField: "HTTP-Referer")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "messages": messages.map { ["role": $0.role, "content": $0.content] }
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw SummarizationError.apiError(statusCode: code, message: body)
        }

        return try Self.responseText(from: data)
    }

    static func responseText(from data: Data) throws -> String {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let choices = json?["choices"] as? [[String: Any]]
        let finishReason = choices?.first?["finish_reason"] as? String
        if finishReason == "length" || finishReason == "max_tokens" {
            throw SummarizationError.responseTruncated
        }
        let message = choices?.first?["message"] as? [String: Any]
        return message?["content"] as? String ?? ""
    }
}
