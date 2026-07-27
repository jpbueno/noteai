import XCTest
@testable import NoteAI

final class AICoachContextTests: XCTestCase {
    func testAnalysisRequestBoundsRecentDeltaAndRollingContext() throws {
        var context = CoachContext(policy: CoachContextPolicy(
            minimumWordCount: 1,
            minimumNewSegments: 1,
            minimumAnalysisInterval: 0,
            failureRetryInterval: 30,
            maxRecentSegments: 6,
            maxDeltaSegments: 3,
            maxTranscriptCharacters: 9_000,
            maxSpeakerCharacters: 80,
            maxRollingContextCharacters: 120,
            maxChatMessages: 4
        ))
        let sessionID = UUID()
        let transcript = makeSegments(1...40)

        let first = try XCTUnwrap(context.prepareAnalysis(
            sessionID: sessionID,
            transcript: transcript,
            now: Date(timeIntervalSince1970: 100)
        ))

        XCTAssertEqual(first.recentTranscript.map(\.id), [35, 36, 37, 38, 39, 40])
        XCTAssertEqual(first.transcriptDelta.map(\.id), [38, 39, 40])
        XCTAssertLessThanOrEqual(first.rollingContext.count, 120)
        XCTAssertFalse(first.rollingContext.isEmpty)

        context.completeAnalysis(
            segmentCount: transcript.count,
            at: Date(timeIntervalSince1970: 100)
        )
        let updatedTranscript = transcript + makeSegments(41...44)
        let second = try XCTUnwrap(context.prepareAnalysis(
            sessionID: sessionID,
            transcript: updatedTranscript,
            now: Date(timeIntervalSince1970: 101)
        ))

        XCTAssertEqual(second.recentTranscript.map(\.id), [39, 40, 41, 42, 43, 44])
        XCTAssertEqual(second.transcriptDelta.map(\.id), [42, 43, 44])
        XCTAssertFalse(second.recentTranscript.map(\.id).contains(1))
    }

    func testAnalysisRequestRequiresNewMaterialAndHonorsCadence() throws {
        var context = CoachContext(policy: CoachContextPolicy(
            minimumWordCount: 3,
            minimumNewSegments: 2,
            minimumAnalysisInterval: 300,
            failureRetryInterval: 30,
            maxRecentSegments: 12,
            maxDeltaSegments: 6,
            maxTranscriptCharacters: 9_000,
            maxSpeakerCharacters: 80,
            maxRollingContextCharacters: 500,
            maxChatMessages: 4
        ))
        let sessionID = UUID()
        let initial = [
            TranscriptSegment(id: 1, text: "one two three", startTime: 0, endTime: 1),
            TranscriptSegment(id: 2, text: "four five six", startTime: 1, endTime: 2),
        ]
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertNotNil(context.prepareAnalysis(sessionID: sessionID, transcript: initial, now: start))
        context.completeAnalysis(segmentCount: initial.count, at: start)

        XCTAssertNil(context.prepareAnalysis(
            sessionID: sessionID,
            transcript: initial + [TranscriptSegment(id: 3, text: "seven eight nine")],
            now: start.addingTimeInterval(301)
        ))
        XCTAssertNil(context.prepareAnalysis(
            sessionID: sessionID,
            transcript: initial + makeSegments(3...4),
            now: start.addingTimeInterval(299)
        ))
        XCTAssertNotNil(context.prepareAnalysis(
            sessionID: sessionID,
            transcript: initial + makeSegments(3...4),
            now: start.addingTimeInterval(300)
        ))
    }

    func testFailedAnalysisRetriesSoonWithoutDiscardingTranscriptDelta() {
        var context = CoachContext(policy: CoachContextPolicy(
            minimumWordCount: 1,
            minimumNewSegments: 1,
            minimumAnalysisInterval: 300,
            failureRetryInterval: 30,
            maxRecentSegments: 12,
            maxDeltaSegments: 6,
            maxTranscriptCharacters: 9_000,
            maxSpeakerCharacters: 80,
            maxRollingContextCharacters: 500,
            maxChatMessages: 4
        ))
        let sessionID = UUID()
        let transcript = makeSegments(1...2)
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertNotNil(context.prepareAnalysis(sessionID: sessionID, transcript: transcript, now: start))
        context.failAnalysis(at: start)

        XCTAssertNil(context.prepareAnalysis(
            sessionID: sessionID,
            transcript: transcript,
            now: start.addingTimeInterval(29)
        ))
        let retry = context.prepareAnalysis(
            sessionID: sessionID,
            transcript: transcript,
            now: start.addingTimeInterval(30)
        )
        XCTAssertEqual(retry?.transcriptDelta.map(\.id), [1, 2])
    }

    func testOversizedNegatedSegmentIsOmittedInsteadOfRelabeledWithPositiveTail() throws {
        var context = CoachContext(policy: CoachContextPolicy(
            minimumWordCount: 1,
            minimumNewSegments: 1,
            minimumAnalysisInterval: 0,
            failureRetryInterval: 0,
            maxRecentSegments: 6,
            maxDeltaSegments: 6,
            maxTranscriptCharacters: 40,
            maxSpeakerCharacters: 8,
            maxRollingContextCharacters: 120,
            maxChatMessages: 4
        ))
        let text = "The customer has not committed to deliver results."
            + String(repeating: " ", count: 80)
            + "Customer will deliver results tomorrow."
        let oversized = TranscriptSegment(
            id: 1,
            text: text,
            startTime: 0,
            endTime: 1,
            speaker: "customer"
        )

        let request = try XCTUnwrap(context.prepareAnalysis(
            sessionID: UUID(),
            transcript: [oversized],
            now: Date()
        ))

        XCTAssertEqual(request.recentTranscript, [])
        XCTAssertEqual(request.transcriptDelta, [])
        XCTAssertFalse(request.recentTranscript.contains { $0.text.contains("Customer will deliver") })
    }

    func testEvidenceContextPreservesCompleteRawWhitespaceAndOmitsLeadingControl() throws {
        var context = CoachContext(policy: CoachContextPolicy(
            minimumWordCount: 1,
            minimumNewSegments: 1,
            minimumAnalysisInterval: 0,
            failureRetryInterval: 0,
            maxRecentSegments: 6,
            maxDeltaSegments: 6,
            maxTranscriptCharacters: 80,
            maxSpeakerCharacters: 8,
            maxRollingContextCharacters: 120,
            maxChatMessages: 4
        ))
        let canonicalText = "  Capacity is constrained.  "
        let transcript = [
            TranscriptSegment(
                id: 1,
                text: canonicalText,
                speaker: String(repeating: "speaker", count: 20)
            ),
            TranscriptSegment(id: 2, text: "\u{0001}Customer will deliver results tomorrow."),
        ]

        let request = try XCTUnwrap(context.prepareAnalysis(
            sessionID: UUID(),
            transcript: transcript,
            now: Date()
        ))

        XCTAssertEqual(request.recentTranscript.map(\.id), [1])
        XCTAssertEqual(request.recentTranscript.first?.text, canonicalText)
        XCTAssertEqual(request.recentTranscript.first?.speaker?.count, 8)
        XCTAssertEqual(request.transcriptDelta.map(\.id), [1])
    }

    func testRollingContextKeepsOnlyCompleteSafeIDLabeledSegments() throws {
        var context = CoachContext(policy: CoachContextPolicy(
            minimumWordCount: 1,
            minimumNewSegments: 1,
            minimumAnalysisInterval: 0,
            failureRetryInterval: 0,
            maxRecentSegments: 1,
            maxDeltaSegments: 1,
            maxTranscriptCharacters: 80,
            maxSpeakerCharacters: 8,
            maxRollingContextCharacters: 80,
            maxChatMessages: 4
        ))
        let transcript = [
            TranscriptSegment(
                id: 1,
                text: "No commitment was discussed. "
                    + String(repeating: "x", count: 90)
                    + " Customer will deliver tomorrow."
            ),
            TranscriptSegment(id: 2, text: "Complete safe context."),
            TranscriptSegment(id: 3, text: "\u{0001}Unsafe context."),
            TranscriptSegment(id: 4, text: "Current complete evidence."),
        ]

        let request = try XCTUnwrap(context.prepareAnalysis(
            sessionID: UUID(),
            transcript: transcript,
            now: Date()
        ))

        XCTAssertTrue(request.rollingContext.contains("[2 "))
        XCTAssertTrue(request.rollingContext.contains("Complete safe context."))
        XCTAssertFalse(request.rollingContext.contains("[1 "))
        XCTAssertFalse(request.rollingContext.contains("Customer will deliver"))
        XCTAssertFalse(request.rollingContext.contains("[3 "))
    }

    func testTranscriptBudgetCountsSpeakerUnicodeScalarsAndOmitsWholeSegments() throws {
        var context = CoachContext(policy: CoachContextPolicy(
            minimumWordCount: 1,
            minimumNewSegments: 1,
            minimumAnalysisInterval: 0,
            failureRetryInterval: 0,
            maxRecentSegments: 6,
            maxDeltaSegments: 6,
            maxTranscriptCharacters: 10,
            maxSpeakerCharacters: 20,
            maxRollingContextCharacters: 120,
            maxChatMessages: 4
        ))
        let combiningSpeaker = "e\u{0301}e\u{0301}e\u{0301}"
        let oversizedCombiningSpeaker = combiningSpeaker + "e\u{0301}"
        let transcript = [
            TranscriptSegment(id: 1, text: "data", speaker: combiningSpeaker),
            TranscriptSegment(id: 2, text: "data", speaker: oversizedCombiningSpeaker),
        ]

        let request = try XCTUnwrap(context.prepareAnalysis(
            sessionID: UUID(),
            transcript: transcript,
            now: Date()
        ))

        XCTAssertEqual(request.recentTranscript.map(\.id), [1])
        XCTAssertEqual(request.recentTranscript.first?.text, "data")
        XCTAssertEqual(request.recentTranscript.first?.speaker, combiningSpeaker)
        XCTAssertEqual(request.recentTranscript.first?.speaker?.unicodeScalars.count, 6)
    }

