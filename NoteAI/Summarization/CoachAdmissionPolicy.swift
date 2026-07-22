import Foundation

struct CoachInsightCandidate: Codable, Equatable, Sendable {
    let type: CoachInsightType
    let content: String
    let basis: CoachInsightBasis
    let sourceSegmentIDs: [Int]
    let topic: String
    let priority: CoachInsightPriority

    private enum CodingKeys: String, CodingKey {
        case type
        case content
        case basis
        case sourceSegmentIDs = "source_segment_ids"
        case topic
        case priority
    }
}

enum CoachGenerationResult: Equatable, Sendable {
    case candidates([CoachInsightCandidate])
    case malformed(String)
}

enum CoachCandidateRejectionReason: Equatable, Sendable {
    case tooManyCandidates
    case emptyContent
    case contentTooLong
    case priorityTooLow
    case invalidTopic
    case exactDuplicate
    case nearDuplicate
    case missingTranscriptEvidence
    case invalidEvidenceReference
    case tooManyEvidenceReferences
    case topicCooldown
    case unsupportedCommitment
    case sessionBudgetExhausted
}

struct CoachCandidateRejection: Equatable, Sendable {
    let candidateIndex: Int?
    let reason: CoachCandidateRejectionReason
}

struct CoachAdmissionDecision: Equatable, Sendable {
    let accepted: [CoachInsight]
    let rejections: [CoachCandidateRejection]
}

struct CoachAdmissionPolicy: Sendable {
    let maxCandidatesPerGeneration: Int
    let maxActiveInsights: Int
    let maxContentCharacters: Int
    let maxContentWords: Int
    let maxTopicCharacters: Int
    let maxEvidenceReferences: Int
    let minimumPriority: CoachInsightPriority
    let nearDuplicateThreshold: Double
    let topicCooldown: TimeInterval

    static let `default` = CoachAdmissionPolicy(
        maxCandidatesPerGeneration: 2,
        maxActiveInsights: 10,
        maxContentCharacters: 180,
        maxContentWords: 24,
        maxTopicCharacters: 64,
        maxEvidenceReferences: 4,
        minimumPriority: .high,
        nearDuplicateThreshold: 0.82,
        topicCooldown: 300
    )

