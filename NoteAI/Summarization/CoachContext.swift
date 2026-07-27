import Foundation

struct CoachContextPolicy: Equatable, Sendable {
    let minimumWordCount: Int
    let minimumNewSegments: Int
    let minimumAnalysisInterval: TimeInterval
    let failureRetryInterval: TimeInterval
    let maxRecentSegments: Int
    let maxDeltaSegments: Int
    let maxTranscriptCharacters: Int
    let maxSpeakerCharacters: Int
    let maxRollingContextCharacters: Int
    let maxChatMessages: Int

    static let `default` = CoachContextPolicy(
        minimumWordCount: 25,
        minimumNewSegments: 2,
        minimumAnalysisInterval: 300,
        failureRetryInterval: 30,
        maxRecentSegments: 24,
        maxDeltaSegments: 12,
        maxTranscriptCharacters: 9_000,
        maxSpeakerCharacters: 80,
        maxRollingContextCharacters: 1_200,
        maxChatMessages: 12
    )
}

struct CoachTranscriptExcerpt: Codable, Equatable, Sendable {
    let id: Int
    let text: String
    let startTime: Float
    let endTime: Float
    let speaker: String?

    init(id: Int, text: String, startTime: Float, endTime: Float, speaker: String?) {
        self.id = id
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.speaker = speaker
    }

    init(segment: TranscriptSegment) {
        self.init(
            id: segment.id,
            text: segment.text,
            startTime: segment.startTime,
            endTime: segment.endTime,
            speaker: segment.speaker
        )
    }
}

struct CoachChatMessage: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let timestamp: Date
    let sessionID: UUID
    let role: CoachRole
    let content: String

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        sessionID: UUID,
        role: CoachRole,
        content: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.role = role
        self.content = content
    }
}

struct CoachAnalysisRequest: Equatable, Sendable {
    let sessionID: UUID
    let transcriptDelta: [CoachTranscriptExcerpt]
    let recentTranscript: [CoachTranscriptExcerpt]
    let rollingContext: String
    let priorInsights: [CoachInsight]
}

struct CoachQuestionRequest: Equatable, Sendable {
    let sessionID: UUID
    let question: String
    let recentTranscript: [CoachTranscriptExcerpt]
    let rollingContext: String
    let priorInsights: [CoachInsight]
    let chatHistory: [CoachChatMessage]
}

struct CoachContext: Sendable {
    private let policy: CoachContextPolicy
    private var analyzedSegmentCount = 0
    private var rolledSegmentCount = 0
    private var lastAnalysisDate: Date?
    private var lastShortRetryDate: Date?
    private var rollingContext = ""

    init(policy: CoachContextPolicy = .default) {
        self.policy = policy
    }

    mutating func isAnalysisReady(
        transcript: [TranscriptSegment],
        now: Date
    ) -> Bool {
        resetIfTranscriptWasReplaced(transcript)
        guard transcript.count - analyzedSegmentCount >= policy.minimumNewSegments else { return false }

        let wordCount = transcript.reduce(into: 0) { count, segment in
            count += segment.text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        }
        guard wordCount >= policy.minimumWordCount else { return false }

        if let lastAnalysisDate,
           now.timeIntervalSince(lastAnalysisDate) < policy.minimumAnalysisInterval {
            return false
        }
        if let lastShortRetryDate,
           now.timeIntervalSince(lastShortRetryDate) < policy.failureRetryInterval {
            return false
        }
        return true
    }

    mutating func prepareAnalysis(
        sessionID: UUID,
        transcript: [TranscriptSegment],
        priorInsights: [CoachInsight] = [],
        now: Date
    ) -> CoachAnalysisRequest? {
        guard isAnalysisReady(transcript: transcript, now: now) else { return nil }

        updateRollingContext(with: transcript)
        let recent = boundedTranscriptExcerpts(from: transcript)
        let deltaSegmentIDs = Set(transcript
            .dropFirst(analyzedSegmentCount)
            .suffix(policy.maxDeltaSegments)
            .map(\.id))
        let delta = recent.filter { deltaSegmentIDs.contains($0.id) }

        return CoachAnalysisRequest(
            sessionID: sessionID,
            transcriptDelta: delta,
            recentTranscript: recent,
            rollingContext: rollingContext,
            priorInsights: priorInsights
        )
    }