    func testSpeakerLimitUsesUnicodeScalarsRatherThanExtendedGraphemes() throws {
        var context = CoachContext(policy: CoachContextPolicy(
            minimumWordCount: 1,
            minimumNewSegments: 1,
            minimumAnalysisInterval: 0,
            failureRetryInterval: 0,
            maxRecentSegments: 6,
            maxDeltaSegments: 6,
            maxTranscriptCharacters: 100,
            maxSpeakerCharacters: 6,
            maxRollingContextCharacters: 120,
            maxChatMessages: 4
        ))
        let speaker = "e\u{0301}e\u{0301}e\u{0301}e\u{0301}"

        let request = try XCTUnwrap(context.prepareAnalysis(
            sessionID: UUID(),
            transcript: [TranscriptSegment(id: 1, text: "complete evidence", speaker: speaker)],
            now: Date()
        ))
        let boundedSpeaker = try XCTUnwrap(request.recentTranscript.first?.speaker)

        XCTAssertEqual(boundedSpeaker, "e\u{0301}e\u{0301}e\u{0301}")
        XCTAssertEqual(boundedSpeaker.unicodeScalars.count, 6)
    }

    private func makeSegments(_ ids: ClosedRange<Int>) -> [TranscriptSegment] {
        ids.map { id in
            TranscriptSegment(
                id: id,
                text: "segment \(id) contains substantive architecture discussion",
                startTime: Float(id * 10),
                endTime: Float(id * 10 + 5),
                speaker: "speaker-\(id % 2)",
                confidence: 0.9
            )
        }
    }
}

final class AICoachAdmissionTests: XCTestCase {
    func testTranscriptInsightRequiresCanonicalEvidence() {
        let policy = CoachAdmissionPolicy.default
        let transcript = [
            TranscriptSegment(id: 7, text: "Our p99 target is 250 milliseconds.", startTime: 12, endTime: 15),
        ]

        let missing = policy.evaluate(
            candidates: [candidate(content: "Confirm whether 250 ms is an end-to-end p99 target.", sourceSegmentIDs: [])],
            transcript: transcript,
            existingInsights: [],
            sessionID: UUID(),
            now: Date(timeIntervalSince1970: 100)
        )
        XCTAssertEqual(missing.accepted, [])
        XCTAssertEqual(missing.rejections.map(\.reason), [.missingTranscriptEvidence])

        let admitted = policy.evaluate(
            candidates: [candidate(content: "Confirm whether 250 ms is an end-to-end p99 target.", sourceSegmentIDs: [7])],
            transcript: transcript,
            existingInsights: [],
            sessionID: UUID(),
            now: Date(timeIntervalSince1970: 100)
        )
        XCTAssertEqual(admitted.accepted.count, 1)
        XCTAssertEqual(admitted.accepted[0].evidence, [
            CoachEvidenceReference(segmentID: 7, startTime: 12, endTime: 15),
        ])
        XCTAssertEqual(admitted.accepted[0].basis, .transcript)
    }

    func testAdmissionRejectsOversizedLowPriorityInvalidEvidenceAndUnsupportedCommitmentCandidates() {
        let policy = CoachAdmissionPolicy.default
        let transcript = [TranscriptSegment(id: 1, text: "We discussed deployment sizing.")]
        let oversized = String(repeating: "long ", count: 60)
        let candidates = [
            candidate(content: oversized, sourceSegmentIDs: [1]),
            candidate(content: "Maybe mention deployment sizing.", priority: .medium, sourceSegmentIDs: [1]),
            candidate(content: "Ask for the missing source detail.", sourceSegmentIDs: [999]),
            candidate(
                type: .actionItem,
                content: "Send a deployment sizing proposal tomorrow.",
                basis: .recommendation,
                sourceSegmentIDs: []
            ),
        ]

        let reasons = candidates.flatMap { candidate in
            policy.evaluate(
                candidates: [candidate],
                transcript: transcript,
                existingInsights: [],
                sessionID: UUID(),
                now: Date()
            ).rejections.map(\.reason)
        }

        XCTAssertEqual(reasons, [
            .contentTooLong,
            .priorityTooLow,
            .invalidEvidenceReference,
            .unsupportedCommitment,
        ])
    }

    func testAdmissionRejectsResultCountAboveLimit() {
        let policy = CoachAdmissionPolicy.default
        let decision = policy.evaluate(
            candidates: (1...3).map { id in
                candidate(
                    content: "Candidate \(id) has independent high-value guidance.",
                    topic: "topic-\(id)",
                    sourceSegmentIDs: [id]
                )
            },
            transcript: (1...3).map { TranscriptSegment(id: $0, text: "Evidence \($0)") },
            existingInsights: [],
            sessionID: UUID(),
            now: Date()
        )

        XCTAssertEqual(decision.accepted, [])
        XCTAssertEqual(decision.rejections.map(\.reason), [.tooManyCandidates])
    }

    func testAdmissionRejectsNearDuplicatesAndTopicCooldownButAllowsHigherPriorityEscalation() throws {
        let policy = CoachAdmissionPolicy.default
        let sessionID = UUID()
        let now = Date(timeIntervalSince1970: 500)
        let transcript = [TranscriptSegment(id: 1, text: "The p99 latency target remains unclear.")]
        let existing = CoachInsight(
            timestamp: now,
            type: .talkingPoint,
            content: "Ask for their p99 latency target before sizing GPUs.",
            sessionID: sessionID,
            basis: .transcript,
            evidence: [CoachEvidenceReference(segmentID: 1, startTime: 0, endTime: 0)],
            topic: "latency-slo",
            priority: .high
        )

        let duplicate = policy.evaluate(
            candidates: [candidate(
                content: "Ask about the p99 latency target before sizing the GPU fleet.",
                topic: "latency-slo",
                sourceSegmentIDs: [1]
            )],
            transcript: transcript,
            existingInsights: [existing],
            sessionID: sessionID,
            now: now.addingTimeInterval(30)
        )
        XCTAssertEqual(duplicate.rejections.map(\.reason), [.nearDuplicate])

        let cooldown = policy.evaluate(
            candidates: [candidate(
                content: "Clarify whether the latency SLO includes queueing time.",
                topic: "latency-slo",
                sourceSegmentIDs: [1]
            )],
            transcript: transcript,
            existingInsights: [existing],
            sessionID: sessionID,
            now: now.addingTimeInterval(30)
        )
        XCTAssertEqual(cooldown.rejections.map(\.reason), [.topicCooldown])

        let escalation = policy.evaluate(
            candidates: [candidate(
                content: "Block sizing until the team defines whether queueing counts toward p99.",
                topic: "latency-slo",
                priority: .critical,
                sourceSegmentIDs: [1]
            )],
            transcript: transcript,
            existingInsights: [existing],
            sessionID: sessionID,
            now: now.addingTimeInterval(30)
        )
        XCTAssertEqual(escalation.accepted.count, 1)
        XCTAssertEqual(escalation.accepted[0].priority, .critical)
    }

    func testAdmissionEvaluatesCriticalCandidateBeforeLowerPriorityCandidateOnSameTopic() throws {
        let policy = CoachAdmissionPolicy.default
        let transcript = [
            TranscriptSegment(id: 1, text: "Deployment ownership is still undecided."),
            TranscriptSegment(id: 2, text: "The production launch is blocked on ownership."),
        ]

        let decision = policy.evaluate(
            candidates: [
                candidate(
                    content: "Ask which team will own the production deployment.",
                    topic: "deployment-ownership",
                    priority: .high,
                    sourceSegmentIDs: [1]
                ),
                candidate(
                    content: "Block launch approval until one team accepts production ownership.",
                    topic: "deployment-ownership",
                    priority: .critical,
                    sourceSegmentIDs: [2]
                ),
            ],
            transcript: transcript,
            existingInsights: [],
            sessionID: UUID(),
            now: Date()
        )

        XCTAssertEqual(decision.accepted.map(\.priority), [.critical])
        XCTAssertEqual(decision.rejections, [
            CoachCandidateRejection(candidateIndex: 0, reason: .topicCooldown),
        ])
    }

    func testAdmissionRejectsMissingTopicAndExcessiveEvidenceReferences() {
        let policy = CoachAdmissionPolicy.default
        let transcript = (1...5).map { TranscriptSegment(id: $0, text: "Evidence \($0)") }

        let missingTopic = policy.evaluate(
            candidates: [candidate(
                content: "Ask who owns the rollout decision.",
                topic: "   ",
                sourceSegmentIDs: [1]
            )],
            transcript: transcript,
            existingInsights: [],
            sessionID: UUID(),
            now: Date()
        )
        let excessiveEvidence = policy.evaluate(
            candidates: [candidate(
                content: "Confirm the combined evidence before approving rollout.",
                topic: "rollout-evidence",
                sourceSegmentIDs: [1, 2, 3, 4, 5]
            )],
            transcript: transcript,
            existingInsights: [],
            sessionID: UUID(),
            now: Date()
        )
        let maximumEvidence = policy.evaluate(
            candidates: [candidate(
                content: "Confirm the four canonical sources before approving rollout.",
                topic: "four-source-evidence",
                sourceSegmentIDs: [1, 2, 3, 4]
            )],
            transcript: transcript,
            existingInsights: [],
            sessionID: UUID(),
            now: Date()
        )

        XCTAssertEqual(missingTopic.rejections.map(\.reason), [.invalidTopic])
        XCTAssertEqual(excessiveEvidence.rejections.map(\.reason), [.tooManyEvidenceReferences])
        XCTAssertEqual(maximumEvidence.accepted.count, 1)
        XCTAssertEqual(maximumEvidence.accepted[0].evidence.map(\.segmentID), [1, 2, 3, 4])
    }

