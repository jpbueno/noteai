import AVFoundation
import Accelerate
import WhisperKit

struct TranscriptionAudioWindow {
    let startFrame: Int
    let frameCount: Int
    let startTime: Float
    let duration: Float
}

enum TranscriptionWindowPlanner {
    static func windows(frameLength: Int, sampleRate: Double, maxDuration: Double) -> [TranscriptionAudioWindow] {
        guard frameLength > 0, sampleRate > 0, maxDuration > 0 else { return [] }

        let maxFrames = max(1, Int((sampleRate * maxDuration).rounded(.down)))
        var windows: [TranscriptionAudioWindow] = []
        var startFrame = 0

        while startFrame < frameLength {
            let frameCount = min(maxFrames, frameLength - startFrame)
            windows.append(TranscriptionAudioWindow(
                startFrame: startFrame,
                frameCount: frameCount,
                startTime: Float(Double(startFrame) / sampleRate),
                duration: Float(Double(frameCount) / sampleRate)
            ))
            startFrame += frameCount
        }

        return windows
    }

    static func warningSegment(id: Int, startTime: Float, endTime: Float, reason: String) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            text: "[Transcript may be incomplete: \(reason)]",
            startTime: startTime,
            endTime: endTime,
            speaker: "System",
            confidence: 0
        )
    }
}

