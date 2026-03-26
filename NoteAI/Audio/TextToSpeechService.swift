import Foundation
import AVFoundation

/// Sends text to OpenAI's TTS endpoint and plays the returned MP3 audio.
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

    private var player: AVAudioPlayer?
    private var progressTimer: Timer?
    private var currentTask: URLSessionDataTask?

    static let voices = ["alloy", "ash", "coral", "echo", "fable", "nova", "onyx", "sage", "shimmer"]

    var selectedVoice: String {
        UserDefaults.standard.string(forKey: "ttsVoice") ?? "nova"
    }

    func speak(_ text: String) {
        stop()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let apiKey = resolveAPIKey()
        guard !apiKey.isEmpty else {
            error = "No API key configured. Set an OpenAI or NVIDIA key in Settings > AI."
            return
        }

        state = .loading
        error = nil

        let truncated = String(text.prefix(4096))
        let endpoint = resolveEndpoint()

        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let model = resolveModel()
        let body: [String: Any] = [
            "model": model,
            "input": truncated,
            "voice": selectedVoice,
            "response_format": "mp3"
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        currentTask = URLSession.shared.dataTask(with: request) { [weak self] data, response, err in
            DispatchQueue.main.async {
                guard let self else { return }

                if let err {
                    self.state = .idle
                    self.error = err.localizedDescription
                    return
                }

                let httpCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "unknown"

                guard httpCode == 200, let data, !data.isEmpty else {
                    self.state = .idle
                    let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    self.error = "TTS failed (HTTP \(httpCode)): \(body.prefix(200))"
                    return
                }

                if let textCheck = String(data: data.prefix(200), encoding: .utf8),
                   textCheck.contains("{") || textCheck.contains("<html") || textCheck.contains("error") {
                    self.state = .idle
                    self.error = "TTS returned text instead of audio: \(textCheck.prefix(200))"
                    return
                }

                let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent("noteai_tts.mp3")
                try? data.write(to: tmpFile)

                do {
                    let player = try AVAudioPlayer(contentsOf: tmpFile, fileTypeHint: AVFileType.mp3.rawValue)
                    player.prepareToPlay()
                    player.play()
                    self.player = player
                    self.state = .playing
                    self.startProgressTimer()
                } catch {
                    self.state = .idle
                    self.error = "Audio error (type: \(contentType), \(data.count) bytes): \(error.localizedDescription)"
                }
            }
        }
        currentTask?.resume()
    }

    func togglePlayPause() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            state = .paused
        } else {
            player.play()
            state = .playing
            startProgressTimer()
        }
    }

    func stop() {
        currentTask?.cancel()
        currentTask = nil
        player?.stop()
        player = nil
        progressTimer?.invalidate()
        progressTimer = nil
        state = .idle
        progress = 0
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, let player = self.player else { return }
                if player.isPlaying {
                    self.progress = player.duration > 0 ? player.currentTime / player.duration : 0
                } else if self.state == .playing {
                    self.state = .idle
                    self.progress = 0
                    self.progressTimer?.invalidate()
                }
            }
        }
    }

    private func resolveAPIKey() -> String {
        let ttsKey = KeychainHelper.load(key: "apiKey_tts") ?? ""
        if !ttsKey.isEmpty { return ttsKey }
        let nvidiaKey = APIKeyStore.key(for: .nvidia)
        if !nvidiaKey.isEmpty { return nvidiaKey }
        let openaiKey = APIKeyStore.key(for: .openAI)
        if !openaiKey.isEmpty { return openaiKey }
        return ""
    }

    private func resolveEndpoint() -> String {
        let ttsKey = KeychainHelper.load(key: "apiKey_tts") ?? ""
        if !ttsKey.isEmpty && ttsKey.hasPrefix("sk-") && !ttsKey.contains("nvidia") {
            return "https://api.openai.com/v1/audio/speech"
        }
        let nvidiaKey = APIKeyStore.key(for: .nvidia)
        if !nvidiaKey.isEmpty {
            return "https://inference-api.nvidia.com/v1/audio/speech"
        }
        return "https://api.openai.com/v1/audio/speech"
    }

    private func resolveModel() -> String {
        let endpoint = resolveEndpoint()
        if endpoint.contains("nvidia") {
            return "openai/openai/gpt-4o-mini-tts"
        }
        return "gpt-4o-mini-tts"
    }

    static func saveTTSKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainHelper.delete(key: "apiKey_tts")
        } else {
            KeychainHelper.save(key: "apiKey_tts", value: trimmed)
        }
    }

    static func loadTTSKey() -> String {
        KeychainHelper.load(key: "apiKey_tts") ?? ""
    }
}
