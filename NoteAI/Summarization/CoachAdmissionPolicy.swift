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
            let commitmentFacts = affirmativeCommitmentFacts(in: content)
            if candidate.type == .actionItem && candidate.basis != .transcript {
                rejections.append(.init(candidateIndex: index, reason: .unsupportedCommitment))
                continue
            }
            if candidate.basis != .transcript && !commitmentFacts.isEmpty {
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
            if candidate.basis == .transcript &&
                (candidate.type == .actionItem || !commitmentFacts.isEmpty) {
                let factsToGround = commitmentFacts.isEmpty
                    ? [syntheticCommitmentFact(in: content)]
                    : commitmentFacts
                let sourceSegments = uniqueSourceIDs.compactMap { transcriptByID[$0] }
                guard factsToGround.allSatisfy({ fact in
                    sourceSegments.contains(where: {
                        transcriptEvidence($0.text, supportsCommitment: fact)
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

    private struct CommitmentFact {
        let actorAnchors: Set<String>
        let actionAnchor: String?
        let objectAnchors: Set<String>
        let timingAnchors: Set<String>
        let isAffirmative: Bool
        let isSynthetic: Bool
    }

    private struct CommitmentPredicateMatch {
        let range: Range<String.Index>
        let text: String
        let sharedAuxiliaryBoundaryRange: Range<String.Index>?

        var sharesAuxiliary: Bool {
            sharedAuxiliaryBoundaryRange != nil
        }
    }

    private struct CommitmentQualifierState {
        let isInquiry: Bool
        let isAntiAssumptionAdvice: Bool
        let isEpistemicallyAbsent: Bool
        let isPrefixNegated: Bool

        var isQualified: Bool {
            isInquiry || isAntiAssumptionAdvice || isEpistemicallyAbsent || isPrefixNegated
        }

        func merging(_ other: CommitmentQualifierState) -> CommitmentQualifierState {
            CommitmentQualifierState(
                isInquiry: isInquiry || other.isInquiry,
                isAntiAssumptionAdvice: isAntiAssumptionAdvice || other.isAntiAssumptionAdvice,
                isEpistemicallyAbsent: isEpistemicallyAbsent || other.isEpistemicallyAbsent,
                isPrefixNegated: isPrefixNegated || other.isPrefixNegated
            )
        }
    }

    private enum PredicateBoundaryKind {
        case strong
        case coordinating
    }

    private struct PredicateBoundary {
        let range: Range<String.Index>
        let kind: PredicateBoundaryKind
    }

    private func affirmativeCommitmentFacts(in content: String) -> [CommitmentFact] {
        commitmentFacts(in: content).filter(\.isAffirmative)
    }

    private func commitmentFacts(in content: String) -> [CommitmentFact] {
        commitmentClauses(in: content).flatMap(commitmentFacts(inClause:))
    }

    private func commitmentClauses(in content: String) -> [String] {
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
        return clauses
    }

    private func commitmentFacts(inClause clause: String) -> [CommitmentFact] {
        let predicates = commitmentPredicateMatches(in: clause)
        let boundaries = predicates.enumerated().map { index, predicate in
            predicateBoundary(
                in: clause,
                before: predicate,
                after: index > 0 ? predicates[index - 1] : nil
            )
        }
        var facts: [CommitmentFact] = []
        var priorActorAnchors: Set<String> = []
        var priorQualifierState: CommitmentQualifierState?
        var priorPredicateWasNegated = false

        for (index, predicate) in predicates.enumerated() {
            let boundary = boundaries[index]
            let localStart = boundary?.range.upperBound ?? clause.startIndex
            let localEnd: String.Index
            if index + 1 < predicates.count {
                localEnd = boundaries[index + 1]?.range.lowerBound ?? predicates[index + 1].range.lowerBound
            } else {
                localEnd = clause.endIndex
            }

            let localPrefix = String(clause[localStart..<predicate.range.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let predicateSuffix = String(clause[predicate.range.upperBound..<localEnd])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let explicitActors = actorAnchors(in: localPrefix, predicateText: predicate.text)
            let isCoordinatedContinuation = boundary?.kind == .coordinating && explicitActors.isEmpty
            let actors = isCoordinatedContinuation ? priorActorAnchors : explicitActors
            priorActorAnchors = actors
            let localQualifierState = qualifierState(
                in: localPrefix,
                isQuestion: isPredicateQuestion(in: clause, predicateRange: predicate.range)
            )
            let qualifierState = isCoordinatedContinuation
                ? priorQualifierState?.merging(localQualifierState) ?? localQualifierState
                : localQualifierState
            priorQualifierState = qualifierState
            let factText = predicate.text + " " + predicateSuffix
            var factTimingAnchors = timingAnchors(in: factText)
            if factTimingAnchors.isEmpty {
                factTimingAnchors = sharedAuxiliaryTimingAnchors(
                    in: clause,
                    after: index,
                    predicates: predicates,
                    boundaries: boundaries
                )
            }
            let predicateIsNegated = isPredicateNegated(predicate.text) ||
                (predicate.sharesAuxiliary && isCoordinatedContinuation && priorPredicateWasNegated)
            priorPredicateWasNegated = predicateIsNegated

            facts.append(CommitmentFact(
                actorAnchors: actors,
                actionAnchor: actionAnchor(in: factText),
                objectAnchors: distinctiveGroundingTokens(predicateSuffix),
                timingAnchors: factTimingAnchors,
                isAffirmative: !qualifierState.isQualified && !predicateIsNegated,
                isSynthetic: false
            ))
        }

        return facts
    }

    private func commitmentPredicateMatches(in clause: String) -> [CommitmentPredicateMatch] {
        let primaryMatches = ranges(matching: commitmentPredicatePattern(), in: clause).map {
            CommitmentPredicateMatch(
                range: $0,
                text: String(clause[$0]),
                sharedAuxiliaryBoundaryRange: nil
            )
        }
        let modifier = #"(?:[\p{L}]+ly|also|even|just|still)\s+"#
        let sharedActionPattern = #"(?i)(?:,\s*)?\b(?:and|or)\b[\s,:]*((?:(?:not|never)\s+)?(?:"#
            + modifier + #")*"# + commitmentActionPattern() + #")\b"#
        let sharedMatches = capturedRanges(
            matching: sharedActionPattern,
            captureGroup: 1,
            in: clause
        ).map { match in
            CommitmentPredicateMatch(
                range: match.capture,
                text: String(clause[match.capture]),
                sharedAuxiliaryBoundaryRange: match.full.lowerBound..<match.capture.lowerBound
            )
        }
        let candidates = (primaryMatches + sharedMatches).sorted {
            if $0.range.lowerBound == $1.range.lowerBound {
                return $0.range.upperBound < $1.range.upperBound
            }
            return $0.range.lowerBound < $1.range.lowerBound
        }
        var accepted: [CommitmentPredicateMatch] = []

        for candidate in candidates {
            if let boundaryRange = candidate.sharedAuxiliaryBoundaryRange {
                guard let previous = accepted.last,
                      previous.range.upperBound <= boundaryRange.lowerBound,
                      !containsStrongPredicateBoundary(
                          String(clause[previous.range.upperBound..<boundaryRange.lowerBound])
                      ) else {
                    continue
                }
            }
            accepted.append(candidate)
        }
        return accepted
    }

    private func containsStrongPredicateBoundary(_ text: String) -> Bool {
        text.range(
            of: #"(?i)\b(?:but|however|yet|although|though|whereas|because|therefore|thus|hence|so|since|then|while|nevertheless)\b"#,
            options: .regularExpression
        ) != nil
    }

    private func sharedAuxiliaryTimingAnchors(
        in clause: String,
        after predicateIndex: Int,
        predicates: [CommitmentPredicateMatch],
        boundaries: [PredicateBoundary?]
    ) -> Set<String> {
        var nextIndex = predicateIndex + 1
        var sharedEnd: String.Index?

        while nextIndex < predicates.count,
              predicates[nextIndex].sharesAuxiliary,
              boundaries[nextIndex]?.kind == .coordinating {
            if nextIndex + 1 < predicates.count {
                sharedEnd = boundaries[nextIndex + 1]?.range.lowerBound ?? predicates[nextIndex + 1].range.lowerBound
            } else {
                sharedEnd = clause.endIndex
            }
            nextIndex += 1
        }

        guard let sharedEnd else { return [] }
        return timingAnchors(in: String(clause[predicates[predicateIndex].range.upperBound..<sharedEnd]))
    }

    private func predicateBoundary(
        in clause: String,
        before predicate: CommitmentPredicateMatch,
        after previousPredicate: CommitmentPredicateMatch?
    ) -> PredicateBoundary? {
        let searchStart = previousPredicate?.range.upperBound ?? clause.startIndex
        let searchRange = searchStart..<predicate.range.lowerBound
        var candidates: [PredicateBoundary] = []
        let strongWord = #"(?i)\b(?:but|however|yet|although|though|whereas|because|therefore|thus|hence|so|since|then|while|nevertheless)\b[\s,:]*"#
        if let range = lastRange(matching: strongWord, in: clause, within: searchRange) {
            candidates.append(PredicateBoundary(range: range, kind: .strong))
        }

        let coordinating = #"(?i)(?:,\s*)?\b(?:and|or)\b[\s,:]*"#
        let coordinatingRange: Range<String.Index>?
        if previousPredicate != nil {
            coordinatingRange = lastRange(matching: coordinating, in: clause, within: searchRange)
        } else if let range = lastRange(matching: coordinating, in: clause, within: searchRange),
                  prefixIntroducesPredicate(String(clause[searchStart..<range.lowerBound])) {
            coordinatingRange = range
        } else {
            coordinatingRange = nil
        }
        if let coordinatingRange {
            candidates.append(PredicateBoundary(range: coordinatingRange, kind: .coordinating))
        }

        if let commaRange = lastRange(matching: #","#, in: clause, within: searchRange),
           !(coordinatingRange?.contains(commaRange.lowerBound) ?? false),
           (previousPredicate != nil || commaIntroducesPredicate(
               in: clause,
               commaRange: commaRange,
               before: predicate.range.lowerBound
           )) {
            candidates.append(PredicateBoundary(range: commaRange, kind: .strong))
        }

        return candidates.max { left, right in
            if left.range.lowerBound == right.range.lowerBound {
                return left.range.upperBound < right.range.upperBound
            }
            return left.range.lowerBound < right.range.lowerBound
        }
    }

    private func lastRange(
        matching pattern: String,
        in text: String,
        within searchRange: Range<String.Index>
    ) -> Range<String.Index>? {
        ranges(matching: pattern, in: text).last {
            $0.lowerBound >= searchRange.lowerBound && $0.upperBound <= searchRange.upperBound
        }
    }

    private func prefixIntroducesPredicate(_ prefix: String) -> Bool {
        let words = normalizedGroundingWords(prefix)
        if let linkerIndex = words.lastIndex(where: { Self.qualifierLinkWords.contains($0) }),
           Set(words.dropFirst(linkerIndex + 1)).isDisjoint(with: Self.predicateSignalWords) {
            return false
        }
        return !Set(words).isDisjoint(with: Self.predicateSignalWords)
    }

    private func commaIntroducesPredicate(
        in clause: String,
        commaRange: Range<String.Index>,
        before predicateStart: String.Index
    ) -> Bool {
        let suffixWords = normalizedGroundingWords(String(clause[commaRange.upperBound..<predicateStart]))
        guard let firstWord = suffixWords.first,
              !Self.qualifierLinkWords.contains(firstWord) else {
            return false
        }
        return prefixIntroducesPredicate(String(clause[..<commaRange.lowerBound]))
    }

    private func commitmentPredicatePattern() -> String {
        let action = commitmentActionPattern()
        let contractedActor = #"[\p{L}][\p{L}\p{N}_-]*['’]"#
        let modifier = #"(?:[\p{L}]+ly|also|even|just|still)\s+"#
        let modifiers = #"(?:"# + modifier + #")*"#
        let willAction = modifiers
            + #"(?:(?:not|never)\s+)?"#
            + modifiers
            + #"(?:be\s+"# + modifiers + #")?"#
            + action
        return #"(?i)\b(?:"#
            + #"will\s+"# + willAction
            + #"|won['’]t\s+(?:be\s+)?"# + modifiers + action
            + #"|"# + contractedActor + #"ll\s+"# + willAction
            + #"|(?:plans?|intends?|expects?)\s+(?:(?:not|never)\s+)?to\s+(?:be\s+)?"# + modifiers + action
            + #"|(?:am|is|are)\s+(?:(?:not|never)\s+)?going\s+to\s+(?:be\s+)?"# + action
            + #"|(?:am|is|are)\s+(?:(?:not|never)\s+)?gonna\s+(?:be\s+)?"# + action
            + #"|(?:isn['’]t|aren['’]t)\s+going\s+to\s+(?:be\s+)?"# + action
            + #"|(?:isn['’]t|aren['’]t)\s+gonna\s+(?:be\s+)?"# + action
            + #"|"# + contractedActor + #"(?:m|re|s)\s+(?:(?:not|never)\s+)?going\s+to\s+(?:be\s+)?"# + action
            + #"|"# + contractedActor + #"(?:m|re|s)\s+(?:(?:not|never)\s+)?gonna\s+(?:be\s+)?"# + action
            + #"|committed|agreed|promised)\b"#
    }

    private func commitmentActionPattern() -> String {
        #"(?:complete|completing|deliver|delivering|email|emailing|follow\s+up|following\s+up|provide|providing|review|reviewing|send|sending|share|sharing|submit|submitting|upload|uploading)"#
    }

    private func actionAnchor(in text: String) -> String? {
        let actions = [
            (#"(?i)\b(?:complete|completing)\b"#, "complete"),
            (#"(?i)\b(?:deliver|delivering)\b"#, "deliver"),
            (#"(?i)\b(?:email|emailing)\b"#, "email"),
            (#"(?i)\b(?:follow\s+up|following\s+up)\b"#, "follow_up"),
            (#"(?i)\b(?:provide|providing)\b"#, "provide"),
            (#"(?i)\b(?:review|reviewing)\b"#, "review"),
            (#"(?i)\b(?:send|sending)\b"#, "send"),
            (#"(?i)\b(?:share|sharing)\b"#, "share"),
            (#"(?i)\b(?:submit|submitting)\b"#, "submit"),
            (#"(?i)\b(?:upload|uploading)\b"#, "upload"),
        ]
        return actions.compactMap { pattern, anchor -> (String.Index, String)? in
            text.range(of: pattern, options: .regularExpression).map { ($0.lowerBound, anchor) }
        }.min { $0.0 < $1.0 }?.1
    }

    private func isPredicateQuestion(
        in clause: String,
        predicateRange: Range<String.Index>
    ) -> Bool {
        guard clause.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") else {
            return false
        }
        let boundary = #"(?:and|or|but|however|yet|although|though|whereas|because|therefore|thus|hence|so|since|then|while|nevertheless)"#
        let interrogative = #"(?:will|won['’]t|can|could|should|would|do|does|did|is|are|am|how|when|what|why|who|where)"#
        let mixedQuestion = #"(?i)(?:,\s*(?:"# + boundary + #"\b[\s,:]*)?|\b"#
            + boundary + #"\b[\s,:]*)"# + interrogative + #"\b"#
        let suffix = String(clause[predicateRange.upperBound...])
        let tagQuestion = #"(?i),\s*(?:right|correct|ok(?:ay)?|"#
            + #"(?:is|are|was|were|do|does|did|has|have|can|could|should|would|will|"#
            + #"won['’]t|isn['’]t|aren['’]t|don['’]t|doesn['’]t|didn['’]t|hasn['’]t|haven['’]t)\b[^,;?.]*)\?[.!?]*\s*$"#
        if suffix.range(of: tagQuestion, options: .regularExpression) != nil {
            return false
        }
        return suffix.range(of: mixedQuestion, options: .regularExpression) == nil
    }

    private func qualifierState(
        in localPrefix: String,
        isQuestion: Bool
    ) -> CommitmentQualifierState {
        CommitmentQualifierState(
            isInquiry: isCommitmentInquiry(localPrefix, isQuestion: isQuestion),
            isAntiAssumptionAdvice: isAntiAssumptionAdvice(localPrefix),
            isEpistemicallyAbsent: isEpistemicallyAbsent(localPrefix),
            isPrefixNegated: isPrefixNegated(localPrefix)
        )
    }

    private func isCommitmentInquiry(_ localPrefix: String, isQuestion: Bool) -> Bool {
        if isQuestion { return true }
        let inquiryCue = #"(?:whether|if|when|how|what|why|who|where)"#
        let inquiryVerb = #"(?:ask(?:s|ed|ing)?|check(?:s|ed|ing)?|clarif(?:y|ies|ied|ying)|confirm(?:s|ed|ing)?|determin(?:e|es|ed|ing)|prob(?:e|es|ed|ing)|verif(?:y|ies|ied|ying)|wonder(?:s|ed|ing)?)"#
        let qualifiedInquiry = #"(?i)\b"# + inquiryVerb + #"\b[\s\S]*\b"# + inquiryCue + #"\b"#
        let embeddedInquiry = #"(?i)^(?:and\s+|or\s+)?"# + inquiryCue + #"\b"#
        return localPrefix.range(of: qualifiedInquiry, options: .regularExpression) != nil ||
            localPrefix.range(of: embeddedInquiry, options: .regularExpression) != nil
    }

    private func isAntiAssumptionAdvice(_ localPrefix: String) -> Bool {
        localPrefix.range(
            of: #"(?i)^(?:please\s+)?(?:do\s+not|don['’]t|never)\s+(?:assume|infer|presume|claim|state|treat)\b"#,
            options: .regularExpression
        ) != nil
    }

    private func isEpistemicallyAbsent(_ localPrefix: String) -> Bool {
        let patterns = [
            #"(?i)\b(?:no\s+(?:evidence|indication|confirmation|proof|guarantee)|insufficient\s+(?:evidence|indication|confirmation|proof)|(?:not|never)(?:\s+yet)?\s+confirm(?:ed|ing)?|cannot\s+confirm|can['’]t\s+confirm|unconfirmed)\b"#,
            #"(?i)\b(?:(?:remain(?:s|ed|ing)?\s+)?(?:unclear|uncertain|unknown)|(?:do|does|did)\s+not\s+know|(?:don|doesn|didn)['’]t\s+know|cannot\s+know|can['’]t\s+know)\b"#,
            #"(?i)\brequest(?:s|ed|ing)?\s+(?:(?:additional|explicit|further)\s+)?confirmation\b"#,
            #"(?i)\b(?:(?:am|is|are|was|were)\s+(?:still\s+)?not\s+(?:entirely\s+)?sure|(?:isn|aren|wasn|weren)['’]t\s+(?:entirely\s+)?sure)\b"#,
            #"(?i)\b(?:i|we|they|he|she|it|customer|partner|team|speaker)\s+doubt(?:s|ed|ing)?\b"#,
        ]
        return patterns.contains {
            localPrefix.range(of: $0, options: .regularExpression) != nil
        }
    }

    private func isPrefixNegated(_ localPrefix: String) -> Bool {
        return localPrefix.range(
            of: #"(?i)(?:\b(?:not|never)|n['’]t)(?:\s+(?:actually|currently|ever|explicitly|formally|previously|yet))*\s*$"#,
            options: .regularExpression
        ) != nil
    }

    private func isPredicateNegated(_ predicateText: String) -> Bool {
        let withoutNotOnly = predicateText.replacingOccurrences(
            of: #"(?i)\bnot\s+only\b"#,
            with: "",
            options: .regularExpression
        )
        return withoutNotOnly.range(
            of: #"(?i)(?:\b(?:not|never)\b|n['’]t\b)"#,
            options: .regularExpression
        ) != nil
    }

    private func syntheticCommitmentFact(in content: String) -> CommitmentFact {
        let actors = syntheticActorAnchors(in: content)
        let timing = timingAnchors(in: content)
        let object = distinctiveGroundingTokens(content)
            .subtracting(actors)
        return CommitmentFact(
            actorAnchors: actors,
            actionAnchor: actionAnchor(in: content),
            objectAnchors: object,
            timingAnchors: timing,
            isAffirmative: true,
            isSynthetic: true
        )
    }

    private func transcriptEvidence(
        _ evidence: String,
        supportsCommitment candidate: CommitmentFact
    ) -> Bool {
        affirmativeCommitmentFacts(in: evidence).contains { evidenceFact in
            factsAreCompatible(candidate: candidate, evidence: evidenceFact)
        }
    }

    private func factsAreCompatible(candidate: CommitmentFact, evidence: CommitmentFact) -> Bool {
        if candidate.isSynthetic,
           candidate.actorAnchors.isEmpty,
           candidate.objectAnchors.isEmpty,
           candidate.timingAnchors.isEmpty {
            return false
        }
        if !candidate.actorAnchors.isEmpty,
           candidate.actorAnchors.isDisjoint(with: evidence.actorAnchors) {
            return false
        }
        if let candidateAction = candidate.actionAnchor,
           candidateAction != evidence.actionAnchor {
            return false
        }
        if !candidate.timingAnchors.isEmpty,
           !candidate.timingAnchors.isSubset(of: evidence.timingAnchors) {
            return false
        }
        if !candidate.objectAnchors.isEmpty,
           !candidate.objectAnchors.isSubset(of: evidence.objectAnchors) {
            return false
        }
        return true
    }

    private func actorAnchors(in localPrefix: String, predicateText: String) -> Set<String> {
        let speakerAnchor = speakerLabelActorAnchor(in: localPrefix)
        if let contractedActor = firstCapture(
            matching: #"(?i)^([\p{L}][\p{L}\p{N}_-]*)['’](?:ll|m|re|s)\b"#,
            in: predicateText
        ), let actorAnchor = canonicalActorPhrase([contractedActor.lowercased()]) {
            if Self.firstPersonActorAnchors.contains(actorAnchor), let speakerAnchor {
                return [speakerAnchor]
            }
            return [actorAnchor]
        }

        let actorSource: String
        if let colon = localPrefix.lastIndex(of: ":") {
            actorSource = String(localPrefix[localPrefix.index(after: colon)...])
        } else {
            actorSource = localPrefix
        }
        if let actorAnchor = grammaticalActorAnchor(in: actorSource) {
            if Self.firstPersonActorAnchors.contains(actorAnchor), let speakerAnchor {
                return [speakerAnchor]
            }
            return [actorAnchor]
        }
        return speakerAnchor.map { [$0] } ?? []
    }

    private func speakerLabelActorAnchor(in text: String) -> String? {
        guard let colon = text.lastIndex(of: ":") else { return nil }
        return grammaticalActorAnchor(in: String(text[..<colon]))
    }

    private func grammaticalActorAnchor(in text: String) -> String? {
        var words = normalizedGroundingWords(text)
        if let delimiterIndex = words.lastIndex(where: { Self.actorSubjectDelimiterWords.contains($0) }) {
            words = Array(words.dropFirst(delimiterIndex + 1))
        }
        while let last = words.last,
              Self.actorTrailingScaffoldingWords.contains(last) || last.hasSuffix("ly") {
            words.removeLast()
        }
        while let first = words.first, Self.actorLeadingScaffoldingWords.contains(first) {
            words.removeFirst()
        }
        return canonicalActorPhrase(words)
    }

    private func canonicalActorPhrase(_ words: [String]) -> String? {
        let canonicalWords = words
            .filter { !Self.actorPhraseIgnoredWords.contains($0) }
            .map(canonicalActorWord)
        let specificWords = canonicalWords.filter { !Self.genericActorRoleWords.contains($0) }
        let chosenWords = specificWords.isEmpty ? canonicalWords : specificWords
        let phrase = chosenWords.joined(separator: " ")
        return phrase.isEmpty ? nil : phrase
    }

    private func canonicalActorWord(_ word: String) -> String {
        Self.canonicalActorWords[word] ?? word
    }

    private func syntheticActorAnchors(in text: String) -> Set<String> {
        var anchors = Set(normalizedGroundingWords(text).filter {
            Self.explicitActorWords.contains($0)
        }.map(canonicalActorWord))
        anchors.formUnion(captures(
            matching: #"(?i)\b([\p{L}][\p{L}\p{N}_-]*)['’]s\b"#,
            in: text
        ).map { canonicalActorWord($0.lowercased()) })
        if let speakerAnchor = speakerLabelActorAnchor(in: text) {
            anchors.insert(speakerAnchor)
        }
        return anchors
    }

    private func timingAnchors(in text: String) -> Set<String> {
        let day = #"(?:monday|mon|tuesday|tues?|wednesday|wed|thursday|thurs?|fri(?:day)?|saturday|sat|sunday|sun)"#
        let period = #"(?:day|week|month|quarter|year)"#
        let month = #"(?:january|february|march|april|may|june|july|august|september|october|november|december)"#
        let pattern = #"(?i)\b(?:(?:by\s+)?(?:the\s+)?end\s+of\s+(?:the\s+)?(?:business\s+)?"# + period
            + #"|(?:next|this|last)\s+(?:"# + period + #"|"# + day + #")"#
            + #"|(?:first|second|third|fourth)\s+quarter|q[1-4]"#
            + #"|today|tomorrow|tonight|yesterday|soon|later|morning|afternoon|evening|"#
            + day + #"|"# + month + #")\b"#
        return Set(ranges(matching: pattern, in: text).map {
            normalizedGroundingWords(String(text[$0]))
                .filter { $0 != "by" && $0 != "the" }
                .map { Self.canonicalTimingWords[$0] ?? $0 }
                .joined(separator: " ")
        })
    }

    private func capturedRanges(
        matching pattern: String,
        captureGroup: Int,
        in text: String
    ) -> [(full: Range<String.Index>, capture: Range<String.Index>)] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text)
        ).compactMap { match in
            guard match.numberOfRanges > captureGroup,
                  let fullRange = Range(match.range, in: text),
                  let captureRange = Range(match.range(at: captureGroup), in: text) else {
                return nil
            }
            return (fullRange, captureRange)
        }
    }

    private func ranges(matching pattern: String, in text: String) -> [Range<String.Index>] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text)
        ).compactMap { Range($0.range, in: text) }
    }

    private func captures(matching pattern: String, in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text)
        ).compactMap { match in
            guard match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
    }

    private func firstCapture(matching pattern: String, in text: String) -> String? {
        captures(matching: pattern, in: text).first
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

    private static let predicateSignalWords: Set<String> = [
        "am", "are", "ask", "asked", "asking", "asks", "check", "checked", "checking", "checks",
        "clarified", "confirmed", "determined", "doubt", "doubted", "doubting", "doubts", "had", "has", "have",
        "is", "probed", "reported", "said",
        "request", "requested", "requesting", "requests", "verified", "was", "were", "wonder", "wondered",
        "wondering", "wonders",
    ]

    private static let qualifierLinkWords: Set<String> = [
        "how", "if", "that", "what", "when", "where", "whether", "which", "who", "why",
    ]

    private static let firstPersonActorAnchors: Set<String> = ["i", "we"]

    private static let actorSubjectDelimiterWords: Set<String> = [
        "ask", "asked", "asking", "asks", "assume", "assumed", "assuming", "check", "checked", "checking",
        "checks", "claim", "claimed", "claims", "clarified", "clarifies", "clarify", "clarifying", "confirm",
        "confirmation", "confirmed", "confirming", "confirms", "determined", "determines", "determining",
        "doubt", "doubted", "doubting", "doubts", "evidence", "how", "if", "indication", "infer", "inferred",
        "infers", "know", "knew", "knows",
        "presume", "presumed", "presumes", "probe", "probed", "probes", "report", "reported", "reports",
        "requested", "requesting", "requests", "said", "say", "says", "state", "stated", "states", "suggest",
        "suggested", "suggests", "that",
        "told", "treat", "treated", "treats", "uncertain", "unclear", "unknown", "verified", "verifies",
        "verify", "verifying", "what", "when", "where", "whether", "which", "who", "why", "wondered",
        "wondering", "wonders",
    ]

    private static let actorTrailingScaffoldingWords: Set<String> = [
        "actually", "also", "am", "are", "can", "cannot", "certainly", "currently", "definitely", "did",
        "do", "does", "eventually", "explicitly", "formally", "had", "has", "have", "is", "likely", "never",
        "not", "personally", "probably", "still", "t", "tentatively", "was", "were", "will", "won", "would",
        "yet",
    ]

    private static let actorLeadingScaffoldingWords: Set<String> = [
        "a", "an", "please", "the", "without",
    ]

    private static let actorPhraseIgnoredWords: Set<String> = [
        "a", "an", "and", "or", "s", "t", "the",
    ]

    private static let genericActorRoleWords: Set<String> = [
        "company", "group", "organization", "rep", "representative", "team",
    ]

    private static let canonicalActorWords: [String: String] = [
        "clients": "client",
        "companies": "company",
        "customers": "customer",
        "groups": "group",
        "organizations": "organization",
        "partners": "partner",
        "representatives": "representative",
        "speakers": "speaker",
        "teams": "team",
        "users": "user",
        "vendors": "vendor",
    ]

    private static let explicitActorWords: Set<String> = [
        "client", "clients", "customer", "customers", "i", "owner", "owners", "partner", "partners",
        "speaker", "speakers", "team", "teams", "user", "users", "vendor", "vendors", "we",
    ]

    private static let canonicalTimingWords: [String: String] = [
        "fri": "friday",
        "mon": "monday",
        "sat": "saturday",
        "sun": "sunday",
        "thu": "thursday",
        "thur": "thursday",
        "thurs": "thursday",
        "tue": "tuesday",
        "tues": "tuesday",
        "wed": "wednesday",
    ]

    private static let genericGroundingWords: Set<String> = [
        "a", "about", "after", "again", "all", "also", "although", "an", "and", "any", "as", "at",
        "because", "before", "but", "by", "for", "from", "has", "have", "hence", "however", "if", "in",
        "into", "nevertheless", "of", "on", "or", "since", "so", "that", "the", "then", "there", "therefore",
        "these", "this", "those", "though", "thus", "to", "was", "were", "what", "when", "where", "whereas",
        "while", "yet",
        "whether", "which", "who", "why", "with",
        "customer", "client", "partner", "speaker", "team", "person", "people", "i", "me", "my", "mine",
        "we", "us", "our", "ours", "you", "your", "yours", "they", "them", "their", "theirs", "he",
        "him", "his", "she", "her", "hers", "it", "its",
        "ll", "m", "re", "s", "t", "won", "will", "be", "been", "being", "am", "is", "are", "go", "going", "plan", "plans", "planned",
        "planning", "intend", "intends", "intended", "intending", "expect", "expects", "expected",
        "expecting", "commit", "commits", "committed", "commitment", "commitments", "agree", "agrees",
        "agreed", "agreement", "promise", "promises", "promised",
        "complete", "completes", "completed", "completing", "deliver", "delivers", "delivered", "delivering",
        "email", "emails", "emailed", "emailing",
        "follow", "follows", "followed", "following", "up", "provide", "provides", "provided", "providing",
        "review", "reviews", "reviewed", "reviewing",
        "send", "sends", "sent", "sending", "share", "shares", "shared", "sharing", "submit", "submits",
        "submitted", "submitting", "upload", "uploads", "uploaded", "uploading",
        "ask", "asks", "asked", "asking", "check", "checked", "checking", "clarified",
        "confirm", "confirmation", "confirmed", "clarify", "cannot", "determine", "determined", "do", "does", "did",
        "evidence", "indication", "never", "no", "not", "please", "probe", "probed", "recommend", "suggest",
        "track", "unconfirmed", "uncertain", "unclear", "unknown", "know", "knows", "knew", "remains",
        "verify", "verified", "discuss", "discussed", "discussion",
        "actually", "also", "certainly", "definitely", "even", "eventually", "explicitly", "formally", "just",
        "likely", "personally", "probably", "still", "tentatively",
        "today", "tomorrow", "tonight", "yesterday", "soon", "later", "next", "time", "timing", "business", "day",
        "week", "month", "quarter", "year", "morning", "afternoon", "evening", "date", "deadline", "end",
        "first", "second", "third", "fourth", "last", "q1", "q2", "q3", "q4",
        "mon", "monday", "tue", "tues", "tuesday", "wed", "wednesday", "thu", "thur", "thurs", "thursday",
        "fri", "friday", "sat", "saturday", "sun", "sunday", "january", "february",
        "march", "april", "may", "june", "july", "august", "september", "october", "november", "december",
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
