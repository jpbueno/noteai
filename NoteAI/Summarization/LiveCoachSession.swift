import Foundation

protocol AICoachGenerating: Sendable {
    func generateInsights(for request: CoachAnalysisRequest) async throws -> CoachGenerationResult
    func answerQuestion(_ request: CoachQuestionRequest) async throws -> String
}

protocol CoachClock: Sendable {
    func currentDate() -> Date
}

struct SystemCoachClock: CoachClock {
    func currentDate() -> Date { Date() }
}

enum CoachAnalysisOutcome: Equatable, Sendable {
    case notReady
    case busy
    case noOp
    case admitted([CoachInsight])
    case rejected([CoachCandidateRejection])
    case malformed(String)
    case staleSession
    case failed(String)
}

enum CoachQuestionOutcome: Equatable, Sendable {
    case ignored
    case busy
    case answered(CoachChatMessage)
    case staleSession
    case failed(String)
}

struct LiveCoachSnapshot: Equatable, Sendable {
    let sessionID: UUID
    let autoInsights: [CoachInsight]
    let chatMessages: [CoachChatMessage]
}

enum CoachInsightLifecycleMutationOutcome: Equatable, Sendable {
    case updated(CoachInsight)
    case notFound
    case staleSession
}

protocol CoachInsightLifecycleMutating: Sendable {
    func setAutoInsightLifecycle(
        id: UUID,
        lifecycle: CoachInsightLifecycle
    ) async -> CoachInsightLifecycleMutationOutcome
}

