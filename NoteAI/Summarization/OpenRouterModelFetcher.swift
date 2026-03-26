import Foundation

/// Fetches the live model list from the OpenRouter API.
final class OpenRouterModelFetcher {
    struct ModelListResponse: Decodable {
        let data: [RemoteModel]
    }

    struct RemoteModel: Decodable {
        let id: String
        let name: String
        let context_length: Int?
        let pricing: Pricing?

        struct Pricing: Decodable {
            let prompt: String? // cost per token as string
            let completion: String?
        }
    }

    /// Fetches all available models from OpenRouter. No API key required.
    static func fetchModels() async throws -> [LLMModel] {
        guard let url = URL(string: "https://openrouter.ai/api/v1/models") else {
            return []
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return []
        }

        let decoded = try JSONDecoder().decode(ModelListResponse.self, from: data)

        return decoded.data.map { remote in
            let inputCost = (Double(remote.pricing?.prompt ?? "0") ?? 0) * 1_000_000
            let outputCost = (Double(remote.pricing?.completion ?? "0") ?? 0) * 1_000_000

            return LLMModel(
                id: remote.id,
                name: remote.name,
                provider: .openRouter,
                contextWindow: remote.context_length,
                costPer1MInput: inputCost,
                costPer1MOutput: outputCost
            )
        }
    }
}