    func testCanonicalDedupeRejectsEquivalentQuestionsAcrossTopics() {
        let policy = CoachAdmissionPolicy.default
        let existing = CoachInsight(
            timestamp: Date(timeIntervalSince1970: 100),
            type: .talkingPoint,
            content: "Ask: What is the p99?",
            sessionID: UUID(),
            basis: .recommendation,
            topic: "latency-slo",
            priority: .high
        )

        let exact = policy.evaluate(
            candidates: [candidate(
                content: "Ask: What is p99?",
                basis: .recommendation,
                topic: "performance-target",
                sourceSegmentIDs: []
            )],
            transcript: [],
            existingInsights: [existing],
            sessionID: UUID(),
            now: Date(timeIntervalSince1970: 1_000)
        )
        let near = policy.evaluate(
            candidates: [candidate(
                content: "Ask: What is the p99 latency target today?",
                basis: .recommendation,
                topic: "launch-gate",
                sourceSegmentIDs: []
            )],
            transcript: [],
            existingInsights: [CoachInsight(
                timestamp: Date(timeIntervalSince1970: 100),
                type: .talkingPoint,
                content: "Ask: What is p99 latency target?",
                sessionID: UUID(),
                basis: .recommendation,
                topic: "latency-slo",
                priority: .high
            )],
            sessionID: UUID(),
            now: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertEqual(exact.rejections.map(\.reason), [.exactDuplicate])
        XCTAssertEqual(near.rejections.map(\.reason), [.nearDuplicate])
    }

    func testDefaultLifetimeBudgetNeverExceedsTenInsightsAcrossFiftyMinuteReplay() {
        let policy = CoachAdmissionPolicy.default
        let sessionID = UUID()
        let start = Date(timeIntervalSince1970: 10_000)
        let transcript = (1...11).map {
            TranscriptSegment(id: $0, text: "Evidence for architecture topic \($0).", startTime: Float($0 * 300))
        }
        var accepted: [CoachInsight] = []

        for minute in stride(from: 0, through: 50, by: 5) {
            let id = minute / 5 + 1
            let decision = policy.evaluate(
                candidates: [candidate(
                    content: "Raise architecture topic \(id) before the next design decision.",
                    topic: "topic-\(id)",
                    sourceSegmentIDs: [id]
                )],
                transcript: transcript,
                existingInsights: accepted,
                sessionID: sessionID,
                now: start.addingTimeInterval(TimeInterval(minute * 60))
            )
            accepted.append(contentsOf: decision.accepted)
            if let lastIndex = accepted.indices.last {
                accepted[lastIndex].lifecycle = minute.isMultiple(of: 10) ? .resolved : .dismissed
            }
        }

        XCTAssertEqual(accepted.count, 10)
        XCTAssertTrue(accepted.allSatisfy { $0.lifecycle != .active })
    }

    private func candidate(
        type: CoachInsightType = .talkingPoint,
        content: String,
        basis: CoachInsightBasis = .transcript,
        topic: String = "latency-slo",
        priority: CoachInsightPriority = .high,
        sourceSegmentIDs: [Int]
    ) -> CoachInsightCandidate {
        CoachInsightCandidate(
            type: type,
            content: content,
            basis: basis,
            sourceSegmentIDs: sourceSegmentIDs,
            topic: topic,
            priority: priority
        )
    }
}

final class AICoachEngineTests: XCTestCase {
    func testSharedAdmissionContractV1ThroughProductionInterface() throws {
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixtureURL = repositoryURL
            .appendingPathComponent("SharedTests")
            .appendingPathComponent("coach-admission-contract-v1.json")
        let fixtureData = try Data(contentsOf: fixtureURL)
        let fixture = try XCTUnwrap(
            JSONSerialization.jsonObject(with: fixtureData) as? [String: Any]
        )
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])

        XCTAssertEqual(cases.count, 93)