    func evaluate(
        candidates: [CoachInsightCandidate],
        transcript: [TranscriptSegment],
        existingInsights: [CoachInsight],
        sessionID: UUID,
        now: Date
    ) -> CoachAdmissionDecision {
        guard candidates.count <= maxCandidatesPerGeneration else {
            return CoachAdmissionDecision(
                accepted: [],
                rejections: [CoachCandidateRejection(candidateIndex: nil, reason: .tooManyCandidates)]
            )
        }

        var transcriptByID: [Int: TranscriptSegment] = [:]
        for segment in transcript where transcriptByID[segment.id] == nil {
            transcriptByID[segment.id] = segment
        }
        var accepted: [CoachInsight] = []
        var rejections: [CoachCandidateRejection] = []

        let prioritizedCandidates = candidates.enumerated().sorted { lhs, rhs in
            if lhs.element.priority != rhs.element.priority {
                return lhs.element.priority > rhs.element.priority
            }
            return lhs.offset < rhs.offset
        }

        for (index, candidate) in prioritizedCandidates {
            let content = candidate.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else {
                rejections.append(.init(candidateIndex: index, reason: .emptyContent))
                continue
            }
            guard content.count <= maxContentCharacters,
                  content.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count <= maxContentWords else {
                rejections.append(.init(candidateIndex: index, reason: .contentTooLong))
                continue
            }
            guard candidate.priority >= minimumPriority else {
                rejections.append(.init(candidateIndex: index, reason: .priorityTooLow))
                continue
            }

            let topic = normalizedTopic(candidate.topic)
            guard !topic.isEmpty, topic.count <= maxTopicCharacters else {
                rejections.append(.init(candidateIndex: index, reason: .invalidTopic))
                continue
            }
            if candidate.type == .actionItem && candidate.basis != .transcript {
                rejections.append(.init(candidateIndex: index, reason: .unsupportedCommitment))
                continue
            }
            if candidate.basis != .transcript && looksLikeUnsupportedCommitment(content) {
                rejections.append(.init(candidateIndex: index, reason: .unsupportedCommitment))
                continue
            }

            let comparisonInsights = existingInsights + accepted
            if comparisonInsights.contains(where: { normalizedText($0.content) == normalizedText(content) }) {
                rejections.append(.init(candidateIndex: index, reason: .exactDuplicate))
                continue
            }
            if comparisonInsights.contains(where: { similarity($0.content, content) >= nearDuplicateThreshold }) {
                rejections.append(.init(candidateIndex: index, reason: .nearDuplicate))
                continue
            }

            let uniqueSourceIDs = candidate.sourceSegmentIDs.reduce(into: [Int]()) { result, id in
                if !result.contains(id) { result.append(id) }
            }
            guard uniqueSourceIDs.count <= maxEvidenceReferences else {
                rejections.append(.init(candidateIndex: index, reason: .tooManyEvidenceReferences))
                continue
            }
            guard uniqueSourceIDs.allSatisfy({ transcriptByID[$0] != nil }) else {
                rejections.append(.init(candidateIndex: index, reason: .invalidEvidenceReference))
                continue
            }
            if candidate.basis == .transcript && uniqueSourceIDs.isEmpty {
                rejections.append(.init(candidateIndex: index, reason: .missingTranscriptEvidence))
                continue
            }

            if let priorForTopic = comparisonInsights.last(where: {
                normalizedTopic($0.topic ?? "") == topic &&
                now.timeIntervalSince($0.timestamp) < topicCooldown
            }), candidate.priority <= priorForTopic.priority {
                rejections.append(.init(candidateIndex: index, reason: .topicCooldown))
                continue
            }

            let activeCount = comparisonInsights.filter { $0.lifecycle == .active }.count
            guard activeCount < maxActiveInsights else {
                rejections.append(.init(candidateIndex: index, reason: .sessionBudgetExhausted))
                continue
            }

            let evidence = uniqueSourceIDs.compactMap { id -> CoachEvidenceReference? in
                guard let segment = transcriptByID[id] else { return nil }
                return CoachEvidenceReference(
                    segmentID: id,
                    startTime: segment.startTime,
                    endTime: segment.endTime
                )
            }
            accepted.append(CoachInsight(
                timestamp: now,
                type: candidate.type,
                content: content,
                sessionID: sessionID,
                basis: candidate.basis,
                evidence: evidence,
                topic: topic,
                priority: candidate.priority
            ))
        }

        return CoachAdmissionDecision(accepted: accepted, rejections: rejections)
    }

    private func looksLikeUnsupportedCommitment(_ content: String) -> Bool {
        if content.range(of: #"\?\s*$"#, options: .regularExpression) != nil ||
            content.range(
                of: #"(?i)^(ask|check|clarify|confirm|determine|probe)\b"#,
                options: .regularExpression
            ) != nil {
            return false
        }
        if content.range(
            of: #"(?i)\b(committed|agreed|promised)\b"#,
            options: .regularExpression
        ) != nil {
            return true
        }
        return content.range(
            of: #"(?i)\b(customer|client|partner|speaker|team|they|we)\b[\s\S]{0,60}\bwill\s+(complete|deliver|follow up|provide|send|share|submit)\b"#,
            options: .regularExpression
        ) != nil
    }

    private func normalizedTopic(_ topic: String) -> String {
        topic
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func similarity(_ lhs: String, _ rhs: String) -> Double {
        let lhsTokens = normalizedTokens(lhs)
        let rhsTokens = normalizedTokens(rhs)
        guard !lhsTokens.isEmpty, !rhsTokens.isEmpty else { return 0 }
        let intersection = lhsTokens.intersection(rhsTokens).count
        let union = lhsTokens.union(rhsTokens).count
        return union == 0 ? 0 : Double(intersection) / Double(union)
    }

    private func normalizedText(_ text: String) -> String {
        normalizedTokens(text).sorted().joined(separator: " ")
    }

    private func normalizedTokens(_ text: String) -> Set<String> {
        let stopWords: Set<String> = [
            "a", "an", "and", "about", "before", "for", "of", "or", "the", "their", "to", "whether",
        ]
        return Set(text
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !stopWords.contains($0) }
            .map(stem))
    }

    private func stem(_ token: String) -> String {
        if token.count > 5 && token.hasSuffix("ing") {
            return String(token.dropLast(3))
        }
        if token.count > 3 && token.hasSuffix("s") {
            return String(token.dropLast())
        }
        return token
    }
}
