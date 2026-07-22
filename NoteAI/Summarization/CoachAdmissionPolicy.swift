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

enum CoachAutoAdmissionRejectionCategory: String, Equatable, Sendable {
    case invalidEnvelope = "invalid_envelope"
    case unsupportedVersion = "unsupported_version"
    case tooManyCandidates = "too_many_candidates"
    case invalidCandidate = "invalid_candidate"
    case invalidText = "invalid_text"
    case invalidTopic = "invalid_topic"
    case invalidEvidence = "invalid_evidence"
}

/// Strict v1 Module for untrusted automatic coach output.
struct CoachAutoAdmissionContractV1 {
    private static let maximumSafeInteger = 9_007_199_254_740_991

    private struct ContractFailure: Error {
        let category: CoachAutoAdmissionRejectionCategory
    }

    private struct TranscriptSource {
        let text: String
    }

    private static let envelopeKeys: Set<String> = ["contract_version", "candidates"]
    private static let guidanceKeys: Set<String> = [
        "kind", "directive", "question", "priority", "topic",
    ]
    private static let quoteKeys: Set<String> = [
        "kind", "presentation", "evidence_quotes", "priority", "topic",
    ]
    private static let evidenceKeys: Set<String> = ["source_segment_id", "quote"]
    private static let directives: Set<String> = [
        "ask", "clarify", "confirm", "check", "probe", "compare", "validate", "quantify",
        "discuss", "explore",
    ]
    private static let interrogativeHeads: Set<String> = [
        "what", "why", "how", "when", "where", "which", "who", "whose", "is", "are",
        "was", "were", "do", "does", "did", "can", "could", "should", "would", "will",
        "has", "have", "had", "may", "might",
    ]

    static func parse(
        modelResponse: String,
        transcriptContext: [CoachTranscriptExcerpt]
    ) -> CoachGenerationResult {
        do {
            return .candidates(try decode(
                modelResponse: modelResponse,
                transcriptContext: transcriptContext
            ))
        } catch let failure as ContractFailure {
            return .malformed(failure.category.rawValue)
        } catch {
            return .malformed(CoachAutoAdmissionRejectionCategory.invalidEnvelope.rawValue)
        }
    }

    private static func decode(
        modelResponse: String,
        transcriptContext: [CoachTranscriptExcerpt]
    ) throws -> [CoachInsightCandidate] {
        guard let data = modelResponse.data(using: .utf8),
              let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              hasExactKeys(envelope, envelopeKeys),
              let version = strictInteger(envelope["contract_version"]),
              let candidates = envelope["candidates"] as? [Any] else {
            throw ContractFailure(category: .invalidEnvelope)
        }
        guard version == 1 else {
            throw ContractFailure(category: .unsupportedVersion)
        }
        guard candidates.count <= 2 else {
            throw ContractFailure(category: .tooManyCandidates)
        }

        let transcript = try transcriptIndex(from: transcriptContext)
        return try candidates.map { rawCandidate in
            guard let candidate = rawCandidate as? [String: Any],
                  let kind = candidate["kind"] as? String else {
                throw ContractFailure(category: .invalidCandidate)
            }
            switch kind {
            case "guidance_question":
                return try decodeGuidance(candidate)
            case "transcript_quote":
                return try decodeTranscriptQuote(candidate, transcript: transcript)
            default:
                throw ContractFailure(category: .invalidCandidate)
            }
        }
    }

    private static func decodeGuidance(
        _ candidate: [String: Any]
    ) throws -> CoachInsightCandidate {
        guard hasExactKeys(candidate, guidanceKeys),
              let directive = candidate["directive"] as? String,
              let question = candidate["question"] as? String,
              let priority = priority(from: candidate["priority"]) else {
            throw ContractFailure(category: .invalidCandidate)
        }
        guard directives.contains(directive) else {
            throw ContractFailure(category: .invalidCandidate)
        }
        let topic = try validatedTopic(candidate["topic"])
        let normalizedQuestion = try normalizedQuestion(question)
        let capitalizedDirective = directive.prefix(1).uppercased() + directive.dropFirst()
        let content = "\(capitalizedDirective): \(normalizedQuestion)"
        try validateDerivedContent(content)

        return CoachInsightCandidate(
            type: .talkingPoint,
            content: content,
            basis: .recommendation,
            sourceSegmentIDs: [],
            topic: topic,
            priority: priority
        )
    }

    private static func decodeTranscriptQuote(
        _ candidate: [String: Any],
        transcript: [Int: TranscriptSource]
    ) throws -> CoachInsightCandidate {
        guard hasExactKeys(candidate, quoteKeys),
              let presentation = candidate["presentation"] as? String,
              let priority = priority(from: candidate["priority"]) else {
            throw ContractFailure(category: .invalidCandidate)
        }
        let derivedPresentation = try presentationValues(for: presentation)
        let topic = try validatedTopic(candidate["topic"])
        guard let evidence = candidate["evidence_quotes"] as? [Any] else {
            throw ContractFailure(category: .invalidEvidence)
        }
        guard !evidence.isEmpty else {
            throw ContractFailure(category: .invalidEvidence)
        }

        var evidenceIDs: [Int] = []
        var normalizedQuote: String?
        for rawEvidence in evidence {
            guard let quoteRecord = rawEvidence as? [String: Any],
                  hasExactKeys(quoteRecord, evidenceKeys),
                  let sourceID = strictInteger(quoteRecord["source_segment_id"]),
                  isPositiveSafeInteger(sourceID),
                  let quote = quoteRecord["quote"] as? String,
                  let source = transcript[sourceID],
                  !evidenceIDs.contains(sourceID) else {
                throw ContractFailure(category: .invalidEvidence)
            }
            let candidateQuote = try normalizedText(quote, category: .invalidEvidence)
            let sourceText = try normalizedText(source.text, category: .invalidEvidence)
            guard !candidateQuote.isEmpty,
                  candidateQuote == sourceText,
                  normalizedQuote == nil || normalizedQuote == candidateQuote else {
                throw ContractFailure(category: .invalidEvidence)
            }
            normalizedQuote = candidateQuote
            evidenceIDs.append(sourceID)
        }

        guard let normalizedQuote else {
            throw ContractFailure(category: .invalidEvidence)
        }
        let content = derivedPresentation.prefix + normalizedQuote
        try validateDerivedContent(content)
        return CoachInsightCandidate(
            type: derivedPresentation.type,
            content: content,
            basis: .transcript,
            sourceSegmentIDs: evidenceIDs,
            topic: topic,
            priority: priority
        )
    }