        for contractCase in cases {
            let caseID = try XCTUnwrap(contractCase["id"] as? String)
            guard let modelOutput = contractCase["model_output"] else {
                XCTFail("Missing model_output for \(caseID)")
                continue
            }
            let modelData = try JSONSerialization.data(withJSONObject: modelOutput, options: [.sortedKeys])
            let modelText = try XCTUnwrap(String(data: modelData, encoding: .utf8))
            let transcriptRecords = try XCTUnwrap(
                contractCase["transcript_segments"] as? [[String: Any]]
            )
            let transcriptContext = try transcriptRecords.map { record in
                CoachTranscriptExcerpt(
                    id: try fixtureTranscriptID(record["source_segment_id"], caseID: caseID),
                    text: try XCTUnwrap(record["text"] as? String),
                    startTime: 0,
                    endTime: 0,
                    speaker: nil
                )
            }
            let expected = try XCTUnwrap(contractCase["expected"] as? [String: Any])
            let expectedOutcome = try XCTUnwrap(expected["outcome"] as? String)
            let expectedCategory = expected["rejection_category"] as? String
            let expectedDerived = try XCTUnwrap(expected["derived"] as? [[String: Any]])
            let expectedSideEffects = try XCTUnwrap(expected["side_effects"] as? [String: Any])

            let result = AICoachEngine.parseAnalysisResponse(
                modelText,
                transcriptContext: transcriptContext
            )

            switch result {
            case .malformed(let rejectionCategory):
                XCTAssertEqual(expectedOutcome, "rejected", caseID)
                XCTAssertEqual(rejectionCategory, expectedCategory, caseID)
            case .candidates(let candidates):
                XCTAssertNotEqual(expectedOutcome, "rejected", caseID)
                XCTAssertNil(expectedCategory, caseID)
                let transcript = transcriptContext.map {
                    TranscriptSegment(
                        id: $0.id,
                        text: $0.text,
                        startTime: $0.startTime,
                        endTime: $0.endTime,
                        speaker: $0.speaker
                    )
                }
                let decision = CoachAdmissionPolicy.default.evaluate(
                    candidates: candidates,
                    transcript: transcript,
                    existingInsights: [],
                    sessionID: UUID(),
                    now: Date(timeIntervalSince1970: 1_000)
                )
                let actualOutcome: String
                if candidates.isEmpty {
                    actualOutcome = "no_op"
                } else if decision.accepted.isEmpty {
                    actualOutcome = "rejected"
                } else {
                    actualOutcome = "accepted"
                }

                XCTAssertEqual(actualOutcome, expectedOutcome, caseID)
                XCTAssertEqual(decision.rejections, [], caseID)
                XCTAssertEqual(decision.accepted.count, expectedDerived.count, caseID)

                for (actual, expectedValue) in zip(decision.accepted, expectedDerived) {
                    let expectedEvidenceIDs = (expectedValue["evidence_ids"] as? [NSNumber])?
                        .map(\.intValue)
                    XCTAssertEqual(actual.content, expectedValue["content"] as? String, caseID)
                    XCTAssertEqual(actual.type.rawValue, expectedValue["type"] as? String, caseID)
                    XCTAssertEqual(actual.basis?.rawValue, expectedValue["basis"] as? String, caseID)
                    XCTAssertEqual(
                        actual.evidence.map { $0.segmentID },
                        expectedEvidenceIDs,
                        caseID
                    )
                    XCTAssertEqual(actual.topic, expectedValue["topic"] as? String, caseID)
                    XCTAssertEqual(actual.priority.rawValue, expectedValue["priority"] as? String, caseID)
                }
            }

            XCTAssertEqual(
                (expectedSideEffects["task_creations"] as? NSNumber)?.intValue,
                0,
                caseID
            )
            XCTAssertEqual(
                (expectedSideEffects["tool_calls"] as? NSNumber)?.intValue,
                0,
                caseID
            )
        }
    }

    func testStrictRawJSONRejectsDuplicateKeysAtEveryDepthAndTrailingCommas() {
        let responses = [
            #"{"contract_version":1,"contract_version":1,"candidates":[]}"#,
            #"{"contract_version":1,"candidates":[{"kind":"guidance_question","kind":"guidance_question","directive":"ask","question":"What is p99?","priority":"high","topic":"p99"}]}"#,
            #"{"contract_version":1,"candidates":[{"kind":"transcript_quote","presentation":"observation","evidence_quotes":[{"source_segment_id":1,"source_segment_id":1,"quote":"Capacity is missing."}],"priority":"high","topic":"capacity"}]}"#,
            #"{"contract_version":1,"candidates":[],}"#,
            #"{"contract_version":1,"candidates":[{"kind":"guidance_question","directive":"ask","question":"What is p99?","priority":"high","topic":"p99",}]}"#,
            #"{"contract_version":1,"candidates":[{"kind":"transcript_quote","presentation":"observation","evidence_quotes":[{"source_segment_id":1,"quote":"Capacity is missing.",}],"priority":"high","topic":"capacity"}]}"#,
        ]

        for response in responses {
            XCTAssertEqual(
                AICoachEngine.parseAnalysisResponse(response, transcriptContext: []),
                .malformed("invalid_envelope"),
                response
            )
        }
    }

    func testStrictRawJSONParserEnforcesByteAndScalarLimitsAtTheirBoundaries() throws {
        let byteLimit = StrictCoachJSONParser.maximumRawBytes
        let scalarLimit = StrictCoachJSONParser.maximumRawScalars
        let emoji = "\u{1F600}"
        let quotedStringOverhead = 2
        let innerByteCount = byteLimit - quotedStringOverhead
        let emojiCount = innerByteCount / emoji.utf8.count
        let byteRemainder = innerByteCount % emoji.utf8.count
        let exactByteJSON = "\""
            + String(repeating: emoji, count: emojiCount)
            + String(repeating: "a", count: byteRemainder)
            + "\""
        let overByteJSON = String(exactByteJSON.dropLast()) + "a\""

        XCTAssertEqual(exactByteJSON.utf8.count, byteLimit)
        XCTAssertLessThan(exactByteJSON.unicodeScalars.count, scalarLimit)
        XCTAssertNoThrow(try StrictCoachJSONParser.parse(exactByteJSON))
        XCTAssertThrowsError(try StrictCoachJSONParser.parse(overByteJSON))

        let noOp = #"{"contract_version":1,"candidates":[]}"#
        let exactScalarJSON = noOp
            + String(repeating: " ", count: scalarLimit - noOp.unicodeScalars.count)
        let overScalarJSON = exactScalarJSON + " "

        XCTAssertEqual(exactScalarJSON.unicodeScalars.count, scalarLimit)
        XCTAssertLessThan(exactScalarJSON.utf8.count, byteLimit)
        XCTAssertEqual(
            AICoachEngine.parseAnalysisResponse(exactScalarJSON, transcriptContext: []),
            .candidates([])
        )
        XCTAssertEqual(
            AICoachEngine.parseAnalysisResponse(overScalarJSON, transcriptContext: []),
            .malformed("invalid_envelope")
        )
    }

    func testStrictRawJSONParserEnforcesArrayAndObjectDepthAndDuplicateKeysNearLimit() {
        let maximumDepth = StrictCoachJSONParser.maximumNestingDepth
        let exactArrayDepth = String(repeating: "[", count: maximumDepth)
            + "0"
            + String(repeating: "]", count: maximumDepth)
        let overArrayDepth = "[" + exactArrayDepth + "]"
        let exactObjectDepth = String(repeating: #"{"value":"#, count: maximumDepth)
            + "0"
            + String(repeating: "}", count: maximumDepth)
        let overObjectDepth = #"{"value":"# + exactObjectDepth + "}"
        let duplicateNearLimit = String(repeating: "[", count: maximumDepth - 1)
            + #"{"value":1,"value":2}"#
            + String(repeating: "]", count: maximumDepth - 1)

        XCTAssertNoThrow(try StrictCoachJSONParser.parse(exactArrayDepth))
        XCTAssertThrowsError(try StrictCoachJSONParser.parse(overArrayDepth))
        XCTAssertNoThrow(try StrictCoachJSONParser.parse(exactObjectDepth))
        XCTAssertThrowsError(try StrictCoachJSONParser.parse(overObjectDepth))
        XCTAssertThrowsError(try StrictCoachJSONParser.parse(duplicateNearLimit))
    }

    func testRawJSONAcceptsMathematicallyIntegralVersionsAndSourceIDs() {
        for version in ["1", "1.0", "1e0", "1e00000000", "1e+00000000", "10e-00000001"] {
            XCTAssertEqual(
                AICoachEngine.parseAnalysisResponse(
                    "{\"contract_version\":\(version),\"candidates\":[]}",
                    transcriptContext: []
                ),
                .candidates([]),
                version
            )
        }

        let transcript = [CoachTranscriptExcerpt(
            id: 1,
            text: "Capacity is missing.",
            startTime: 0,
            endTime: 1,
            speaker: nil
        )]
        for sourceID in ["1", "1.0", "1e0", "1e00000000", "1e+00000000", "10e-00000001"] {
            let response = """
            {"contract_version":1,"candidates":[{"kind":"transcript_quote","presentation":"observation","evidence_quotes":[{"source_segment_id":\(sourceID),"quote":"Capacity is missing."}],"priority":"high","topic":"capacity"}]}
            """
            guard case .candidates(let candidates) = AICoachEngine.parseAnalysisResponse(
                response,
                transcriptContext: transcript
            ) else {
                XCTFail("Expected integral source ID \(sourceID) to be accepted")
                continue
            }
            XCTAssertEqual(candidates.map(\.sourceSegmentIDs), [[1]], sourceID)
        }

        let maximumSafeID = 9_007_199_254_740_991
        let maximumTranscript = [CoachTranscriptExcerpt(
            id: maximumSafeID,
            text: "Capacity is missing.",
            startTime: 0,
            endTime: 1,
            speaker: nil
        )]
        let maximumResponse = """
        {"contract_version":1,"candidates":[{"kind":"transcript_quote","presentation":"observation","evidence_quotes":[{"source_segment_id":90071992547409910e-1,"quote":"Capacity is missing."}],"priority":"high","topic":"capacity"}]}
        """
        guard case .candidates(let maximumCandidates) = AICoachEngine.parseAnalysisResponse(
            maximumResponse,
            transcriptContext: maximumTranscript
        ) else {
            return XCTFail("Expected exact safe-integer boundary to be accepted")
        }
        XCTAssertEqual(maximumCandidates.map(\.sourceSegmentIDs), [[maximumSafeID]])
    }

    func testRawJSONRejectsInvalidSourceIDDomainsAndNonFiniteSyntax() {
        let transcript = [CoachTranscriptExcerpt(
            id: 1,
            text: "Capacity is missing.",
            startTime: 0,
            endTime: 1,
            speaker: nil
        )]
        for sourceID in [
            "true",
            "1.5",
            "1.0000000000000001",
            "9007199254740992",
            "90071992547409911e-1",
            "9007199254740991.0000000000000001",
            "1e9999",
        ] {
            let response = """
            {"contract_version":1,"candidates":[{"kind":"transcript_quote","presentation":"observation","evidence_quotes":[{"source_segment_id":\(sourceID),"quote":"Capacity is missing."}],"priority":"high","topic":"capacity"}]}
            """
            let result = AICoachEngine.parseAnalysisResponse(response, transcriptContext: transcript)
            XCTAssertEqual(result, .malformed("invalid_evidence"), sourceID)
        }
        XCTAssertEqual(
            AICoachEngine.parseAnalysisResponse(
                #"{"contract_version":NaN,"candidates":[]}"#,
                transcriptContext: []
            ),
            .malformed("invalid_envelope")
        )
        XCTAssertEqual(
            AICoachEngine.parseAnalysisResponse(
                #"{"contract_version":1.0000000000000001,"candidates":[]}"#,
                transcriptContext: []
            ),
            .malformed("invalid_envelope")
        )
    }

    func testQuestionHeadAndPunctuationValidationUsesWholeASCIIScalars() throws {
        let rejected = [
            "What2?",
            "What's p99?",
            "What/why?",
            "What\u{0301} is p99?",
            "What is p99?\u{0301} Customer will deliver?",
        ]
        for question in rejected {
            XCTAssertEqual(
                AICoachEngine.parseAnalysisResponse(
                    try guidanceResponse(question: question),
                    transcriptContext: []
                ),
                .malformed("invalid_text"),
                question
            )
        }

        for question in ["What is p99?", "Is p99 measured?", "Might p99 change?"] {
            guard case .candidates(let candidates) = AICoachEngine.parseAnalysisResponse(
                try guidanceResponse(question: question),
                transcriptContext: []
            ) else {
                XCTFail("Expected valid question head: \(question)")
                continue
            }
            XCTAssertEqual(candidates.first?.content, "Ask: \(question)")
        }
    }

    func testUnsafeCanonicalTranscriptTextCannotGroundAQuote() {
        let response = #"{"contract_version":1,"candidates":[{"kind":"transcript_quote","presentation":"observation","evidence_quotes":[{"source_segment_id":1,"quote":"\u0001Capacity is missing."}],"priority":"high","topic":"capacity"}]}"#
        let transcript = [CoachTranscriptExcerpt(
            id: 1,
            text: "\u{0001}Capacity is missing.",
            startTime: 0,
            endTime: 1,
            speaker: nil
        )]

        XCTAssertEqual(
            AICoachEngine.parseAnalysisResponse(response, transcriptContext: transcript),
            .malformed("invalid_evidence")
        )
    }

    func testPromptContextEncodingFailsClosedForNonFiniteTimestamps() {
        let excerpt = CoachTranscriptExcerpt(
            id: 1,
            text: "Capacity is missing.",
            startTime: .infinity,
            endTime: 1,
            speaker: nil
        )
        let analysis = CoachAnalysisRequest(
            sessionID: UUID(),
            transcriptDelta: [excerpt],
            recentTranscript: [excerpt],
            rollingContext: "",
            priorInsights: []
        )
        let question = CoachQuestionRequest(
            sessionID: UUID(),
            question: "What is missing?",
            recentTranscript: [excerpt],
            rollingContext: "",
            priorInsights: [],
            chatHistory: []
        )

        XCTAssertThrowsError(try AICoachEngine.makeAnalysisMessages(request: analysis))
        XCTAssertThrowsError(try AICoachEngine.makeInteractiveMessages(request: question))
    }

    func testAutoCoachProductionPathHasNoTaskPersistenceOrToolExecutionDependency() throws {
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let coreRelativePaths = [
            "NoteAI/Summarization/AICoachEngine.swift",
            "NoteAI/Summarization/CoachAdmissionPolicy.swift",
            "NoteAI/Summarization/CoachContext.swift",
            "NoteAI/Summarization/LiveCoachSession.swift",
        ]
        let forbiddenSymbols = [
            "MeetingStore",
            "TaskItem",
            "TaskStore",
            "saveTask(",
            "createTask(",
            "ToolExecutor",
            "executeTool(",
            "tool_calls",
        ]

        for relativePath in coreRelativePaths {
            let source = try String(
                contentsOf: repositoryURL.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            let imports = source
                .split(separator: "\n")
                .map(String.init)
                .filter { $0.hasPrefix("import ") }
            XCTAssertEqual(imports, ["import Foundation"], relativePath)
            for symbol in forbiddenSymbols {
                XCTAssertFalse(source.contains(symbol), "\(relativePath) references \(symbol)")
            }
        }

        let managerPath = "NoteAI/App/MeetingManager.swift"
        let managerSource = try String(
            contentsOf: repositoryURL.appendingPathComponent(managerPath),
            encoding: .utf8
        )
        let autoCoachConsumer = try sourceSection(
            in: managerSource,
            from: "// MARK: - AI Coach loop",
            through: "    private func setupAutoDetection()"
        )
        let sessionLifecycle = try sourceSection(
            in: managerSource,
            from: "    private func resetCoachStateForRecording()",
            through: "    private func startDurationTimer()"
        )
        let productionConsumer = autoCoachConsumer + sessionLifecycle
        for symbol in forbiddenSymbols + ["meetingStore.", "tasks.append", "todos.append"] {
            XCTAssertFalse(productionConsumer.contains(symbol), "\(managerPath) coach path references \(symbol)")
        }

        let sessionSource = try String(
            contentsOf: repositoryURL
                .appendingPathComponent("NoteAI/Summarization/LiveCoachSession.swift"),
            encoding: .utf8
        )
        let generatorInterface = try sourceSection(
            in: sessionSource,
            from: "protocol AICoachGenerating: Sendable",
            through: "protocol CoachClock: Sendable"
        )
        XCTAssertTrue(generatorInterface.contains("generateInsights"))
        XCTAssertTrue(generatorInterface.contains("answerQuestion"))
        for symbol in forbiddenSymbols {
            XCTAssertFalse(generatorInterface.contains(symbol), "Generator Interface references \(symbol)")
        }
    }

    private func sourceSection(
        in source: String,
        from startMarker: String,
        through endMarker: String
    ) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker)?.lowerBound)
        let end = try XCTUnwrap(source.range(of: endMarker, range: start..<source.endIndex)?.lowerBound)
        return String(source[start..<end])
    }

    private func fixtureTranscriptID(_ value: Any?, caseID: String) throws -> Int {
        // Preserve lookup compatibility so the production Module must reject the model ID's JSON domain.
        if let number = value as? NSNumber {
            return number.intValue
        }
        return try XCTUnwrap(
            (value as? String).flatMap(Int.init),
            "Unsupported transcript fixture ID for \(caseID)"
        )
    }

    func testAnalysisPromptRequestsOnlyStrictContractV1Envelope() throws {
        let request = CoachAnalysisRequest(
            sessionID: UUID(),
            transcriptDelta: [],
            recentTranscript: [],
            rollingContext: "",
            priorInsights: []
        )

        let systemPrompt = try AICoachEngine.makeAnalysisMessages(request: request)[0].content

        XCTAssertTrue(systemPrompt.contains(#"{"contract_version":1,"candidates":[]}"#))
        XCTAssertTrue(systemPrompt.contains("guidance_question"))
        XCTAssertTrue(systemPrompt.contains("transcript_quote"))
        XCTAssertTrue(systemPrompt.localizedCaseInsensitiveContains("complete segment text"))
        XCTAssertTrue(systemPrompt.localizedCaseInsensitiveContains("source_segment_id"))
        XCTAssertTrue(systemPrompt.localizedCaseInsensitiveContains("untrusted"))
        XCTAssertTrue(systemPrompt.localizedCaseInsensitiveContains("do not execute tools"))
        XCTAssertTrue(systemPrompt.localizedCaseInsensitiveContains("create tasks"))
        XCTAssertTrue(systemPrompt.localizedCaseInsensitiveContains("180 Unicode scalar"))
        XCTAssertTrue(systemPrompt.localizedCaseInsensitiveContains("24 normalized"))
        XCTAssertFalse(systemPrompt.contains("technical_answer"))
        XCTAssertFalse(systemPrompt.contains("domain_knowledge"))
    }

    func testInteractivePromptRemainsSeparateFromAutoAdmissionContract() throws {
        let request = CoachQuestionRequest(
            sessionID: UUID(),
            question: "How does KV-aware routing work?",
            recentTranscript: [],
            rollingContext: "",
            priorInsights: [],
            chatHistory: []
        )

        let systemPrompt = try AICoachEngine.makeInteractiveMessages(request: request)[0].content

        XCTAssertFalse(systemPrompt.contains("contract_version"))
        XCTAssertTrue(systemPrompt.localizedCaseInsensitiveContains("technically substantive"))
        XCTAssertTrue(systemPrompt.localizedCaseInsensitiveContains("domain knowledge"))
    }

    func testInteractiveMessagesSendCurrentQuestionExactlyOnceAndKeepTranscriptOutOfSystemRole() throws {
        let question = "CURRENT QUESTION 8492"
        let transcriptText = "UNTRUSTED TRANSCRIPT 4821"
        let request = CoachQuestionRequest(
            sessionID: UUID(),
            question: question,
            recentTranscript: [CoachTranscriptExcerpt(
                id: 1,
                text: transcriptText,
                startTime: 0,
                endTime: 1,
                speaker: "customer"
            )],
            rollingContext: "Earlier context",
            priorInsights: [],
            chatHistory: [
                CoachChatMessage(sessionID: UUID(), role: .user, content: "Earlier question"),
                CoachChatMessage(sessionID: UUID(), role: .assistant, content: "Earlier answer"),
            ]
        )

        let messages = try AICoachEngine.makeInteractiveMessages(request: request)

        XCTAssertEqual(messages.filter { $0.content == question }.count, 1)
        XCTAssertEqual(messages.last?.role, "user")
        XCTAssertEqual(messages.last?.content, question)
        XCTAssertFalse(messages[0].content.contains(transcriptText))
        XCTAssertTrue(messages.dropFirst().contains { $0.content.contains(transcriptText) })
        XCTAssertTrue(messages[0].content.localizedCaseInsensitiveContains("untrusted"))
    }

    func testAnalysisMessagesDoNotDuplicateDeltaSegmentsInRecentContext() throws {
        let request = CoachAnalysisRequest(
            sessionID: UUID(),
            transcriptDelta: [CoachTranscriptExcerpt(
                id: 2,
                text: "new evidence",
                startTime: 1,
                endTime: 2,
                speaker: "customer"
            )],
            recentTranscript: [
                CoachTranscriptExcerpt(
                    id: 1,
                    text: "prior context",
                    startTime: 0,
                    endTime: 1,
                    speaker: "customer"
                ),
                CoachTranscriptExcerpt(
                    id: 2,
                    text: "new evidence",
                    startTime: 1,
                    endTime: 2,
                    speaker: "customer"
                ),
            ],
            rollingContext: "",
            priorInsights: []
        )

        let message = try XCTUnwrap(try AICoachEngine.makeAnalysisMessages(request: request).last?.content)
        let json = try XCTUnwrap(message.split(separator: "\n", maxSplits: 1).last)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let recent = try XCTUnwrap(object["recentTranscript"] as? [[String: Any]])
        let delta = try XCTUnwrap(object["transcriptDelta"] as? [[String: Any]])

        XCTAssertEqual(recent.compactMap { $0["id"] as? Int }, [1])
        XCTAssertEqual(delta.compactMap { $0["id"] as? Int }, [2])
    }

    private func guidanceResponse(question: String) throws -> String {
        let questionData = try JSONEncoder().encode(question)
        let encodedQuestion = try XCTUnwrap(String(data: questionData, encoding: .utf8))
        return """
        {"contract_version":1,"candidates":[{"kind":"guidance_question","directive":"ask","question":\(encodedQuestion),"priority":"high","topic":"p99"}]}
        """
    }
}

final class AICoachSessionTests: XCTestCase {
    @MainActor
    func testSessionAndMeetingManagerExposeNarrowLifecycleMutationInterface() {
        func requireLifecycleInterface<T: CoachInsightLifecycleMutating>(_: T.Type) {}

        requireLifecycleInterface(LiveCoachSession.self)
        requireLifecycleInterface(MeetingManager.self)
    }

    func testMeetingManagerDisablePathCancelsAllCoachWorkAndGuardsEveryPublication() throws {
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryURL.appendingPathComponent("NoteAI/App/MeetingManager.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("coachSessionSlot.resume(publishedEntries: coachInsights)"))
        XCTAssertTrue(source.contains("guard let session = coachSessionSlot.retire()"))
        XCTAssertTrue(source.contains("Task { await session.cancel() }"))
        XCTAssertTrue(source.contains("coachOperationEpoch.invalidate()"))
        XCTAssertTrue(source.contains("let operationToken = coachOperationEpoch.capture"))
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: "coachOperationEpoch.allows(").count - 1,
            4
        )
        XCTAssertTrue(source.contains("refreshCoachTimeline(from: session, operationToken: operationToken)"))
    }

    @MainActor
    func testDisableDuringRefreshInvalidatesTheCommitPointToken() async {
        let operationEpoch = CoachOperationEpoch()
        let sessionID = UUID()
        let token = operationEpoch.capture(sessionID: sessionID)
        let commitPoint = SuspendedCommitPoint()
        let publicationState = CoachPublicationTestState()

        let publication = Task { @MainActor in
            await commitPoint.suspend()
            return operationEpoch.allows(
                token,
                coachEnabled: publicationState.coachEnabled,
                currentSessionID: sessionID
            )
        }
        await commitPoint.waitUntilSuspended()
        publicationState.coachEnabled = false
        operationEpoch.invalidate()
        await commitPoint.resume()

        let wasPublished = await publication.value
        XCTAssertFalse(wasPublished)
    }

    @MainActor
    func testDisableReenableCannotMakeAnOldOperationCurrentAgain() {
        let operationEpoch = CoachOperationEpoch()
        let sessionID = UUID()
        let staleToken = operationEpoch.capture(sessionID: sessionID)

        operationEpoch.invalidate()
        let currentToken = operationEpoch.capture(sessionID: sessionID)

        XCTAssertFalse(operationEpoch.allows(
            staleToken,
            coachEnabled: true,
            currentSessionID: sessionID
        ))
        XCTAssertTrue(operationEpoch.allows(
            currentToken,
            coachEnabled: true,
            currentSessionID: sessionID
        ))
    }

    @MainActor
    func testQuestionCompletionAfterDisableReenableCannotPublishWithOldToken() async {
        let generator = SuspendedQuestionCoachGenerator()
        let session = LiveCoachSession(
            generator: generator,
            clock: FixedCoachClock(now: Date()),
            contextPolicy: .testing
        )
        let operationEpoch = CoachOperationEpoch()
        let token = operationEpoch.capture(sessionID: session.id)

        let questionTask = Task {
            await session.ask(
                question: "Who owns production rollout?",
                transcript: [TranscriptSegment(id: 1, text: "Rollout ownership is undecided.")]
            )
        }
        await generator.waitUntilQuestionStarts()
        operationEpoch.invalidate()
        await generator.resumeQuestion(with: "The platform team owns the rollout.")

        guard case .answered = await questionTask.value else {
            return XCTFail("Expected the underlying session reply to complete")
        }
        XCTAssertFalse(operationEpoch.allows(
            token,
            coachEnabled: true,
            currentSessionID: session.id
        ))
    }

    @MainActor
    func testFreshEnableGenerationCannotRepublishLateStateFromRetiredSession() async throws {
        let staleGenerator = SuspendedDualCoachGenerator()
        let freshGenerator = RecordingCoachGenerator(
            analysisResult: .candidates([CoachInsightCandidate(
                type: .talkingPoint,
                content: "Ask: What is the fresh launch risk?",
                basis: .recommendation,
                sourceSegmentIDs: [],
                topic: "fresh-launch-risk",
                priority: .high
            )]),
            answer: "Fresh reply."
        )
        var generationCount = 0
        let slot = CoachSessionSlot { id, autoInsights, chatMessages in
            generationCount += 1
            if generationCount == 1 {
                return LiveCoachSession(
                    id: id,
                    generator: staleGenerator,
                    clock: FixedCoachClock(now: Date()),
                    contextPolicy: .testing,
                    initialAutoInsights: autoInsights,
                    initialChatMessages: chatMessages
                )
            }
            return LiveCoachSession(
                id: id,
                generator: freshGenerator,
                clock: FixedCoachClock(now: Date()),
                contextPolicy: .testing,
                initialAutoInsights: autoInsights,
                initialChatMessages: chatMessages
            )
        }
        let transcript = [TranscriptSegment(
            id: 1,
            text: "This transcript has enough material for both coach paths."
        )]
        let retiredSession = slot.beginRecording()
        let staleAnalysis = Task { await retiredSession.analyze(transcript: transcript) }
        let staleQuestion = Task {
            await retiredSession.ask(question: "What is the stale risk?", transcript: transcript)
        }
        await staleGenerator.waitUntilBothRequestsStart()

        XCTAssertTrue(slot.retire() === retiredSession)
        XCTAssertNil(slot.current)

        await staleGenerator.resumeAll(
            analysis: .candidates([CoachInsightCandidate(
                type: .talkingPoint,
                content: "Ask: What is the stale launch risk?",
                basis: .recommendation,
                sourceSegmentIDs: [],
                topic: "stale-launch-risk",
                priority: .critical
            )]),
            answer: "Stale reply."
        )
        guard case .admitted = await staleAnalysis.value,
              case .answered = await staleQuestion.value else {
            return XCTFail("Expected the retired actor to complete before delayed cancellation")
        }
        let contaminatedSnapshot = await retiredSession.snapshot()
        XCTAssertTrue(contaminatedSnapshot.autoInsights.contains { $0.content.contains("stale") })
        XCTAssertTrue(contaminatedSnapshot.chatMessages.contains { $0.content == "Stale reply." })
        await retiredSession.cancel()

        let publishedInsight = CoachInsight(
            type: .talkingPoint,
            content: "Ask: What was already published?",
            sessionID: retiredSession.id,
            basis: .recommendation,
            topic: "published-history",
            priority: .high
        )
        let publishedQuestion = CoachInsight(
            type: .keyInsight,
            content: "What was already answered?",
            role: .user,
            sessionID: retiredSession.id
        )
        let publishedReply = CoachInsight(
            type: .keyInsight,
            content: "Published reply.",
            role: .assistant,
            sessionID: retiredSession.id
        )
        let freshSession = try XCTUnwrap(slot.resume(publishedEntries: [
            publishedInsight,
            publishedQuestion,
            publishedReply,
        ]))
        XCTAssertFalse(freshSession === retiredSession)
        XCTAssertEqual(freshSession.id, retiredSession.id)

        guard case .admitted = await freshSession.analyze(transcript: transcript) else {
            return XCTFail("Expected a valid operation in the fresh enable generation")
        }
        let refreshedSnapshot = await freshSession.snapshot()

        XCTAssertEqual(
            refreshedSnapshot.autoInsights.map(\.content),
            ["Ask: What was already published?", "Ask: What is the fresh launch risk?"]
        )
        XCTAssertEqual(
            refreshedSnapshot.chatMessages.map(\.content),
            ["What was already answered?", "Published reply."]
        )
        XCTAssertFalse(refreshedSnapshot.autoInsights.contains { $0.content.contains("stale") })
        XCTAssertFalse(refreshedSnapshot.chatMessages.contains { $0.content == "Stale reply." })
    }

    func testSessionReadinessDoesNotStartGeneration() async {
        let generator = RecordingCoachGenerator(analysisResult: .candidates([]), answer: "")
        let session = LiveCoachSession(
            generator: generator,
            clock: FixedCoachClock(now: Date()),
            contextPolicy: .testing
        )

        let emptyIsReady = await session.isAnalysisReady(transcript: [])
        let materialIsReady = await session.isAnalysisReady(transcript: [
            TranscriptSegment(id: 1, text: "Substantive architecture context is now available."),
        ])
        let requestCount = await generator.recordedAnalysisRequestCount()

        XCTAssertFalse(emptyIsReady)
        XCTAssertTrue(materialIsReady)
        XCTAssertEqual(requestCount, 0)
    }

    func testSessionKeepsAutoInsightsSeparateFromChatAndDoesNotRepeatQuestionInHistory() async throws {
        let generator = RecordingCoachGenerator(
            analysisResult: .candidates([CoachInsightCandidate(
                type: .talkingPoint,
                content: "Ask whether p99 includes queueing delay.",
                basis: .transcript,
                sourceSegmentIDs: [1],
                topic: "latency-slo",
                priority: .high
            )]),
            answer: "Queueing should be included in an end-to-end SLO."
        )
        let sessionID = UUID()
        let session = LiveCoachSession(
            id: sessionID,
            generator: generator,
            clock: FixedCoachClock(now: Date(timeIntervalSince1970: 100)),
            contextPolicy: .testing
        )
        let transcript = [TranscriptSegment(
            id: 1,
            text: "We need a p99 latency target for the production endpoint.",
            startTime: 5,
            endTime: 8
        )]

        let analysis = await session.analyze(transcript: transcript)
        guard case .admitted(let insights) = analysis else {
            return XCTFail("Expected an admitted insight, got \(analysis)")
        }
        XCTAssertEqual(insights.count, 1)

        let question = "Does p99 include queueing?"
        let reply = await session.ask(question: question, transcript: transcript)
        guard case .answered(let answer) = reply else {
            return XCTFail("Expected an answer, got \(reply)")
        }
        XCTAssertEqual(answer.content, "Queueing should be included in an end-to-end SLO.")

        let snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.autoInsights.count, 1)
        XCTAssertEqual(snapshot.chatMessages.map(\.role), [.user, .assistant])

        let requests = await generator.recordedQuestionRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].question, question)
        XCTAssertFalse(requests[0].chatHistory.contains { $0.content == question })
    }

    func testSessionOwnsAutoInsightLifecycleAndNeverMutatesChatThroughThatInterface() async throws {
        let generator = RecordingCoachGenerator(
            analysisResult: .candidates([CoachInsightCandidate(
                type: .talkingPoint,
                content: "Confirm who owns the production rollout.",
                basis: .transcript,
                sourceSegmentIDs: [1],
                topic: "rollout-ownership",
                priority: .high
            )]),
            answer: "The platform team owns the rollout."
        )
        let session = LiveCoachSession(
            generator: generator,
            clock: FixedCoachClock(now: Date(timeIntervalSince1970: 100)),
            contextPolicy: .testing
        )
        let transcript = [TranscriptSegment(
            id: 1,
            text: "The production rollout still needs a named owner."
        )]

        let analysis = await session.analyze(transcript: transcript)
        guard case .admitted(let insights) = analysis,
              let insight = insights.first else {
            return XCTFail("Expected one admitted auto insight, got \(analysis)")
        }

        let dismissed = await session.setAutoInsightLifecycle(id: insight.id, lifecycle: .dismissed)
        guard case .updated(let dismissedInsight) = dismissed else {
            return XCTFail("Expected dismissed insight, got \(dismissed)")
        }
        XCTAssertEqual(dismissedInsight.lifecycle, .dismissed)

        let resolved = await session.setAutoInsightLifecycle(id: insight.id, lifecycle: .resolved)
        guard case .updated(let resolvedInsight) = resolved else {
            return XCTFail("Expected resolved insight, got \(resolved)")
        }
        XCTAssertEqual(resolvedInsight.lifecycle, .resolved)

        let reactivated = await session.setAutoInsightLifecycle(id: insight.id, lifecycle: .active)
        guard case .updated(let activeInsight) = reactivated else {
            return XCTFail("Expected reactivated insight, got \(reactivated)")
        }
        XCTAssertEqual(activeInsight.lifecycle, .active)

        guard case .answered(let answer) = await session.ask(
            question: "Who owns rollout?",
            transcript: transcript
        ) else {
            return XCTFail("Expected a chat answer")
        }
        let chatMutation = await session.setAutoInsightLifecycle(id: answer.id, lifecycle: .dismissed)
        XCTAssertEqual(chatMutation, .notFound)

        await session.cancel()
        let staleMutation = await session.setAutoInsightLifecycle(id: insight.id, lifecycle: .dismissed)
        XCTAssertEqual(staleMutation, .staleSession)
    }

    func testSessionLifetimeBudgetAndPriorPromptBoundsSurviveDismissalsAcrossFiftyMinutes() async throws {
        let generator = HistoryRecordingCoachGenerator()
        let session = LiveCoachSession(
            generator: generator,
            clock: FixedCoachClock(now: Date()),
            contextPolicy: .testing
        )
        var transcript: [TranscriptSegment] = []

        for minute in stride(from: 0, through: 50, by: 5) {
            let id = minute / 5 + 1
            transcript.append(TranscriptSegment(
                id: id,
                text: "Architecture evidence \(id) arrived at minute \(minute)."
            ))
            let outcome = await session.analyze(transcript: transcript)
            if id <= 10 {
                guard case .admitted(let insights) = outcome,
                      let insight = insights.first else {
                    return XCTFail("Expected insight \(id), got \(outcome)")
                }
                _ = await session.setAutoInsightLifecycle(id: insight.id, lifecycle: .dismissed)
            } else {
                guard case .rejected(let rejections) = outcome else {
                    return XCTFail("Expected lifetime budget rejection, got \(outcome)")
                }
                XCTAssertEqual(rejections.map(\.reason), [.sessionBudgetExhausted])
            }
        }

        guard case .answered = await session.ask(
            question: "What should we revisit?",
            transcript: transcript
        ) else {
            return XCTFail("Expected a bounded-context answer")
        }
        let snapshot = await session.snapshot()
        let questionRequests = await generator.recordedQuestionRequests()
        let questionRequest = try XCTUnwrap(questionRequests.last)

        XCTAssertEqual(snapshot.autoInsights.count, 10)
        XCTAssertTrue(snapshot.autoInsights.allSatisfy { $0.lifecycle == .dismissed })
        XCTAssertLessThanOrEqual(questionRequest.priorInsights.count, 8)
        XCTAssertLessThanOrEqual(
            questionRequest.priorInsights.reduce(0) { $0 + $1.content.unicodeScalars.count },
            1_000
        )
        XCTAssertLessThan(questionRequest.priorInsights.count, snapshot.autoInsights.count)
    }

    func testSessionDistinguishesNoOpFromMalformedGeneration() async {
        let transcript = [TranscriptSegment(id: 1, text: "This transcript has enough words for deterministic coach analysis.")]
        let noOp = LiveCoachSession(
            generator: RecordingCoachGenerator(analysisResult: .candidates([]), answer: ""),
            clock: FixedCoachClock(now: Date()),
            contextPolicy: .testing
        )
        let malformed = LiveCoachSession(
            generator: RecordingCoachGenerator(analysisResult: .malformed("invalid JSON"), answer: ""),
            clock: FixedCoachClock(now: Date()),
            contextPolicy: .testing
        )

        let noOpOutcome = await noOp.analyze(transcript: transcript)
        let malformedOutcome = await malformed.analyze(transcript: transcript)

        XCTAssertEqual(noOpOutcome, .noOp)
        XCTAssertEqual(malformedOutcome, .malformed("invalid JSON"))
    }

    func testValidNoOpRetriesFreshTranscriptAfterShortIntervalWithoutHammeringUnchangedText() async {
        let clock = MutableCoachClock(now: Date(timeIntervalSince1970: 1_000))
        let generator = SequencedCoachGenerator(analysisResults: [
            .candidates([]),
            .candidates([CoachInsightCandidate(
                type: .talkingPoint,
                content: "Ask: What latency target defines launch readiness?",
                basis: .recommendation,
                sourceSegmentIDs: [],
                topic: "latency-target",
                priority: .high
            )]),
        ])
        let session = LiveCoachSession(
            generator: generator,
            clock: clock,
            contextPolicy: CoachContextPolicy(
                minimumWordCount: 3,
                minimumNewSegments: 2,
                minimumAnalysisInterval: 300,
                failureRetryInterval: 30,
                maxRecentSegments: 12,
                maxDeltaSegments: 6,
                maxTranscriptCharacters: 9_000,
                maxSpeakerCharacters: 80,
                maxRollingContextCharacters: 500,
                maxChatMessages: 4
            )
        )
        let initialTranscript = [
            TranscriptSegment(id: 1, text: "Thanks for joining today."),
            TranscriptSegment(id: 2, text: "Let us begin with introductions."),
        ]
        let freshTranscript = initialTranscript + [
            TranscriptSegment(id: 3, text: "Production requires a defined latency target."),
            TranscriptSegment(id: 4, text: "Launch readiness depends on that target."),
        ]

        let initialOutcome = await session.analyze(transcript: initialTranscript)
        XCTAssertEqual(initialOutcome, .noOp)

        clock.advance(by: 29)
        let earlyFreshOutcome = await session.analyze(transcript: freshTranscript)
        XCTAssertEqual(earlyFreshOutcome, .notReady)

        clock.advance(by: 1)
        let unchangedOutcome = await session.analyze(transcript: initialTranscript)
        XCTAssertEqual(unchangedOutcome, .notReady)

        guard case .admitted(let insights) = await session.analyze(transcript: freshTranscript) else {
            return XCTFail("Expected fresh transcript to retry after the short interval")
        }
        XCTAssertEqual(insights.map(\.content), ["Ask: What latency target defines launch readiness?"])

        clock.advance(by: 299)
        let postAdmissionTranscript = freshTranscript + [
            TranscriptSegment(id: 5, text: "The target must include queueing latency."),
            TranscriptSegment(id: 6, text: "The owner must confirm the percentile."),
        ]
        let postAdmissionIsReady = await session.isAnalysisReady(transcript: postAdmissionTranscript)
        let analysisRequestCount = await generator.recordedAnalysisRequestCount()
        XCTAssertFalse(postAdmissionIsReady)
        XCTAssertEqual(analysisRequestCount, 2)
    }

    func testCancelledSessionRejectsLateGeneration() async {
        let generator = SuspendedCoachGenerator()
        let session = LiveCoachSession(
            generator: generator,
            clock: FixedCoachClock(now: Date()),
            contextPolicy: .testing
        )
        let transcript = [TranscriptSegment(id: 1, text: "This transcript has enough words for deterministic coach analysis.")]

        let analysisTask = Task { await session.analyze(transcript: transcript) }
        await generator.waitUntilAnalysisStarts()
        await session.cancel()
        await generator.resume(with: .candidates([CoachInsightCandidate(
            type: .talkingPoint,
            content: "This late result must never become visible.",
            basis: .transcript,
            sourceSegmentIDs: [1],
            topic: "stale-result",
            priority: .critical
        )]))

        let outcome = await analysisTask.value
        let snapshot = await session.snapshot()

        XCTAssertEqual(outcome, .staleSession)
        XCTAssertEqual(snapshot.autoInsights, [])
    }

    func testCancelledSessionRejectsLateQuestionAnswer() async {
        let generator = SuspendedQuestionCoachGenerator()
        let session = LiveCoachSession(
            generator: generator,
            clock: FixedCoachClock(now: Date()),
            contextPolicy: .testing
        )

        let questionTask = Task {
            await session.ask(
                question: "Who owns production rollout?",
                transcript: [TranscriptSegment(id: 1, text: "Rollout ownership is undecided.")]
            )
        }
        await generator.waitUntilQuestionStarts()
        await session.cancel()
        await generator.resumeQuestion(with: "A late answer that must be discarded.")

        let outcome = await questionTask.value
        let snapshot = await session.snapshot()

        XCTAssertEqual(outcome, .staleSession)
        XCTAssertEqual(snapshot.chatMessages.map(\.role), [.user])
    }

    func testDisablingPendingWorkInvalidatesAnalysisAndInteractiveReplies() async {
        let generator = SuspendedDualCoachGenerator()
        let session = LiveCoachSession(
            generator: generator,
            clock: FixedCoachClock(now: Date()),
            contextPolicy: .testing
        )
        let transcript = [TranscriptSegment(
            id: 1,
            text: "This transcript has enough material for both coach paths."
        )]

        let analysisTask = Task { await session.analyze(transcript: transcript) }
        let questionTask = Task {
            await session.ask(question: "What is the launch risk?", transcript: transcript)
        }
        await generator.waitUntilBothRequestsStart()
        await session.cancelPendingWork()
        await generator.resumeAll(
            analysis: .candidates([CoachInsightCandidate(
                type: .talkingPoint,
                content: "Ask: What is the launch risk?",
                basis: .recommendation,
                sourceSegmentIDs: [],
                topic: "launch-risk",
                priority: .high
            )]),
            answer: "This reply must not publish after disable."
        )

        let analysisOutcome = await analysisTask.value
        let questionOutcome = await questionTask.value
        let snapshot = await session.snapshot()

        XCTAssertEqual(analysisOutcome, .staleSession)
        XCTAssertEqual(questionOutcome, .staleSession)
        XCTAssertEqual(snapshot.autoInsights, [])
        XCTAssertEqual(snapshot.chatMessages.map(\.role), [.user])
    }
}

