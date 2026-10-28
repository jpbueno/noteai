import Foundation
import AVFoundation
import Combine

/// A speech credential stays paired with its endpoint and specialized voice model.
struct SpeechConnection {
    let provider: LLMProviderType
    let apiKey: String

    var endpoint: URL {
        URL(string: provider == .nvidia
            ? "https://inference-api.nvidia.com/v1/audio/speech"
            : "https://api.openai.com/v1/audio/speech")!
    }

    var model: String {
        provider == .nvidia ? "openai/openai/gpt-4o-mini-tts" : "gpt-4o-mini-tts"
    }

    static func resolve(
        selectedProvider: LLMProviderType, ttsKey: String, nvidiaKey: String, openAIKey: String
    ) -> SpeechConnection? {
        let dedicated = ttsKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let nvidia = nvidiaKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let openAI = openAIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !dedicated.isEmpty { return SpeechConnection(provider: .openAI, apiKey: dedicated) }
        if selectedProvider == .openAI, !openAI.isEmpty {
            return SpeechConnection(provider: .openAI, apiKey: openAI)
        }
        if !nvidia.isEmpty { return SpeechConnection(provider: .nvidia, apiKey: nvidia) }
        if !openAI.isEmpty { return SpeechConnection(provider: .openAI, apiKey: openAI) }
        return nil
    }

    static func current() -> SpeechConnection? {
        // Speech must not reuse a legacy generic credential belonging to another provider.
        func key(for provider: LLMProviderType) -> String {
            let saved = APIKeyStore.load(for: provider)
            return saved.isEmpty ? ProcessInfo.processInfo.environment[provider.envKeyName] ?? "" : saved
        }
        return resolve(
            selectedProvider: LLMSelection.current().provider,
            ttsKey: TextToSpeechService.loadTTSKey(),
            nvidiaKey: key(for: .nvidia), openAIKey: key(for: .openAI)
        )
    }
}

/// Playback is the hardware Seam; AVAudioPlayer is the production Adapter.
@MainActor
protocol SpeechPlayback: AnyObject {
    var isPlaying: Bool { get }
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }
    func play() -> Bool
    func pause()
    func stop()
}

extension AVAudioPlayer: SpeechPlayback {}

/// Reads the entire input through the configured speech connection, one part at a time.
@MainActor
final class TextToSpeechService: ObservableObject {
    enum PlaybackState: Equatable {
        case idle
        case loading
        case playing
        case paused
    }

    @Published var state: PlaybackState = .idle
    @Published var error: String?
    @Published var progress: Double = 0

    private let connectionProvider: () -> SpeechConnection?
    private let voiceProvider: () -> String
    private let loadAudio: (URLRequest) async throws -> (Data, URLResponse)
    private let makePlayer: (Data) throws -> SpeechPlayback
    private var player: SpeechPlayback?
    private var progressTimer: Timer?
    private var currentTask: Task<Void, Never>?
    private var operationID = UUID()
    private var chunks: [String] = []
    private var chunkIndex = 0
    private var completedBytes = 0
    private var totalBytes = 0
    private var activeConnection: SpeechConnection?
    private var activeVoice: String?

    private static let maximumChunkUTF8Bytes = 1800
    static let voices = ["alloy", "ash", "coral", "echo", "fable", "nova", "onyx", "sage", "shimmer"]