/// On-device transcription using WhisperKit (CoreML-optimized Whisper on Apple Neural Engine).
actor TranscriptionEngine {
    private static let maxTranscriptionWindowDuration: Double = 30
    private static let maxChunkAttempts = 2

    private var whisperKit: WhisperKit?
    private var isInitialized = false
    private var initFailed = false
    private var initError: String?
    private var segmentIndex = 0
    private var meetingStartTime: Date?
    private var elapsedTime: Float = 0

    /// Rolling context from previous chunks — fed as prompt conditioning so Whisper
    /// maintains coherence across chunk boundaries (names, acronyms, topic continuity).
    private var previousContext: String = ""

    /// Whisper control tokens and artifacts to strip from output
    private static let tokenPatterns: [String] = [
        // Whisper control tokens
        "<\\|startoftranscript\\|>",
        "<\\|endoftext\\|>",
        "<\\|en\\|>",
        "<\\|transcribe\\|>",
        "<\\|translate\\|>",
        "<\\|notimestamps\\|>",
        "<\\|[0-9]+\\.[0-9]+\\|>",
        // Bracketed hallucination tags
        "\\[BLANK_AUDIO\\]",
        "\\[NO_SPEECH\\]",
        "\\[Music\\]",
        "\\[MUSIC\\]",
        "\\[LAUGHTER\\]",
        "\\[Laughter\\]",
        // Parenthesized hallucination tags
        "\\(soft music\\)",
        "\\(music\\)",
        "\\(Music\\)",
        "\\(crying\\)",
        "\\(Crying\\)",
        "\\(wind blowing\\)",
        "\\(engine rumbling\\)",
        "\\(crashing\\)",
        "\\(distant noises\\)",
        "\\(speaking in foreign language\\)",
        "\\(Speaking in foreign language\\)",
        "\\(sighing\\)",
        "\\(laughing\\)",
        "\\(applause\\)",
        "\\(silence\\)",
        "\\(footsteps\\)",
        "\\(birds chirping\\)",
        "\\(dog barking\\)",
        "\\(phone ringing\\)",
        "\\(beeping\\)",
        "\\(buzzing\\)",
        "\\(tapping\\)",
        "\\(typing\\)",
        "\\(coughing\\)",
        "\\(clapping\\)",
        "\\(door slamming\\)",
        // Single-word parenthesized tags
        "\\(chanting\\)",
        "\\(chiming\\)",
        "\\(cheering\\)",
        "\\(screaming\\)",
        "\\(whispering\\)",
        "\\(snoring\\)",
        "\\(humming\\)",
        "\\(singing\\)",
        "\\(groaning\\)",
        "\\(sobbing\\)",
        "\\(gasping\\)",
        "\\(mumbling\\)",
        // Asterisk-wrapped tags
        "\\*[Mm]usic\\*",
        "\\*[Cc]rying\\*",
        "\\*[Ll]aughing\\*",
        "\\*[Ss]ighing\\*",
        "\\*[Ss]ad music\\*",
        // Generic patterns for any remaining hallucination brackets
        "\\([a-z]+\\)",              // (single lowercase word) like (chanting)
        "\\([a-z]+ [a-z]+\\)",      // (two lowercase words) like (soft music)
        "\\[[A-Z][a-z]+\\]",         // [Capitalized] like [Music]
        "\\[sounds? of [a-z ]+\\]",  // [sounds of ...] / [sound of ...]
    ]

    private static let filterRegex: NSRegularExpression? = {
        let combined = tokenPatterns.joined(separator: "|")
        return try? NSRegularExpression(pattern: combined, options: [])
    }()

    /// Repetition detection — Whisper sometimes loops on a phrase.
    private static let repetitionRegex: NSRegularExpression? = {
        // Catches any phrase of 4+ words repeated 3+ times consecutively
        try? NSRegularExpression(pattern: "\\b(\\w+(?:\\s+\\w+){3,})(?:\\s+\\1){2,}", options: [.caseInsensitive])
    }()

    private func log(_ msg: String) {
        let logFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("NoteAI/transcription.log")
        let line = "[\(Date())] \(msg)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFile.path) {
                if let handle = try? FileHandle(forWritingTo: logFile) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: logFile)
            }
        }
    }

    /// Call before first transcribe to load the model off the hot path.
    /// This prevents the actor from blocking on model load while buffers queue up.
    func warmup() async {
        log("warmup: starting model load")
        do {
            _ = try await getOrInitWhisper()
            log("warmup: model loaded successfully")
        } catch {
            log("warmup: model load FAILED: \(error)")
            initFailed = true
            initError = error.localizedDescription
        }
    }

    func transcribe(audioBuffer: AVAudioPCMBuffer) async throws -> [TranscriptSegment] {
        // Don't retry if model init already failed — prevents memory explosion
        if initFailed { return [] }

        // Skip if model isn't ready yet (still loading from warmup)
        guard let whisper = whisperKit else { return [] }

        log("transcribe: frames=\(audioBuffer.frameLength)")

        // Convert AVAudioPCMBuffer to float array
        var audioArray = bufferToFloatArray(audioBuffer)

        // Normalize FIRST — Bluetooth/AirPod audio from remote participants
        // can be very quiet and gets rejected by the silence check otherwise
        audioArray = normalizeAudio(audioArray)

        // Skip truly silent buffers (post-normalization)
        let energy = computeRMS(audioArray)
        guard energy > 0.0001 else {
            let bufferDuration = Float(audioBuffer.frameLength) / Float(audioBuffer.format.sampleRate)
            elapsedTime += bufferDuration
            log("skipped silent buffer: energy=\(energy)")
            return []
        }

        let bufferDuration = Float(audioBuffer.frameLength) / Float(audioBuffer.format.sampleRate)
        let windows = TranscriptionWindowPlanner.windows(
            frameLength: audioArray.count,
            sampleRate: audioBuffer.format.sampleRate,
            maxDuration: Self.maxTranscriptionWindowDuration
        )

        var segments: [TranscriptSegment] = []
        for window in windows {
            let start = window.startFrame
            let end = start + window.frameCount
            let windowSamples = Array(audioArray[start..<end])
            let windowBaseTime = elapsedTime + window.startTime

            do {
                let windowSegments = try await transcribeWindow(
                    whisper: whisper,
                    samples: windowSamples,
                    baseTime: windowBaseTime
                )
                segments.append(contentsOf: windowSegments)
            } catch {
                log("window transcribe FAILED start=\(window.startTime)s duration=\(window.duration)s: \(error)")
                segmentIndex += 1
                segments.append(TranscriptionWindowPlanner.warningSegment(
                    id: segmentIndex,
                    startTime: windowBaseTime,
                    endTime: windowBaseTime + window.duration,
                    reason: "Whisper chunk failed; partial transcript preserved"
                ))
            }
        }

        elapsedTime += bufferDuration

        return segments
    }

    func reset() {
        segmentIndex = 0
        meetingStartTime = nil
        elapsedTime = 0
        previousContext = ""
        // Allow retry on next recording session
        initFailed = false
        initError = nil
    }

    // MARK: - Private

    private func transcribeWindow(whisper: WhisperKit, samples: [Float], baseTime: Float) async throws -> [TranscriptSegment] {
        var lastError: Error?

        for attempt in 1...Self.maxChunkAttempts {
            do {
                log("calling whisper.transcribe window attempt=\(attempt), samples=\(samples.count)")
                let results = try await whisper.transcribe(
                    audioArray: samples,
                    decodeOptions: decodingOptions(for: whisper, attempt: attempt)
                )
                log("window transcribe returned \(results.count) results, segments=\(results.flatMap(\.segments).count)")
                return convertResults(results, baseTime: baseTime)
            } catch {
                lastError = error
                log("window transcribe attempt \(attempt) FAILED: \(error)")
            }
        }

        throw lastError ?? NSError(domain: "NoteAI.Transcription", code: -1)
    }

    private func decodingOptions(for whisper: WhisperKit, attempt: Int) -> DecodingOptions {
        let promptTokens: [Int]?
        if !previousContext.isEmpty, let tokenizer = whisper.tokenizer {
            let contextTokens = tokenizer.encode(text: previousContext)
            promptTokens = Array(contextTokens.suffix(100))
        } else {
            promptTokens = nil
        }

        return DecodingOptions(
            language: "en",
            temperature: attempt == 1 ? 0.0 : 0.2,
            temperatureIncrementOnFallback: 0.2,
            temperatureFallbackCount: attempt == 1 ? 2 : 3,
            topK: attempt == 1 ? 5 : 8,
            usePrefillPrompt: true,
            usePrefillCache: true,
            skipSpecialTokens: true,
            wordTimestamps: false,
            promptTokens: promptTokens,
            suppressBlank: true,
            compressionRatioThreshold: attempt == 1 ? 2.8 : 3.2,
            logProbThreshold: attempt == 1 ? -2.0 : -2.5,
            firstTokenLogProbThreshold: attempt == 1 ? -2.5 : -3.0,
            noSpeechThreshold: attempt == 1 ? 0.3 : 0.45,
            chunkingStrategy: .vad
        )
    }

    private func convertResults(_ results: [TranscriptionResult], baseTime: Float) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []

        for result in results {
            for segment in result.segments {
                let cleaned = Self.cleanText(segment.text)

                guard !cleaned.isEmpty,
                      !cleaned.allSatisfy({ $0.isWhitespace || $0.isPunctuation }) else {
                    continue
                }

                segmentIndex += 1
                segments.append(TranscriptSegment(
                    id: segmentIndex,
                    text: cleaned,
                    startTime: baseTime + segment.start,
                    endTime: baseTime + segment.end,
                    speaker: nil,
                    confidence: Float(segment.avgLogprob)
                ))
            }
        }

        let allText = segments
            .filter { $0.speaker != "System" }
            .map(\.text)
            .joined(separator: " ")
        if !allText.isEmpty {
            previousContext = String(allText.suffix(200))
        }

        return segments
    }

    private func getOrInitWhisper() async throws -> WhisperKit {
        if let whisperKit {
            return whisperKit
        }

        // Model name maps to WhisperKit HuggingFace repo folder names
        let storedName = UserDefaults.standard.string(forKey: "whisperModel") ?? "distil-large-v3"
        // Map user-friendly names to WhisperKit model identifiers
        let modelName: String
        switch storedName {
        case "distil-large-v3":
            modelName = "distil-whisper_distil-large-v3"
        default:
            modelName = storedName
        }

        // Try loading from local HuggingFace cache first to skip network verification
        // which can take 90+ seconds on VPN
        let hfCacheBase = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/huggingface/models/argmaxinc/whisperkit-coreml")
        let localModelFolder = hfCacheBase.appendingPathComponent("openai_whisper-\(storedName)")
        let distilModelFolder = hfCacheBase.appendingPathComponent("distil-whisper_distil-large-v3")

        let localFolder: URL?
        if FileManager.default.fileExists(atPath: localModelFolder.path) {
            localFolder = localModelFolder
            log("Using cached model at \(localModelFolder.path)")
        } else if storedName == "distil-large-v3" && FileManager.default.fileExists(atPath: distilModelFolder.path) {
            localFolder = distilModelFolder
            log("Using cached distil model at \(distilModelFolder.path)")
        } else {
            localFolder = nil
            log("No cached model found, will download \(modelName)")
        }

        let config: WhisperKitConfig
        if let localFolder {
            config = WhisperKitConfig(
                modelFolder: localFolder.path,
                computeOptions: ModelComputeOptions(
                    audioEncoderCompute: .cpuAndNeuralEngine,
                    textDecoderCompute: .cpuAndNeuralEngine
                ),
                download: false
            )
        } else {
            config = WhisperKitConfig(
                model: modelName,
                computeOptions: ModelComputeOptions(
                    audioEncoderCompute: .cpuAndNeuralEngine,
                    textDecoderCompute: .cpuAndNeuralEngine
                )
            )
        }
        let whisper = try await WhisperKit(config)
        whisperKit = whisper
        isInitialized = true
        print("[TranscriptionEngine] WhisperKit initialized with model: \(modelName)")
        return whisper
    }

    /// Normalize audio to a consistent peak level using Accelerate.
    /// This ensures quiet speakers and loud speakers are transcribed equally well.
    private func normalizeAudio(_ samples: [Float]) -> [Float] {
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))

        // Target peak at 0.9 to leave headroom, skip if already loud enough
        // or if the signal is basically silence (peak < 0.001)
        guard peak > 0.001, peak < 0.7 else { return samples }

        let gain = Float(0.9) / peak
        var normalized = [Float](repeating: 0, count: samples.count)
        var g = gain
        vDSP_vsmul(samples, 1, &g, &normalized, 1, vDSP_Length(samples.count))
        return normalized
    }

    /// Strip Whisper control tokens, hallucination artifacts, and repetition loops.
    private static func cleanText(_ text: String) -> String {
        var cleaned = text
        if let regex = filterRegex {
            cleaned = regex.stringByReplacingMatches(
                in: cleaned,
                range: NSRange(cleaned.startIndex..., in: cleaned),
                withTemplate: ""
            )
        }
        // Collapse repeated phrases (Whisper looping artifact)
        if let repRegex = repetitionRegex {
            cleaned = repRegex.stringByReplacingMatches(
                in: cleaned,
                range: NSRange(cleaned.startIndex..., in: cleaned),
                withTemplate: "$1"
            )
        }
        // Collapse multiple spaces and trim
        cleaned = cleaned.replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned
    }

    /// Compute RMS energy of an audio buffer to detect silence.
    private func computeRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var meanSquare: Float = 0
        vDSP_measqv(samples, 1, &meanSquare, vDSP_Length(samples.count))
        return sqrt(meanSquare)
    }

    private func bufferToFloatArray(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData else { return [] }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)

        if channelCount == 1 {
            return Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
        }

        // Mix down to mono if stereo
        var mono = [Float](repeating: 0, count: frameCount)
        for frame in 0..<frameCount {
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += channelData[channel][frame]
            }
            mono[frame] = sum / Float(channelCount)
        }
        return mono
    }
}