    private static func transcriptIndex(
        from transcriptContext: [CoachTranscriptExcerpt]
    ) throws -> [Int: TranscriptSource] {
        var transcript: [Int: TranscriptSource] = [:]
        for segment in transcriptContext {
            guard isPositiveSafeInteger(segment.id), transcript[segment.id] == nil else {
                throw ContractFailure(category: .invalidEvidence)
            }
            transcript[segment.id] = TranscriptSource(text: segment.text)
        }
        return transcript
    }

    private static func presentationValues(
        for presentation: String
    ) throws -> (type: CoachInsightType, prefix: String) {
        switch presentation {
        case "observation":
            return (.keyInsight, "Transcript quote: ")
        case "possible_action":
            return (.actionItem, "Possible action: ")
        case "possible_follow_up":
            return (.followUp, "Possible follow-up: ")
        default:
            throw ContractFailure(category: .invalidCandidate)
        }
    }

    private static func priority(from value: Any?) -> CoachInsightPriority? {
        guard let rawValue = value as? String,
              rawValue == "high" || rawValue == "critical" else {
            return nil
        }
        return CoachInsightPriority(rawValue: rawValue)
    }

    private static func validatedTopic(_ value: Any?) throws -> String {
        guard let topic = value as? String else {
            throw ContractFailure(category: .invalidCandidate)
        }
        let pattern = #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#
        guard !topic.isEmpty,
              topic.count <= 64,
              topic.range(of: pattern, options: .regularExpression) != nil else {
            throw ContractFailure(category: .invalidTopic)
        }
        return topic
    }

    private static func normalizedQuestion(_ question: String) throws -> String {
        guard !question.contains(";"),
              !containsUnsafeScalar(question) else {
            throw ContractFailure(category: .invalidText)
        }
        let normalized = collapseWhitespace(question.precomposedStringWithCanonicalMapping)
        guard normalized.last == "?" else {
            throw ContractFailure(category: .invalidText)
        }
        let body = normalized.dropLast()
        guard !body.isEmpty,
              !body.contains(where: { $0 == "." || $0 == "!" || $0 == "?" }),
              let firstWord = body.split(whereSeparator: { !$0.isLetter }).first,
              body.hasPrefix(firstWord),
              interrogativeHeads.contains(firstWord.lowercased()) else {
            throw ContractFailure(category: .invalidText)
        }
        return normalized
    }

    private static func normalizedText(
        _ text: String,
        category: CoachAutoAdmissionRejectionCategory
    ) throws -> String {
        guard !containsUnsafeScalar(text) else {
            throw ContractFailure(category: category)
        }
        return collapseWhitespace(text.precomposedStringWithCanonicalMapping)
    }

    private static func collapseWhitespace(_ text: String) -> String {
        var normalized = ""
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            if isCollapsibleWhitespace(scalar) {
                if !normalized.isEmpty { pendingSpace = true }
                continue
            }
            if pendingSpace {
                normalized.append(" ")
                pendingSpace = false
            }
            normalized.append(String(scalar))
        }
        return normalized
    }

    private static func containsUnsafeScalar(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let value = scalar.value
            if value <= 0x1F || (0x7F...0x9F).contains(value) { return true }
            switch value {
            case 0x061C, 0x200B...0x200F, 0x202A...0x202E, 0x2060,
                 0x2066...0x2069, 0xFEFF:
                return true
            default:
                return false
            }
        }
    }

    private static func isCollapsibleWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0020, 0x00A0, 0x1680, 0x2000...0x200A, 0x202F, 0x205F, 0x3000:
            return true
        default:
            return false
        }
    }

    private static func validateDerivedContent(_ content: String) throws {
        let wordCount = content.split(separator: " ").count
        guard content.unicodeScalars.count <= 180, wordCount <= 24 else {
            throw ContractFailure(category: .invalidText)
        }
    }

    private static func strictInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        let type = String(cString: number.objCType)
        guard type != "c", type != "B", type != "f", type != "d" else { return nil }
        let value = number.doubleValue
        guard value.isFinite,
              abs(value) <= Double(maximumSafeInteger),
              let integer = Int(exactly: value) else { return nil }
        return integer
    }

    private static func isPositiveSafeInteger(_ value: Int) -> Bool {
        value > 0 && value <= maximumSafeInteger
    }

    private static func hasExactKeys(
        _ dictionary: [String: Any],
        _ expectedKeys: Set<String>
    ) -> Bool {
        Set(dictionary.keys) == expectedKeys
    }
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
            guard content.unicodeScalars.count <= maxContentCharacters,
                  content.split(separator: " ").count <= maxContentWords else {
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

    private func normalizedTopic(_ topic: String) -> String {
        topic.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