    init(
        connectionProvider: @escaping () -> SpeechConnection? = SpeechConnection.current,
        voiceProvider: @escaping () -> String = { UserDefaults.standard.string(forKey: "ttsVoice") ?? "nova" },
        loadAudio: ((URLRequest) async throws -> (Data, URLResponse))? = nil,
        makePlayer: @escaping (Data) throws -> SpeechPlayback = { data in
            let player = try AVAudioPlayer(data: data, fileTypeHint: AVFileType.mp3.rawValue)
            player.prepareToPlay()
            return player
        }
    ) {
        self.connectionProvider = connectionProvider
        self.voiceProvider = voiceProvider
        self.makePlayer = makePlayer
        if let loadAudio {
            self.loadAudio = loadAudio
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: configuration)
            self.loadAudio = { request in try await session.data(for: request) }
        }
    }

    var selectedVoice: String { activeVoice ?? voiceProvider() }

    var connectionDescription: String {
        guard let connection = activeConnection ?? connectionProvider() else {
            return "Add an NVIDIA or OpenAI speech key in Settings > AI."
        }
        return "\(connection.provider.displayName) · \(connection.model)"
    }

    func speak(_ text: String) {
        stop()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let connection = connectionProvider() else {
            error = "No speech API key configured. Set an NVIDIA or OpenAI key in Settings > AI."
            return
        }

        activeConnection = connection
        let voice = voiceProvider()
        activeVoice = Self.voices.contains(voice) ? voice : "nova"
        totalBytes = text.utf8.count
        // The voice model accepts at most 2,000 input tokens. A conservative UTF-8
        // byte ceiling avoids exceeding it without a model-specific tokenizer.
        // Scalar boundaries preserve even a single grapheme larger than a part.
        let scalars = text.unicodeScalars
        var start = scalars.startIndex
        while start < scalars.endIndex {
            var end = start
            var byteCount = 0
            var lastWhitespace: String.UnicodeScalarView.Index?
            var containsSpokenText = false
            while end < scalars.endIndex {
                let scalar = scalars[end]
                let scalarBytes = scalar.utf8.count
                guard byteCount + scalarBytes <= Self.maximumChunkUTF8Bytes else { break }
                byteCount += scalarBytes
                end = scalars.index(after: end)
                if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    if containsSpokenText { lastWhitespace = end }
                } else {
                    containsSpokenText = true
                }
            }
            if end < scalars.endIndex, let lastWhitespace { end = lastWhitespace }
            chunks.append(String(scalars[start..<end]))
            start = end
        }
        loadNextChunk(operation: operationID)
    }

    func togglePlayPause() {
        guard let player else { return }
        if state == .playing {
            player.pause()
            state = .paused
        } else if state == .paused {
            guard player.play() else {
                fail("Unable to resume audio playback.")
                return
            }
            state = .playing
        }
    }

    func stop() {
        operationID = UUID()
        currentTask?.cancel()
        currentTask = nil
        player?.stop()
        player = nil
        progressTimer?.invalidate()
        progressTimer = nil
        chunks.removeAll()
        chunkIndex = 0
        completedBytes = 0
        totalBytes = 0
        activeConnection = nil
        activeVoice = nil
        state = .idle
        progress = 0
        error = nil
    }

    private func loadNextChunk(operation: UUID) {
        guard operation == operationID, let connection = activeConnection else { return }
        // Blank-only parts represent silence. Advance them without sending an
        // empty speech request; preserve every scalar in parts containing text.
        while chunkIndex < chunks.count,
              chunks[chunkIndex].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            completedBytes += chunks[chunkIndex].utf8.count
            chunkIndex += 1
        }
        guard chunkIndex < chunks.count else {
            stop()
            return
        }
        progress = Double(completedBytes) / Double(totalBytes)
        state = .loading
        var request = URLRequest(url: connection.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(connection.apiKey)", forHTTPHeaderField: "Authorization")
        let body = ["model": connection.model, "input": chunks[chunkIndex], "voice": selectedVoice, "response_format": "mp3"]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (data, response) = try await loadAudio(request)
                guard operation == operationID, !Task.isCancelled else { return }
                currentTask = nil
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 200 else {
                    fail("Speech request failed (HTTP \(code)). Check your speech connection in Settings > AI.")
                    return
                }
                let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
                guard !data.isEmpty, !contentType.contains("json"), !contentType.contains("text/") else {
                    fail("The speech connection returned no playable audio.")
                    return
                }
                let audio = try makePlayer(data)
                guard audio.play() else {
                    fail("Unable to start audio playback.")
                    return
                }
                player = audio
                state = .playing
                startProgressTimer(operation: operation)
            } catch {
                guard operation == operationID, !Task.isCancelled else { return }
                fail("Unable to generate speech. Check your connection and speech settings, then try again.")
            }
        }
    }

    private func startProgressTimer(operation: UUID) {
        progressTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateProgress(operation: operation) }
        }
        progressTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updateProgress(operation: UUID) {
        guard operation == operationID, state == .playing, let player else { return }
        let partLength = chunks[chunkIndex].utf8.count
        if player.isPlaying {
            let fraction = player.duration > 0 ? min(1, max(0, player.currentTime / player.duration)) : 0
            progress = (Double(completedBytes) + fraction * Double(partLength)) / Double(totalBytes)
        } else {
            completedBytes += partLength
            chunkIndex += 1
            progress = Double(completedBytes) / Double(totalBytes)
            progressTimer?.invalidate()
            progressTimer = nil
            self.player = nil
            if chunkIndex < chunks.count {
                loadNextChunk(operation: operation)
            } else {
                stop()
            }
        }
    }

    private func fail(_ message: String) {
        stop()
        error = message
    }

    static func saveTTSKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainHelper.delete(key: "apiKey_tts")
        } else {
            KeychainHelper.save(key: "apiKey_tts", value: trimmed)
        }
    }

    nonisolated static func loadTTSKey() -> String {
        KeychainHelper.load(key: "apiKey_tts") ?? ""
    }
}
