import Foundation

struct CoachContextPolicy: Equatable, Sendable {
    let minimumWordCount: Int
    let minimumNewSegments: Int
    let minimumAnalysisInterval: TimeInterval
    let maxRecentSegments: Int
    let maxDeltaSegments: Int
    let maxRollingContextCharacters: Int
    let maxChatMessages: Int

    static let `default` = CoachContextPolicy(
        minimumWordCount: 25,
        minimumNewSegments: 2,
        minimumAnalysisInterval: 300,
        maxRecentSegments: 24,
        maxDeltaSegments: 12,
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
        let recent = transcript.suffix(policy.maxRecentSegments).map(CoachTranscriptExcerpt.init(segment:))
        let delta = transcript
            .dropFirst(analyzedSegmentCount)
            .suffix(policy.maxDeltaSegments)
            .map(CoachTranscriptExcerpt.init(segment:))

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
            recentTranscript: transcript.suffix(policy.maxRecentSegments).map(CoachTranscriptExcerpt.init(segment:)),
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
        rollingContext = ""
    }

    private mutating func updateRollingContext(with transcript: [TranscriptSegment]) {
        let upperBound = max(0, transcript.count - policy.maxRecentSegments)
        guard upperBound > rolledSegmentCount else { return }

        let contextLines: [String] = transcript[rolledSegmentCount..<upperBound]
            .map { segment -> String in
                let speaker = segment.speaker.map { " \($0)" } ?? ""
                return "[\(segment.id) \(segment.formattedTimestamp)\(speaker)] \(segment.text)"
            }
        let additions = contextLines.joined(separator: "\n")
        rollingContext = [rollingContext, additions]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        if rollingContext.count > policy.maxRollingContextCharacters {
            rollingContext = String(rollingContext.suffix(policy.maxRollingContextCharacters))
        }
        rolledSegmentCount = upperBound
    }
}
