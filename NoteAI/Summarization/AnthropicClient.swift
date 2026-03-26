import Foundation

/// Client for the Anthropic Messages API (native format).
struct AnthropicClient: LLMClient {
    let apiKey: String

    func complete(prompt: String, model: String) async throws -> String {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw SummarizationError.invalidURL("https://api.anthropic.com/v1/messages")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

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

        // Parse Anthropic response format
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let content = json?["content"] as? [[String: Any]]
        let text = content?.first?["text"] as? String ?? ""

        return text
    }

    func chat(messages: [(role: String, content: String)], model: String) async throws -> String {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw SummarizationError.invalidURL("https://api.anthropic.com/v1/messages")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        // Anthropic requires system message separate from messages array
        let systemMsg = messages.first(where: { $0.role == "system" })?.content
        let chatMessages = messages.filter { $0.role != "system" }.map { ["role": $0.role, "content": $0.content] }

        var body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "messages": chatMessages
        ]
        if let system = systemMsg {
            body["system"] = system
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw SummarizationError.apiError(statusCode: code, message: body)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let content = json?["content"] as? [[String: Any]]
        return content?.first?["text"] as? String ?? ""
    }
}
