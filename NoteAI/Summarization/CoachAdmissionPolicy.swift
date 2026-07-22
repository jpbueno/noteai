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
            let commitmentClaims = unqualifiedCommitmentClaims(in: content)
            if candidate.basis == .transcript &&
                (candidate.type == .actionItem || !commitmentClaims.isEmpty) {
                let claimsToGround = commitmentClaims.isEmpty ? [content] : commitmentClaims
                let sourceSegments = uniqueSourceIDs.compactMap { transcriptByID[$0] }
                guard claimsToGround.allSatisfy({ claim in
                    sourceSegments.contains(where: {
                        transcriptEvidence($0.text, supportsCommitment: claim)
                    })
                }) else {
                    rejections.append(.init(candidateIndex: index, reason: .unsupportedCommitment))
                    continue
                }
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
        !unqualifiedCommitmentClaims(in: content).isEmpty
    }

    private func unqualifiedCommitmentClaims(in content: String) -> [String] {
        commitmentScopes(in: content).filter { scope in
            containsCommitmentClaim(scope) &&
                !isCommitmentInquiry(scope) &&
                !isNegatedCommitmentAdvice(scope)
        }
    }

    private func commitmentScopes(in content: String) -> [String] {
        var clauses: [String] = []
        var currentClause = ""
        let terminators: Set<Character> = [";", ".", "!", "?", "\n"]

        for character in content {
            currentClause.append(character)
            if terminators.contains(character) {
                let clause = currentClause.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clause.isEmpty { clauses.append(clause) }
                currentClause = ""
            }
        }

        let trailingClause = currentClause.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trailingClause.isEmpty { clauses.append(trailingClause) }
        return clauses.flatMap(localCommitmentScopes)
    }

    private func localCommitmentScopes(in clause: String) -> [String] {
        let boundary = #"(?:but|however|although|though|whereas|because|therefore|thus|hence|so|since|then)"#
        let boundaryAfterComma = #"(?:but|however|yet|although|though|whereas|because|therefore|thus|hence|so|since|then)"#
        let boundaryPattern = #"(?i)(?:,\s*"# + boundaryAfterComma + #"\b[\s,:]*|\s+"# + boundary + #"\b[\s,:]+)"#
        guard let expression = try? NSRegularExpression(pattern: boundaryPattern) else {
            return [clause]
        }

        let matches = expression.matches(
            in: clause,
            range: NSRange(clause.startIndex..<clause.endIndex, in: clause)
        )
        var scopes: [String] = []
        var start = clause.startIndex
        for match in matches {
            guard let range = Range(match.range, in: clause) else { continue }
            let scope = clause[start..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if !scope.isEmpty { scopes.append(scope) }
            start = range.upperBound
        }

        let trailingScope = clause[start...].trimmingCharacters(in: .whitespacesAndNewlines)
        if !trailingScope.isEmpty { scopes.append(trailingScope) }
        return scopes
    }

    private func containsCommitmentClaim(_ scope: String) -> Bool {
        let sanitizedScope = directlyNegatedCommitmentPatterns().reduce(scope) { result, pattern in
            result.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return affirmativeCommitmentPatterns().contains(where: {
            sanitizedScope.range(of: $0, options: .regularExpression) != nil
        })
    }

    private func affirmativeCommitmentPatterns() -> [String] {
        let action = commitmentActionPattern()
        return [
            #"(?i)\bwill\s+(?:be\s+)?"# + action + #"\b"#,
            #"(?i)\b(?:plans?|intends?|expects?)\s+to\s+"# + action + #"\b"#,
            #"(?i)\b(?:am|is|are)\s+going\s+to\s+"# + action + #"\b"#,
            #"(?i)\b(?:committed|agreed|promised)\b"#,
        ]
    }

    private func directlyNegatedCommitmentPatterns() -> [String] {
        let action = commitmentActionPattern()
        return [
            #"(?i)\b(?:(?:has|have|had|did|does|do|is|are|was|were)\s+)?(?:not|never)\s+(?:yet\s+)?(?:explicitly\s+)?(?:committed|agreed|promised)\b"#,
            #"(?i)\b(?:hasn't|haven't|hadn't|didn't|doesn't|don't|isn't|aren't|wasn't|weren't)\s+(?:yet\s+)?(?:explicitly\s+)?(?:committed|agreed|promised)\b"#,
            #"(?i)\bwill\s+(?:not|never)\s+(?:be\s+)?"# + action + #"\b"#,
            #"(?i)\bwon't\s+(?:be\s+)?"# + action + #"\b"#,
            #"(?i)\b(?:do|does|did)\s+(?:not|never)\s+(?:plan|intend|expect)\s+to\s+"# + action + #"\b"#,
            #"(?i)\b(?:don't|doesn't|didn't)\s+(?:plan|intend|expect)\s+to\s+"# + action + #"\b"#,
            #"(?i)\b(?:plans?|intends?|expects?)\s+(?:not|never)\s+to\s+"# + action + #"\b"#,
            #"(?i)\b(?:am|is|are)\s+(?:not|never)\s+going\s+to\s+"# + action + #"\b"#,
            #"(?i)\b(?:isn't|aren't)\s+going\s+to\s+"# + action + #"\b"#,
        ]
    }

    private func commitmentActionPattern() -> String {
        #"(?:complete|completing|deliver|delivering|follow\s+up|following\s+up|provide|providing|send|sending|share|sharing|submit|submitting)"#
    }

    private func isCommitmentInquiry(_ scope: String) -> Bool {
        if scope.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") { return true }
        guard let commitmentRange = firstCommitmentRange(in: scope) else { return false }

        let prefix = String(scope[..<commitmentRange.lowerBound])
        let localPrefix = (prefix.split(separator: ",", omittingEmptySubsequences: false).last
            .map(String.init) ?? prefix)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let inquiryCue = #"(?:whether|if|when|how|what|why|who|where)"#
        let qualifiedInquiry = #"(?i)^(?:please\s+)?(?:(?:recommend|suggest)\s+)?(?:ask(?:ing)?|check(?:ing)?|clarify(?:ing)?|confirm(?:ing)?|determine|probe|verify)\b[\s\S]*\b"#
            + inquiryCue + #"\b"#
        let embeddedInquiry = #"(?i)^(?:and\s+|or\s+)?"# + inquiryCue + #"\b"#
        return localPrefix.range(
            of: qualifiedInquiry,
            options: .regularExpression
        ) != nil || localPrefix.range(of: embeddedInquiry, options: .regularExpression) != nil
    }

    private func firstCommitmentRange(in scope: String) -> Range<String.Index>? {
        affirmativeCommitmentPatterns()
            .compactMap { scope.range(of: $0, options: .regularExpression) }
            .min { $0.lowerBound < $1.lowerBound }
    }

    private func isNegatedCommitmentAdvice(_ scope: String) -> Bool {
        scope.range(
            of: #"(?i)^\s*(?:do\s+not|don't|never)\s+(?:assume|infer|presume|claim|state|treat)\b"#,
            options: .regularExpression
        ) != nil
    }

    private func transcriptEvidence(_ evidence: String, supportsCommitment claim: String) -> Bool {
        unqualifiedCommitmentClaims(in: evidence).contains { evidenceClaim in
            isTextuallyGrounded(claim, in: evidenceClaim)
        }
    }

    private func isTextuallyGrounded(_ candidate: String, in evidence: String) -> Bool {
        let normalizedCandidate = normalizedGroundingWords(candidate).joined(separator: " ")
        let normalizedEvidence = normalizedGroundingWords(evidence).joined(separator: " ")
        if !normalizedCandidate.isEmpty && normalizedEvidence.contains(normalizedCandidate) {
            return true
        }

        let candidateTokens = distinctiveGroundingTokens(candidate)
        let evidenceTokens = distinctiveGroundingTokens(evidence)
        return !candidateTokens.isDisjoint(with: evidenceTokens)
    }

    private func distinctiveGroundingTokens(_ text: String) -> Set<String> {
        Set(normalizedGroundingWords(text)
            .filter { !Self.genericGroundingWords.contains($0) }
            .map(stem)
            .filter { $0.count > 1 && !Self.genericGroundingWords.contains($0) })
    }

    private func normalizedGroundingWords(_ text: String) -> [String] {
        text
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    private static let genericGroundingWords: Set<String> = [
        "a", "about", "after", "again", "all", "also", "an", "and", "any", "as", "at", "before",
        "by", "for", "from", "has", "have", "if", "in", "into", "of", "on", "or", "that", "the",
        "then", "there", "these", "this", "those", "to", "was", "were", "what", "when", "where",
        "whether", "which", "who", "why", "with",
        "customer", "client", "partner", "speaker", "team", "person", "people", "i", "me", "my", "mine",
        "we", "us", "our", "ours", "you", "your", "yours", "they", "them", "their", "theirs", "he",
        "him", "his", "she", "her", "hers", "it", "its",
        "will", "be", "been", "being", "am", "is", "are", "go", "going", "plan", "plans", "planned",
        "planning", "intend", "intends", "intended", "intending", "expect", "expects", "expected",
        "expecting", "commit", "commits", "committed", "commitment", "commitments", "agree", "agrees",
        "agreed", "agreement", "promise", "promises", "promised",
        "complete", "completes", "completed", "completing", "deliver", "delivers", "delivered", "delivering",
        "follow", "follows", "followed", "following", "up", "provide", "provides", "provided", "providing",
        "send", "sends", "sent", "sending", "share", "shares", "shared", "sharing", "submit", "submits",
        "submitted", "submitting", "ask", "asks", "asked", "asking", "check", "confirm", "clarify",
        "determine", "probe", "verify", "recommend", "track", "discuss", "discussed", "discussion",
        "today", "tomorrow", "tonight", "yesterday", "soon", "later", "next", "time", "timing", "day",
        "week", "month", "quarter", "year", "morning", "afternoon", "evening", "date", "deadline",
    ]

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
