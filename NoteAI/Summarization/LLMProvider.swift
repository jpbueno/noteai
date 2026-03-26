import Foundation

/// Represents an LLM provider that NoteAI can route summarization requests through.
enum LLMProviderType: String, CaseIterable, Identifiable, Codable {
    case openRouter = "openrouter"
    case anthropic = "anthropic"
    case openAI = "openai"
    case nvidia = "nvidia"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openRouter: return "OpenRouter"
        case .anthropic: return "Anthropic"
        case .openAI: return "OpenAI"
        case .nvidia: return "NVIDIA Inference"
        }
    }

    var baseURL: String {
        switch self {
        case .openRouter: return "https://openrouter.ai/api/v1/chat/completions"
        case .anthropic: return "https://api.anthropic.com/v1/messages"
        case .openAI: return "https://api.openai.com/v1/chat/completions"
        case .nvidia: return "https://inference-api.nvidia.com/v1/chat/completions"
        }
    }

    var envKeyName: String {
        switch self {
        case .openRouter: return "OPENROUTER_API_KEY"
        case .anthropic: return "ANTHROPIC_API_KEY"
        case .openAI: return "OPENAI_API_KEY"
        case .nvidia: return "NVIDIA_API_KEY"
        }
    }

    /// Whether this provider uses the OpenAI-compatible chat completions format.
    var usesOpenAIFormat: Bool {
        switch self {
        case .openRouter, .openAI, .nvidia: return true
        case .anthropic: return false
        }
    }
}

/// A model available through a provider.
struct LLMModel: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let provider: LLMProviderType
    let contextWindow: Int?
    let costPer1MInput: Double? // USD per 1M tokens
    let costPer1MOutput: Double?

    var displayName: String {
        if provider == .openRouter || provider == .nvidia {
            return name.isEmpty ? id : name
        }
        return name
    }
}

/// Protocol for LLM API clients.
protocol LLMClient {
    func complete(prompt: String, model: String) async throws -> String
    func chat(messages: [(role: String, content: String)], model: String) async throws -> String
}

extension LLMClient {
    // Default chat implementation using complete() for backward compatibility
    func chat(messages: [(role: String, content: String)], model: String) async throws -> String {
        let prompt = messages.map { "\($0.role): \($0.content)" }.joined(separator: "\n")
        return try await complete(prompt: prompt, model: model)
    }
}

/// Curated list of popular models available via OpenRouter.
enum OpenRouterModels {
    static let popular: [LLMModel] = [
        // Anthropic
        LLMModel(id: "anthropic/claude-sonnet-4", name: "Claude Sonnet 4", provider: .openRouter, contextWindow: 200_000, costPer1MInput: 3.0, costPer1MOutput: 15.0),
        LLMModel(id: "anthropic/claude-3.5-haiku", name: "Claude 3.5 Haiku", provider: .openRouter, contextWindow: 200_000, costPer1MInput: 0.80, costPer1MOutput: 4.0),
        // OpenAI
        LLMModel(id: "openai/gpt-4o", name: "GPT-4o", provider: .openRouter, contextWindow: 128_000, costPer1MInput: 2.50, costPer1MOutput: 10.0),
        LLMModel(id: "openai/gpt-4o-mini", name: "GPT-4o Mini", provider: .openRouter, contextWindow: 128_000, costPer1MInput: 0.15, costPer1MOutput: 0.60),
        LLMModel(id: "openai/o3-mini", name: "o3-mini", provider: .openRouter, contextWindow: 200_000, costPer1MInput: 1.10, costPer1MOutput: 4.40),
        // Google
        LLMModel(id: "google/gemini-2.5-pro-preview", name: "Gemini 2.5 Pro", provider: .openRouter, contextWindow: 1_000_000, costPer1MInput: 1.25, costPer1MOutput: 10.0),
        LLMModel(id: "google/gemini-2.5-flash-preview", name: "Gemini 2.5 Flash", provider: .openRouter, contextWindow: 1_000_000, costPer1MInput: 0.15, costPer1MOutput: 0.60),
        // Meta
        LLMModel(id: "meta-llama/llama-4-maverick", name: "Llama 4 Maverick", provider: .openRouter, contextWindow: 1_000_000, costPer1MInput: 0.20, costPer1MOutput: 0.60),
        LLMModel(id: "meta-llama/llama-4-scout", name: "Llama 4 Scout", provider: .openRouter, contextWindow: 512_000, costPer1MInput: 0.10, costPer1MOutput: 0.30),
        // Mistral
        LLMModel(id: "mistralai/mistral-large-2", name: "Mistral Large 2", provider: .openRouter, contextWindow: 128_000, costPer1MInput: 2.0, costPer1MOutput: 6.0),
        LLMModel(id: "mistralai/mistral-small-3.2", name: "Mistral Small 3.2", provider: .openRouter, contextWindow: 128_000, costPer1MInput: 0.10, costPer1MOutput: 0.30),
        // DeepSeek
        LLMModel(id: "deepseek/deepseek-chat-v3", name: "DeepSeek V3", provider: .openRouter, contextWindow: 128_000, costPer1MInput: 0.30, costPer1MOutput: 0.88),
        LLMModel(id: "deepseek/deepseek-r1", name: "DeepSeek R1", provider: .openRouter, contextWindow: 128_000, costPer1MInput: 0.55, costPer1MOutput: 2.19),
        // Qwen
        LLMModel(id: "qwen/qwen-2.5-72b-instruct", name: "Qwen 2.5 72B", provider: .openRouter, contextWindow: 131_072, costPer1MInput: 0.36, costPer1MOutput: 0.40),
    ]