final class AICoachModelTests: XCTestCase {
    func testLegacyInsightPayloadDecodesWithLifecycleDefaults() throws {
        let legacy = LegacyCoachInsightPayload(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 123),
            type: .keyInsight,
            content: "Legacy insight",
            role: nil
        )

        let data = try JSONEncoder().encode(legacy)
        let insight = try JSONDecoder().decode(CoachInsight.self, from: data)

        XCTAssertNil(insight.sessionID)
        XCTAssertNil(insight.basis)
        XCTAssertEqual(insight.evidence, [])
        XCTAssertNil(insight.topic)
        XCTAssertEqual(insight.priority, .medium)
        XCTAssertEqual(insight.lifecycle, .active)
    }
}

final class AICoachPanelPresentationTests: XCTestCase {
    func testChatScrollStateOnlyFollowsAnExplicitQuestionThroughItsReply() throws {
        let existingMessage = CoachInsight(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 10),
            type: .keyInsight,
            content: "Existing answer",
            role: .assistant
        )
        let submittedQuestion = CoachInsight(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 20),
            type: .keyInsight,
            content: "What should I clarify?",
            role: .user
        )
        let reply = CoachInsight(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 30),
            type: .keyInsight,
            content: "Clarify who owns rollout approval.",
            role: .assistant
        )

        var state = CoachPanelChatScrollState()

        XCTAssertNil(state.chatMessagesChanged(to: [existingMessage]))
        XCTAssertFalse(state.isFollowingSubmittedExchange)

        let submitRequest = state.submitQuestion()
        XCTAssertEqual(submitRequest.target, .chatSection)
        XCTAssertTrue(state.isFollowingSubmittedExchange)

        let questionRequest = try XCTUnwrap(
            state.chatMessagesChanged(to: [existingMessage, submittedQuestion])
        )
        XCTAssertEqual(questionRequest.target, .message(submittedQuestion.id))

        let thinkingRequest = try XCTUnwrap(state.replyStateChanged(isReplying: true))
        XCTAssertEqual(thinkingRequest.target, .thinking)

        let replyRequest = try XCTUnwrap(
            state.chatMessagesChanged(to: [existingMessage, submittedQuestion, reply])
        )
        XCTAssertEqual(replyRequest.target, .message(reply.id))
        XCTAssertFalse(state.isFollowingSubmittedExchange)
        XCTAssertGreaterThan(replyRequest.sequence, thinkingRequest.sequence)

        let laterMessage = CoachInsight(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 40),
            type: .keyInsight,
            content: "Passive history refresh",
            role: .assistant
        )
        XCTAssertNil(
            state.chatMessagesChanged(to: [existingMessage, submittedQuestion, reply, laterMessage])
        )
        XCTAssertNil(state.replyStateChanged(isReplying: false))
    }

    func testPresentationSeparatesAutoInsightsFromChatAndOrdersActiveGuidanceByPriority() {
        let activeHighID = UUID()
        let activeCriticalID = UUID()
        let dismissedID = UUID()
        let userID = UUID()
        let assistantID = UUID()
        let entries = [
            CoachInsight(
                id: userID,
                timestamp: Date(timeIntervalSince1970: 10),
                type: .keyInsight,
                content: "What should I clarify?",
                role: .user
            ),
            CoachInsight(
                id: activeHighID,
                timestamp: Date(timeIntervalSince1970: 40),
                type: .talkingPoint,
                content: "Confirm the production owner.",
                priority: .high
            ),
            CoachInsight(
                id: assistantID,
                timestamp: Date(timeIntervalSince1970: 20),
                type: .keyInsight,
                content: "Ask which team owns launch approval.",
                role: .assistant
            ),
            CoachInsight(
                id: dismissedID,
                timestamp: Date(timeIntervalSince1970: 50),
                type: .followUp,
                content: "Revisit the capacity plan.",
                priority: .medium,
                lifecycle: .dismissed
            ),
            CoachInsight(
                id: activeCriticalID,
                timestamp: Date(timeIntervalSince1970: 30),
                type: .technicalAnswer,
                content: "Block sizing until the p99 target is defined.",
                priority: .critical
            ),
        ]

        let presentation = CoachPanelPresentation(entries: entries)

        XCTAssertEqual(presentation.activeInsights.map(\.id), [activeCriticalID, activeHighID])
        XCTAssertEqual(presentation.historyInsights.map(\.id), [dismissedID])
        XCTAssertEqual(presentation.chatMessages.map(\.id), [userID, assistantID])
        XCTAssertEqual(presentation.autoInsightCount, 3)
    }

    func testPresentationOnlyExposesEvidenceForTranscriptBackedInsights() throws {
        let firstReference = CoachEvidenceReference(segmentID: 7, startTime: 12, endTime: 15)
        let secondReference = CoachEvidenceReference(segmentID: 9, startTime: 18, endTime: 21)
        let transcriptInsight = CoachInsight(
            type: .keyInsight,
            content: "Confirm whether the p99 target includes queueing.",
            basis: .transcript,
            evidence: [firstReference, secondReference],
            priority: .high
        )
        let recommendation = CoachInsight(
            type: .talkingPoint,
            content: "Recommend a staged rollout.",
            basis: .recommendation,
            evidence: [firstReference],
            priority: .high
        )

        XCTAssertEqual(CoachPanelPresentation.primaryEvidence(for: transcriptInsight), firstReference)
        XCTAssertNil(CoachPanelPresentation.primaryEvidence(for: recommendation))
    }

    func testTranscriptScrollStatePausesForEvidenceAndUserScrollingUntilResumed() throws {
        var state = LiveTranscriptScrollState()
        XCTAssertTrue(state.isFollowingLive)

        state.revealSource(segmentID: 42)
        let firstRequest = try XCTUnwrap(state.sourceRequest)
        XCTAssertEqual(firstRequest.segmentID, 42)
        XCTAssertFalse(state.isFollowingLive)

        state.revealSource(segmentID: 42)
        let repeatedRequest = try XCTUnwrap(state.sourceRequest)
        XCTAssertNotEqual(repeatedRequest.sequence, firstRequest.sequence)

        state.resumeFollowing()
        XCTAssertTrue(state.isFollowingLive)
        XCTAssertNil(state.sourceRequest)

        state.userDidScroll()
        XCTAssertFalse(state.isFollowingLive)
    }
}