    mutating func completeAnalysis(segmentCount: Int, at date: Date) {
        analyzedSegmentCount = max(analyzedSegmentCount, segmentCount)
        lastAnalysisDate = date
        lastShortRetryDate = nil
    }

    mutating func completeNoOp(segmentCount: Int, at date: Date) {
        analyzedSegmentCount = max(analyzedSegmentCount, segmentCount)
        lastShortRetryDate = date
    }

    mutating func failAnalysis(at date: Date) {
        lastShortRetryDate = date
    }

    mutating func prepareQuestion(
        sessionID: UUID,
        question: String,
        transcript: [TranscriptSegment],
        priorInsights: [CoachInsight],
        chatHistory: [CoachChatMessage]
    ) -> CoachQuestionRequest {
        resetIfTranscriptWasReplaced(transcript)
        updateRollingContext(with: transcript)
        return CoachQuestionRequest(
            sessionID: sessionID,
            question: question,
            recentTranscript: boundedTranscriptExcerpts(from: transcript),
            rollingContext: rollingContext,
            priorInsights: priorInsights,
            chatHistory: Array(chatHistory.suffix(policy.maxChatMessages))
        )
    }

    private mutating func resetIfTranscriptWasReplaced(_ transcript: [TranscriptSegment]) {
        guard transcript.count < analyzedSegmentCount || transcript.count < rolledSegmentCount else { return }
        analyzedSegmentCount = 0
        rolledSegmentCount = 0
        lastAnalysisDate = nil
        lastShortRetryDate = nil
        rollingContext = ""
    }

    private mutating func updateRollingContext(with transcript: [TranscriptSegment]) {
        let upperBound = max(0, transcript.count - policy.maxRecentSegments)
        guard upperBound > rolledSegmentCount else { return }

        var remainingCharacters = policy.maxRollingContextCharacters
        var contextLines: [String] = []
        for segment in transcript[..<upperBound].reversed() {
            guard remainingCharacters > 0 else { break }
            guard !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  CoachAutoAdmissionContractV1.isSafeTranscriptSourceText(segment.text) else {
                continue
            }
            let speaker = boundedSpeaker(segment.speaker).map { " \($0)" } ?? ""
            let prefix = "[\(segment.id) \(segment.formattedTimestamp)\(speaker)] "
            let line = prefix + segment.text
            let lineCharacterCount = line.unicodeScalars.count + (contextLines.isEmpty ? 0 : 1)
            guard lineCharacterCount <= remainingCharacters else { continue }
            contextLines.insert(line, at: 0)
            remainingCharacters -= lineCharacterCount
        }
        rollingContext = contextLines.joined(separator: "\n")
        rolledSegmentCount = upperBound
    }

    private func boundedTranscriptExcerpts(
        from transcript: [TranscriptSegment]
    ) -> [CoachTranscriptExcerpt] {
        var excerpts: [CoachTranscriptExcerpt] = []
        var characterCount = 0

        for segment in transcript.reversed() {
            guard excerpts.count < policy.maxRecentSegments else { break }
            let text = segment.text
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  CoachAutoAdmissionContractV1.isSafeTranscriptSourceText(text) else {
                continue
            }

            let remainingCharacters = policy.maxTranscriptCharacters - characterCount
            guard remainingCharacters > 0 else { break }
            let speaker = boundedSpeaker(segment.speaker)
            let textCharacterCount = text.unicodeScalars.count
            let excerptCharacterCount = textCharacterCount
                + (speaker?.unicodeScalars.count ?? 0)
            guard excerptCharacterCount <= remainingCharacters else { continue }

            excerpts.insert(CoachTranscriptExcerpt(
                id: segment.id,
                text: text,
                startTime: segment.startTime,
                endTime: segment.endTime,
                speaker: speaker
            ), at: 0)
            characterCount += excerptCharacterCount
        }

        return excerpts
    }

    private func boundedSpeaker(_ speaker: String?) -> String? {
        guard let trimmed = speaker?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              CoachAutoAdmissionContractV1.isSafeTranscriptSourceText(trimmed) else {
            return nil
        }
        return String(trimmed.unicodeScalars.prefix(policy.maxSpeakerCharacters))
    }
}