    /// Models available for direct Anthropic API
    static let anthropicDirect: [LLMModel] = [
        LLMModel(id: "claude-sonnet-4-20250514", name: "Claude Sonnet 4", provider: .anthropic, contextWindow: 200_000, costPer1MInput: 3.0, costPer1MOutput: 15.0),
        LLMModel(id: "claude-haiku-4-5-20251001", name: "Claude 3.5 Haiku", provider: .anthropic, contextWindow: 200_000, costPer1MInput: 0.80, costPer1MOutput: 4.0),
    ]

    /// Models available for direct OpenAI API
    static let openAIDirect: [LLMModel] = [
        LLMModel(id: "gpt-4o", name: "GPT-4o", provider: .openAI, contextWindow: 128_000, costPer1MInput: 2.50, costPer1MOutput: 10.0),
        LLMModel(id: "gpt-4o-mini", name: "GPT-4o Mini", provider: .openAI, contextWindow: 128_000, costPer1MInput: 0.15, costPer1MOutput: 0.60),
    ]

    /// Models available via NVIDIA Enterprise Inference Hub (inference-api.nvidia.com)
    static let nvidiaNIM: [LLMModel] = [
        // Anthropic (via Azure/AWS)
        LLMModel(id: "azure/anthropic/claude-opus-4-6", name: "Claude Opus 4.6", provider: .nvidia, contextWindow: 200_000, costPer1MInput: nil, costPer1MOutput: nil),
        LLMModel(id: "azure/anthropic/claude-sonnet-4-6", name: "Claude Sonnet 4.6", provider: .nvidia, contextWindow: 200_000, costPer1MInput: nil, costPer1MOutput: nil),
        LLMModel(id: "azure/anthropic/claude-opus-4-5", name: "Claude Opus 4.5", provider: .nvidia, contextWindow: 200_000, costPer1MInput: nil, costPer1MOutput: nil),
        LLMModel(id: "azure/anthropic/claude-sonnet-4-5", name: "Claude Sonnet 4.5", provider: .nvidia, contextWindow: 200_000, costPer1MInput: nil, costPer1MOutput: nil),
        LLMModel(id: "azure/anthropic/claude-haiku-4-5", name: "Claude Haiku 4.5", provider: .nvidia, contextWindow: 200_000, costPer1MInput: nil, costPer1MOutput: nil),
        // NVIDIA
        LLMModel(id: "nvcf/nvidia/llama-3.3-nemotron-super-49b-v1.5", name: "Nemotron Super 49B v1.5", provider: .nvidia, contextWindow: 128_000, costPer1MInput: nil, costPer1MOutput: nil),
        LLMModel(id: "nvcf/nvidia/llama-3.3-nemotron-super-49b-v1", name: "Nemotron Super 49B", provider: .nvidia, contextWindow: 128_000, costPer1MInput: nil, costPer1MOutput: nil),
        // Meta
        LLMModel(id: "nvcf/meta/llama-3.3-70b-instruct", name: "Llama 3.3 70B", provider: .nvidia, contextWindow: 128_000, costPer1MInput: nil, costPer1MOutput: nil),
        LLMModel(id: "nvcf/meta/llama-3.1-70b-instruct", name: "Llama 3.1 70B", provider: .nvidia, contextWindow: 128_000, costPer1MInput: nil, costPer1MOutput: nil),
        // OpenAI
        LLMModel(id: "nvcf/openai/gpt-oss-120b", name: "GPT OSS 120B", provider: .nvidia, contextWindow: 128_000, costPer1MInput: nil, costPer1MOutput: nil),
        // Qwen
        LLMModel(id: "nvidia/qwen/qwen3-next-80b-a3b-instruct", name: "Qwen 3 Next 80B", provider: .nvidia, contextWindow: 128_000, costPer1MInput: nil, costPer1MOutput: nil),
    ]

    static func models(for provider: LLMProviderType) -> [LLMModel] {
        switch provider {
        case .openRouter: return popular
        case .anthropic: return anthropicDirect
        case .openAI: return openAIDirect
        case .nvidia: return nvidiaNIM
        }
    }
}
