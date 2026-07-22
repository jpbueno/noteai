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

private indirect enum StrictCoachJSONValue {
    case object([String: StrictCoachJSONValue])
    case array([StrictCoachJSONValue])
    case string(String)
    case number(String)
    case boolean(Bool)
    case null
}

/// Strict JSON grammar Module for untrusted automatic coach responses.
private struct StrictCoachJSONParser {
    private struct ParseFailure: Error {}

    private let bytes: [UInt8]
    private var index = 0

    private init(_ text: String) {
        bytes = Array(text.utf8)
    }

    static func parse(_ text: String) throws -> StrictCoachJSONValue {
        var parser = StrictCoachJSONParser(text)
        parser.skipWhitespace()
        let value = try parser.parseValue()
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw ParseFailure() }
        return value
    }

    private mutating func parseValue() throws -> StrictCoachJSONValue {
        guard let byte = currentByte else { throw ParseFailure() }
        switch byte {
        case 0x7B:
            return try parseObject()
        case 0x5B:
            return try parseArray()
        case 0x22:
            return .string(try parseString())
        case 0x2D, 0x30...0x39:
            return .number(try parseNumber())
        case 0x74:
            try consumeLiteral("true")
            return .boolean(true)
        case 0x66:
            try consumeLiteral("false")
            return .boolean(false)
        case 0x6E:
            try consumeLiteral("null")
            return .null
        default:
            throw ParseFailure()
        }
    }

    private mutating func parseObject() throws -> StrictCoachJSONValue {
        try consume(0x7B)
        skipWhitespace()
        if consumeIfPresent(0x7D) { return .object([:]) }

        var object: [String: StrictCoachJSONValue] = [:]
        while true {
            guard currentByte == 0x22 else { throw ParseFailure() }
            let key = try parseString()
            guard object[key] == nil else { throw ParseFailure() }
            skipWhitespace()
            try consume(0x3A)
            skipWhitespace()
            object[key] = try parseValue()
            skipWhitespace()
            if consumeIfPresent(0x7D) { return .object(object) }
            try consume(0x2C)
            skipWhitespace()
        }
    }

    private mutating func parseArray() throws -> StrictCoachJSONValue {
        try consume(0x5B)
        skipWhitespace()
        if consumeIfPresent(0x5D) { return .array([]) }

        var array: [StrictCoachJSONValue] = []
        while true {
            array.append(try parseValue())
            skipWhitespace()
            if consumeIfPresent(0x5D) { return .array(array) }
            try consume(0x2C)
            skipWhitespace()
        }
    }

    private mutating func parseString() throws -> String {
        let tokenStart = index
        try consume(0x22)
        while let current = currentByte {
            switch current {
            case 0x00...0x1F:
                throw ParseFailure()
            case 0x22:
                index += 1
                let token = Data(bytes[tokenStart..<index])
                guard let decoded = try JSONSerialization.jsonObject(
                    with: token,
                    options: .fragmentsAllowed
                ) as? String else {
                    throw ParseFailure()
                }
                return decoded
            case 0x5C:
                index += 1
                guard let escaped = currentByte else { throw ParseFailure() }
                switch escaped {
                case 0x22, 0x2F, 0x5C, 0x62, 0x66, 0x6E, 0x72, 0x74:
                    index += 1
                case 0x75:
                    index += 1
                    let codeUnit = try consumeHexCodeUnit()
                    if (0xD800...0xDBFF).contains(codeUnit) {
                        guard currentByte == 0x5C,
                              byte(at: index + 1) == 0x75 else {
                            throw ParseFailure()
                        }
                        index += 2
                        let lowSurrogate = try consumeHexCodeUnit()
                        guard (0xDC00...0xDFFF).contains(lowSurrogate) else {
                            throw ParseFailure()
                        }
                    } else if (0xDC00...0xDFFF).contains(codeUnit) {
                        throw ParseFailure()
                    }
                default:
                    throw ParseFailure()
                }
            default:
                index += 1
            }
        }
        throw ParseFailure()
    }

    private mutating func parseNumber() throws -> String {
        let start = index
        _ = consumeIfPresent(0x2D)
        guard let firstDigit = currentByte else { throw ParseFailure() }
        if firstDigit == 0x30 {
            index += 1
            if let next = currentByte, (0x30...0x39).contains(next) { throw ParseFailure() }
        } else {
            guard (0x31...0x39).contains(firstDigit) else { throw ParseFailure() }
            consumeDigits()
        }

        if consumeIfPresent(0x2E) {
            guard let digit = currentByte, (0x30...0x39).contains(digit) else {
                throw ParseFailure()
            }
            consumeDigits()
        }
        if currentByte == 0x65 || currentByte == 0x45 {
            index += 1
            if currentByte == 0x2B || currentByte == 0x2D { index += 1 }
            guard let digit = currentByte, (0x30...0x39).contains(digit) else {
                throw ParseFailure()
            }
            consumeDigits()
        }

        guard let number = String(bytes: bytes[start..<index], encoding: .utf8) else {
            throw ParseFailure()
        }
        return number
    }

    private mutating func consumeHexCodeUnit() throws -> UInt16 {
        guard index + 4 <= bytes.count else { throw ParseFailure() }
        var value: UInt16 = 0
        for _ in 0..<4 {
            guard let byte = currentByte, let digit = hexValue(byte) else { throw ParseFailure() }
            value = value * 16 + UInt16(digit)
            index += 1
        }
        return value
    }

    private func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x41 + 10
        case 0x61...0x66: return byte - 0x61 + 10
        default: return nil
        }
    }

    private mutating func consumeDigits() {
        while let byte = currentByte, (0x30...0x39).contains(byte) {
            index += 1
        }
    }

    private mutating func consumeLiteral(_ literal: String) throws {
        let literalBytes = Array(literal.utf8)
        guard index + literalBytes.count <= bytes.count,
              Array(bytes[index..<(index + literalBytes.count)]) == literalBytes else {
            throw ParseFailure()
        }
        index += literalBytes.count
    }

    private mutating func consume(_ byte: UInt8) throws {
        guard consumeIfPresent(byte) else { throw ParseFailure() }
    }

    private mutating func consumeIfPresent(_ byte: UInt8) -> Bool {
        guard currentByte == byte else { return false }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while let byte = currentByte,
              byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
            index += 1
        }
    }

    private var currentByte: UInt8? {
        byte(at: index)
    }

    private func byte(at offset: Int) -> UInt8? {
        guard bytes.indices.contains(offset) else { return nil }
        return bytes[offset]
    }
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

    static func isSafeTranscriptSourceText(_ text: String) -> Bool {
        !containsUnsafeScalar(text)
    }

    private static func decode(
        modelResponse: String,
        transcriptContext: [CoachTranscriptExcerpt]
    ) throws -> [CoachInsightCandidate] {
        let root: StrictCoachJSONValue
        do {
            root = try StrictCoachJSONParser.parse(modelResponse)
        } catch {
            throw ContractFailure(category: .invalidEnvelope)
        }
        guard case .object(let envelope) = root,
              hasExactKeys(envelope, envelopeKeys),
              let version = strictInteger(envelope["contract_version"]),
              case .array(let candidates)? = envelope["candidates"] else {
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
            guard case .object(let candidate) = rawCandidate,
                  case .string(let kind)? = candidate["kind"] else {
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
        _ candidate: [String: StrictCoachJSONValue]
    ) throws -> CoachInsightCandidate {
        guard hasExactKeys(candidate, guidanceKeys),
              case .string(let directive)? = candidate["directive"],
              case .string(let question)? = candidate["question"],
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
        _ candidate: [String: StrictCoachJSONValue],
        transcript: [Int: TranscriptSource]
    ) throws -> CoachInsightCandidate {
        guard hasExactKeys(candidate, quoteKeys),
              case .string(let presentation)? = candidate["presentation"],
              let priority = priority(from: candidate["priority"]) else {
            throw ContractFailure(category: .invalidCandidate)
        }
        let derivedPresentation = try presentationValues(for: presentation)
        let topic = try validatedTopic(candidate["topic"])
        guard case .array(let evidence)? = candidate["evidence_quotes"] else {
            throw ContractFailure(category: .invalidEvidence)
        }
        guard !evidence.isEmpty else {
            throw ContractFailure(category: .invalidEvidence)
        }

        var evidenceIDs: [Int] = []
        var normalizedQuote: String?
        for rawEvidence in evidence {
            guard case .object(let quoteRecord) = rawEvidence,
                  hasExactKeys(quoteRecord, evidenceKeys),
                  let sourceID = strictInteger(quoteRecord["source_segment_id"]),
                  isPositiveSafeInteger(sourceID),
                  case .string(let quote)? = quoteRecord["quote"],
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

    private static func priority(from value: StrictCoachJSONValue?) -> CoachInsightPriority? {
        guard case .string(let rawValue)? = value,
              rawValue == "high" || rawValue == "critical" else {
            return nil
        }
        return CoachInsightPriority(rawValue: rawValue)
    }

    private static func validatedTopic(_ value: StrictCoachJSONValue?) throws -> String {
        guard case .string(let topic)? = value else {
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
        guard !containsUnsafeScalar(question), hasValidQuestionPunctuation(question) else {
            throw ContractFailure(category: .invalidText)
        }
        let normalized = collapseWhitespace(question.precomposedStringWithCanonicalMapping)
        guard hasValidQuestionPunctuation(normalized) else {
            throw ContractFailure(category: .invalidText)
        }
        let bodyScalars = normalized.unicodeScalars.dropLast()
        let firstSpace = bodyScalars.firstIndex(where: { $0.value == 0x20 }) ?? bodyScalars.endIndex
        let headScalars = bodyScalars[..<firstSpace]
        guard !headScalars.isEmpty,
              headScalars.allSatisfy({
                  (0x41...0x5A).contains($0.value) || (0x61...0x7A).contains($0.value)
              }),
              interrogativeHeads.contains(String(headScalars).lowercased()) else {
            throw ContractFailure(category: .invalidText)
        }
        return normalized
    }

    private static func hasValidQuestionPunctuation(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        var lowerBound = 0
        var upperBound = scalars.count
        while lowerBound < upperBound, isCollapsibleWhitespace(scalars[lowerBound]) {
            lowerBound += 1
        }
        while upperBound > lowerBound, isCollapsibleWhitespace(scalars[upperBound - 1]) {
            upperBound -= 1
        }
        guard upperBound > lowerBound, scalars[upperBound - 1].value == 0x3F else { return false }
        return scalars[lowerBound..<(upperBound - 1)].allSatisfy { scalar in
            switch scalar.value {
            case 0x21, 0x2E, 0x3B, 0x3F:
                return false
            default:
                return true
            }
        }
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
            case 0x061C, 0x200B...0x200F, 0x2028...0x202E, 0x2060,
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

    private static func strictInteger(_ value: StrictCoachJSONValue?) -> Int? {
        guard case .number(let rawValue)? = value else { return nil }
        return exactInteger(from: rawValue)
    }

    private static func exactInteger(from rawValue: String) -> Int? {
        var number = rawValue
        let isNegative = number.first == "-"
        if isNegative { number.removeFirst() }

        let exponentIndex = number.firstIndex(where: { $0 == "e" || $0 == "E" })
        let significand = exponentIndex.map { String(number[..<$0]) } ?? number
        let exponentText = exponentIndex.map { String(number[number.index(after: $0)...]) } ?? "0"
        let significandParts = significand.split(separator: ".", omittingEmptySubsequences: false)
        guard significandParts.count <= 2 else { return nil }

        let fractionalCount = significandParts.count == 2 ? significandParts[1].count : 0
        var digits = significandParts.joined()
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        if digits.allSatisfy({ $0 == "0" }) { return 0 }

        guard exponentText.count <= 7, let exponent = Int(exponentText) else { return nil }
        let scale = exponent - fractionalCount
        if scale >= 0 {
            guard digits.count + scale <= String(maximumSafeInteger).count else { return nil }
            digits.append(String(repeating: "0", count: scale))
        } else {
            let removedCount = -scale
            guard removedCount <= digits.count,
                  digits.suffix(removedCount).allSatisfy({ $0 == "0" }) else {
                return nil
            }
            digits.removeLast(removedCount)
        }

        digits = String(digits.drop(while: { $0 == "0" }))
        if digits.isEmpty { return 0 }
        let maximum = String(maximumSafeInteger)
        guard digits.count < maximum.count || (digits.count == maximum.count && digits <= maximum),
              let magnitude = Int(digits) else {
            return nil
        }
        return isNegative ? -magnitude : magnitude
    }

    private static func isPositiveSafeInteger(_ value: Int) -> Bool {
        value > 0 && value <= maximumSafeInteger
    }

    private static func hasExactKeys(
        _ dictionary: [String: StrictCoachJSONValue],
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
    let maxSessionInsights: Int
    let maxContentCharacters: Int
    let maxContentWords: Int
    let maxTopicCharacters: Int
    let maxEvidenceReferences: Int
    let minimumPriority: CoachInsightPriority
    let nearDuplicateThreshold: Double
    let topicCooldown: TimeInterval

    static let `default` = CoachAdmissionPolicy(
        maxCandidatesPerGeneration: 2,
        maxSessionInsights: 10,
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

            guard comparisonInsights.count < maxSessionInsights else {
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