private struct FixedCoachClock: CoachClock {
    let now: Date

    func currentDate() -> Date { now }
}

private final class MutableCoachClock: CoachClock, @unchecked Sendable {
    private let lock = NSLock()
    private var now: Date

    init(now: Date) {
        self.now = now
    }

    func currentDate() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return now
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        now = now.addingTimeInterval(interval)
        lock.unlock()
    }
}

private actor SequencedCoachGenerator: AICoachGenerating {
    private var analysisResults: [CoachGenerationResult]
    private var analysisRequestCount = 0

    init(analysisResults: [CoachGenerationResult]) {
        self.analysisResults = analysisResults
    }

    func generateInsights(for request: CoachAnalysisRequest) async throws -> CoachGenerationResult {
        analysisRequestCount += 1
        guard !analysisResults.isEmpty else {
            return .malformed("Unexpected extra analysis request")
        }
        return analysisResults.removeFirst()
    }

    func answerQuestion(_ request: CoachQuestionRequest) async throws -> String {
        ""
    }

    func recordedAnalysisRequestCount() -> Int {
        analysisRequestCount
    }
}

private actor RecordingCoachGenerator: AICoachGenerating {
    private let analysisResult: CoachGenerationResult
    private let answer: String
    private var analysisRequestCount = 0
    private var questionRequests: [CoachQuestionRequest] = []

    init(analysisResult: CoachGenerationResult, answer: String) {
        self.analysisResult = analysisResult
        self.answer = answer
    }

    func generateInsights(for request: CoachAnalysisRequest) async throws -> CoachGenerationResult {
        analysisRequestCount += 1
        return analysisResult
    }

    func answerQuestion(_ request: CoachQuestionRequest) async throws -> String {
        questionRequests.append(request)
        return answer
    }

    func recordedQuestionRequests() -> [CoachQuestionRequest] {
        questionRequests
    }

    func recordedAnalysisRequestCount() -> Int {
        analysisRequestCount
    }
}