actor LiveCoachSession: CoachInsightLifecycleMutating {
    nonisolated let id: UUID

    private static let maxPromptPriorInsightCount = 8
    private static let maxPromptPriorInsightCharacters = 1_000

    private let generator: any AICoachGenerating
    private let clock: any CoachClock
    private let admissionPolicy: CoachAdmissionPolicy
    private var context: CoachContext
    private var isActive = true
    private var autoInsights: [CoachInsight] = []
    private var chatMessages: [CoachChatMessage] = []
    private var analysisTask: Task<CoachGenerationResult, Error>?
    private var analysisRequestID: UUID?
    private var questionTask: Task<String, Error>?
    private var questionRequestID: UUID?

    init(
        id: UUID = UUID(),
        generator: any AICoachGenerating,
        clock: any CoachClock = SystemCoachClock(),
        contextPolicy: CoachContextPolicy = .default,
        admissionPolicy: CoachAdmissionPolicy = .default,
        initialAutoInsights: [CoachInsight] = [],
        initialChatMessages: [CoachChatMessage] = []
    ) {
        self.id = id
        self.generator = generator
        self.clock = clock
        self.context = CoachContext(policy: contextPolicy)
        self.admissionPolicy = admissionPolicy
        self.autoInsights = initialAutoInsights.filter {
            $0.role == nil && $0.sessionID == id
        }
        self.chatMessages = initialChatMessages.filter { $0.sessionID == id }
    }

    func isAnalysisReady(transcript: [TranscriptSegment]) -> Bool {
        guard isActive, analysisTask == nil else { return false }
        return context.isAnalysisReady(transcript: transcript, now: clock.currentDate())
    }

    func analyze(transcript: [TranscriptSegment]) async -> CoachAnalysisOutcome {
        guard isActive else { return .staleSession }
        guard analysisTask == nil else { return .busy }

        let requestDate = clock.currentDate()
        guard let request = context.prepareAnalysis(
            sessionID: id,
            transcript: transcript,
            priorInsights: boundedPromptPriorInsights(),
            now: requestDate
        ) else {
            return .notReady
        }

        let requestID = UUID()
        let task = Task { try await generator.generateInsights(for: request) }
        analysisRequestID = requestID
        analysisTask = task

        do {
            let generated = try await task.value
            let requestIsCurrent = isActive && analysisRequestID == requestID
            clearAnalysisTask(requestID: requestID)
            guard requestIsCurrent else { return .staleSession }

            let completionDate = clock.currentDate()

            switch generated {
            case .malformed(let reason):
                context.failAnalysis(at: completionDate)
                return .malformed(reason)
            case .candidates(let candidates):
                context.completeAnalysis(segmentCount: transcript.count, at: completionDate)
                guard !candidates.isEmpty else { return .noOp }
                let decision = admissionPolicy.evaluate(
                    candidates: candidates,
                    transcript: transcript,
                    existingInsights: autoInsights,
                    sessionID: id,
                    now: completionDate
                )
                autoInsights.append(contentsOf: decision.accepted)
                if decision.accepted.isEmpty {
                    return .rejected(decision.rejections)
                }
                return .admitted(decision.accepted)
            }
        } catch {
            let requestIsCurrent = isActive && analysisRequestID == requestID
            clearAnalysisTask(requestID: requestID)
            guard requestIsCurrent else { return .staleSession }
            context.failAnalysis(at: clock.currentDate())
            return .failed(error.localizedDescription)
        }
    }

    func ask(question: String, transcript: [TranscriptSegment]) async -> CoachQuestionOutcome {
        guard isActive else { return .staleSession }
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .ignored }
        guard questionTask == nil else { return .busy }

        let request = context.prepareQuestion(
            sessionID: id,
            question: trimmed,
            transcript: transcript,
            priorInsights: boundedPromptPriorInsights(),
            chatHistory: chatMessages
        )
        chatMessages.append(CoachChatMessage(
            timestamp: clock.currentDate(),
            sessionID: id,
            role: .user,
            content: trimmed
        ))

        let requestID = UUID()
        let task = Task { try await generator.answerQuestion(request) }
        questionRequestID = requestID
        questionTask = task

        do {
            let response = try await task.value
            let requestIsCurrent = isActive && questionRequestID == requestID
            clearQuestionTask(requestID: requestID)
            guard requestIsCurrent else { return .staleSession }

            let cleaned = response.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return .failed("The coach returned an empty reply.") }
            let message = CoachChatMessage(
                timestamp: clock.currentDate(),
                sessionID: id,
                role: .assistant,
                content: cleaned
            )
            chatMessages.append(message)
            return .answered(message)
        } catch {
            let requestIsCurrent = isActive && questionRequestID == requestID
            clearQuestionTask(requestID: requestID)
            guard requestIsCurrent else { return .staleSession }

            let message = "Reply failed: \(error.localizedDescription)"
            chatMessages.append(CoachChatMessage(
                timestamp: clock.currentDate(),
                sessionID: id,
                role: .assistant,
                content: message
            ))
            return .failed(message)
        }
    }

    func snapshot() -> LiveCoachSnapshot {
        LiveCoachSnapshot(
            sessionID: id,
            autoInsights: autoInsights,
            chatMessages: chatMessages
        )
    }

    func setAutoInsightLifecycle(
        id: UUID,
        lifecycle: CoachInsightLifecycle
    ) -> CoachInsightLifecycleMutationOutcome {
        guard isActive else { return .staleSession }
        guard let index = autoInsights.firstIndex(where: { $0.id == id }) else { return .notFound }

        autoInsights[index].lifecycle = lifecycle
        return .updated(autoInsights[index])
    }

    func cancelPendingWork() {
        analysisRequestID = nil
        questionRequestID = nil
        analysisTask?.cancel()
        questionTask?.cancel()
        analysisTask = nil
        questionTask = nil
    }

    func cancel() {
        isActive = false
        cancelPendingWork()
    }

    private func clearAnalysisTask(requestID: UUID) {
        guard analysisRequestID == requestID else { return }
        analysisRequestID = nil
        analysisTask = nil
    }

    private func clearQuestionTask(requestID: UUID) {
        guard questionRequestID == requestID else { return }
        questionRequestID = nil
        questionTask = nil
    }

    private func boundedPromptPriorInsights() -> [CoachInsight] {
        var result: [CoachInsight] = []
        var characterCount = 0

        for insight in autoInsights.reversed() {
            guard result.count < Self.maxPromptPriorInsightCount else { break }
            let insightCharacterCount = insight.content.unicodeScalars.count
            guard insightCharacterCount <= Self.maxPromptPriorInsightCharacters,
                  characterCount + insightCharacterCount <= Self.maxPromptPriorInsightCharacters else {
                continue
            }
            result.insert(insight, at: 0)
            characterCount += insightCharacterCount
        }
        return result
    }
}