private actor HistoryRecordingCoachGenerator: AICoachGenerating {
    private var questionRequests: [CoachQuestionRequest] = []

    func generateInsights(for request: CoachAnalysisRequest) async throws -> CoachGenerationResult {
        guard let id = request.transcriptDelta.last?.id else { return .candidates([]) }
        let padding = String(repeating: "x", count: 120)
        return .candidates([CoachInsightCandidate(
            type: .talkingPoint,
            content: "Ask: What architecture issue \(id) needs review \(padding)?",
            basis: .recommendation,
            sourceSegmentIDs: [],
            topic: "topic-\(id)",
            priority: .high
        )])
    }

    func answerQuestion(_ request: CoachQuestionRequest) async throws -> String {
        questionRequests.append(request)
        return "Review the bounded prior insight context."
    }

    func recordedQuestionRequests() -> [CoachQuestionRequest] {
        questionRequests
    }
}

private actor SuspendedCoachGenerator: AICoachGenerating {
    private var started = false
    private var continuation: CheckedContinuation<CoachGenerationResult, Never>?

    func generateInsights(for request: CoachAnalysisRequest) async throws -> CoachGenerationResult {
        started = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func answerQuestion(_ request: CoachQuestionRequest) async throws -> String {
        ""
    }

    func waitUntilAnalysisStarts() async {
        while !started {
            await Task.yield()
        }
    }

    func resume(with result: CoachGenerationResult) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

private actor SuspendedQuestionCoachGenerator: AICoachGenerating {
    private var questionStarted = false
    private var questionContinuation: CheckedContinuation<String, Never>?

    func generateInsights(for request: CoachAnalysisRequest) async throws -> CoachGenerationResult {
        .candidates([])
    }

    func answerQuestion(_ request: CoachQuestionRequest) async throws -> String {
        questionStarted = true
        return await withCheckedContinuation { continuation in
            questionContinuation = continuation
        }
    }

    func waitUntilQuestionStarts() async {
        while !questionStarted {
            await Task.yield()
        }
    }

    func resumeQuestion(with answer: String) {
        questionContinuation?.resume(returning: answer)
        questionContinuation = nil
    }
}

private actor SuspendedCommitPoint {
    private var isSuspended = false
    private var continuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        isSuspended = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilSuspended() async {
        while !isSuspended {
            await Task.yield()
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class CoachPublicationTestState {
    var coachEnabled = true
}

private actor SuspendedDualCoachGenerator: AICoachGenerating {
    private var analysisStarted = false
    private var questionStarted = false
    private var analysisContinuation: CheckedContinuation<CoachGenerationResult, Never>?
    private var questionContinuation: CheckedContinuation<String, Never>?

    func generateInsights(for request: CoachAnalysisRequest) async throws -> CoachGenerationResult {
        analysisStarted = true
        return await withCheckedContinuation { continuation in
            analysisContinuation = continuation
        }
    }

    func answerQuestion(_ request: CoachQuestionRequest) async throws -> String {
        questionStarted = true
        return await withCheckedContinuation { continuation in
            questionContinuation = continuation
        }
    }

    func waitUntilBothRequestsStart() async {
        while !analysisStarted || !questionStarted {
            await Task.yield()
        }
    }

    func resumeAll(analysis: CoachGenerationResult, answer: String) {
        analysisContinuation?.resume(returning: analysis)
        questionContinuation?.resume(returning: answer)
        analysisContinuation = nil
        questionContinuation = nil
    }
}

private struct LegacyCoachInsightPayload: Encodable {
    let id: UUID
    let timestamp: Date
    let type: CoachInsightType
    let content: String
    let role: CoachRole?
}

private extension CoachContextPolicy {
    static let testing = CoachContextPolicy(
        minimumWordCount: 1,
        minimumNewSegments: 1,
        minimumAnalysisInterval: 0,
        failureRetryInterval: 0,
        maxRecentSegments: 12,
        maxDeltaSegments: 6,
        maxTranscriptCharacters: 9_000,
        maxSpeakerCharacters: 80,
        maxRollingContextCharacters: 500,
        maxChatMessages: 6
    )
}
