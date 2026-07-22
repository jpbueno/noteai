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

    func testAnalysisRequestBoundsTranscriptCharactersAndSpeakerMetadata() throws {
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
        let oversized = TranscriptSegment(
            id: 1,
            text: String(repeating: "context ", count: 50),
            startTime: 0,
            endTime: 1,
            speaker: String(repeating: "speaker", count: 20)
        )

        let request = try XCTUnwrap(context.prepareAnalysis(
            sessionID: UUID(),
            transcript: [oversized],
            now: Date()
        ))

        XCTAssertLessThanOrEqual(request.recentTranscript.reduce(0) { $0 + $1.text.count }, 40)
        XCTAssertLessThanOrEqual(request.transcriptDelta.reduce(0) { $0 + $1.text.count }, 40)
        XCTAssertEqual(request.recentTranscript.first?.speaker?.count, 8)
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

    func testAdmissionCommitmentCorpusConformance() {
        let rejectedCases = [
            "Customer will deliver results tomorrow.",
            "Customer is going to deliver tomorrow.",
            "Ask for logs; customer will deliver tomorrow.",
            "Ask for logs and customer will deliver tomorrow.",
            "Ask whether logs are available, but customer will deliver tomorrow.",
            "Please ask whether logs are available, but customer will deliver tomorrow.",
            "Do not speculate about timing because customer will deliver tomorrow.",
            "Do not assume the customer agreed, but partner will deliver tomorrow.",
            "Customer committed to deliver tomorrow. Is that confirmed?",
            "Acme will deliver tomorrow.",
            "I will send the results.",
            "Customer will be delivering tomorrow.",
            "Customer intends to submit results tomorrow.",
            "Customer expects to provide results tomorrow.",
            "Team will deliver results tomorrow.",
            "Speaker promised to share benchmarks.",
        ]
        let allowedCases = [
            "Ask whether the customer will deliver results tomorrow.",
            "Ask whether: customer will deliver tomorrow.",
            "Ask when the customer will deliver results.",
            "Please ask whether Acme will deliver tomorrow.",
            "Recommend asking whether Acme will deliver tomorrow.",
            "Suggest asking when Acme will deliver tomorrow.",
            "Asking if Acme will deliver tomorrow.",
            "Checking what Acme will deliver tomorrow.",
            "Clarifying who will provide results tomorrow.",
            "Confirming where Acme will deliver results tomorrow.",
            "Do not assume the customer agreed.",
            "Do not infer the customer will deliver tomorrow.",
            "The customer has not agreed to deliver tomorrow.",
            "The customer will not deliver tomorrow.",
            "The customer does not expect to provide results tomorrow.",
            "How will the team deliver these results?",
            "Customer will deliver tomorrow?",
            "Confirm whether the team plans to deliver tomorrow.",
        ]
        let nonTranscriptBases: [CoachInsightBasis] = [.recommendation, .domainKnowledge]
        let nonActionTypes = CoachInsightType.allCases.filter { $0 != .actionItem }

        for content in rejectedCases {
            for type in CoachInsightType.allCases {
                for basis in nonTranscriptBases {
                    let decision = CoachAdmissionPolicy.default.evaluate(
                        candidates: [candidate(
                            type: type,
                            content: content,
                            basis: basis,
                            sourceSegmentIDs: []
                        )],
                        transcript: [],
                        existingInsights: [],
                        sessionID: UUID(),
                        now: Date()
                    )

                    let context = "\(type.rawValue)/\(basis.rawValue): \(content)"
                    XCTAssertEqual(decision.accepted, [], context)
                    XCTAssertEqual(decision.rejections.map(\.reason), [.unsupportedCommitment], context)
                }
            }
        }

        for content in allowedCases {
            for type in nonActionTypes {
                let decision = CoachAdmissionPolicy.default.evaluate(
                    candidates: [candidate(
                        type: type,
                        content: content,
                        basis: .recommendation,
                        sourceSegmentIDs: []
                    )],
                    transcript: [],
                    existingInsights: [],
                    sessionID: UUID(),
                    now: Date()
                )

                let context = "\(type.rawValue): \(content)"
                XCTAssertEqual(decision.accepted.map(\.content), [content], context)
                XCTAssertEqual(decision.rejections, [], context)
            }
        }
    }

    func testAdmissionAllowsGroundedCommitmentObservationsAcrossCandidateTypes() {
        let content = "Customer will deliver results tomorrow."
        let transcript = [TranscriptSegment(id: 1, text: content)]

        for type in CoachInsightType.allCases {
            let decision = CoachAdmissionPolicy.default.evaluate(
                candidates: [candidate(
                    type: type,
                    content: content,
                    sourceSegmentIDs: [1]
                )],
                transcript: transcript,
                existingInsights: [],
                sessionID: UUID(),
                now: Date()
            )

            XCTAssertEqual(decision.accepted.map(\.type), [type], type.rawValue)
            XCTAssertEqual(decision.rejections, [], type.rawValue)
        }
    }

    func testAdmissionRejectsCommitmentsWithoutTextuallyGroundedTranscriptSupport() {
        let content = "Customer will deliver results tomorrow."
        let unsupportedEvidence = [
            "No commitment was discussed.",
            "Partner will deliver logs tomorrow.",
            "Will the customer deliver results tomorrow?",
        ]

        for (index, evidence) in unsupportedEvidence.enumerated() {
            let segmentID = index + 1
            let decision = CoachAdmissionPolicy.default.evaluate(
                candidates: [candidate(
                    type: .keyInsight,
                    content: content,
                    sourceSegmentIDs: [segmentID]
                )],
                transcript: [TranscriptSegment(id: segmentID, text: evidence)],
                existingInsights: [],
                sessionID: UUID(),
                now: Date()
            )

            XCTAssertEqual(decision.accepted, [], evidence)
            XCTAssertEqual(decision.rejections.map(\.reason), [.unsupportedCommitment], evidence)
        }
    }

    func testAdmissionAllowsGroundedUtilizationDataActionItemParaphrase() {
        let evidence = "The customer committed to sending utilization data."
        let decision = CoachAdmissionPolicy.default.evaluate(
            candidates: [candidate(
                type: .actionItem,
                content: "Track the customer's utilization-data commitment.",
                sourceSegmentIDs: [12]
            )],
            transcript: [TranscriptSegment(id: 12, text: evidence, startTime: 120, endTime: 128)],
            existingInsights: [],
            sessionID: UUID(),
            now: Date()
        )

        XCTAssertEqual(decision.accepted.map(\.type), [.actionItem])
        XCTAssertEqual(decision.accepted.first?.evidence, [
            CoachEvidenceReference(segmentID: 12, startTime: 120, endTime: 128),
        ])
        XCTAssertEqual(decision.rejections, [])
    }

    func testAdmissionPreservesPresentTenseDomainKnowledgeButRejectsFutureClaim() {
        let presentTense = CoachAdmissionPolicy.default.evaluate(
            candidates: [candidate(
                type: .technicalAnswer,
                content: "Dynamo provides cache-aware routing.",
                basis: .domainKnowledge,
                sourceSegmentIDs: []
            )],
            transcript: [],
            existingInsights: [],
            sessionID: UUID(),
            now: Date()
        )
        let futureTense = CoachAdmissionPolicy.default.evaluate(
            candidates: [candidate(
                type: .technicalAnswer,
                content: "Dynamo will deliver cache-aware routing.",
                basis: .domainKnowledge,
                sourceSegmentIDs: []
            )],
            transcript: [],
            existingInsights: [],
            sessionID: UUID(),
            now: Date()
        )

        XCTAssertEqual(presentTense.accepted.map(\.content), ["Dynamo provides cache-aware routing."])
        XCTAssertEqual(presentTense.rejections, [])
        XCTAssertEqual(futureTense.accepted, [])
        XCTAssertEqual(futureTense.rejections.map(\.reason), [.unsupportedCommitment])
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

        XCTAssertEqual(missingTopic.rejections.map(\.reason), [.invalidTopic])
        XCTAssertEqual(excessiveEvidence.rejections.map(\.reason), [.tooManyEvidenceReferences])
    }

    func testDefaultAdmissionBudgetNeverExceedsTenInsightsAcrossFiftyMinuteReplay() {
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
        }

        XCTAssertEqual(accepted.count, 10)
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
    func testParserDistinguishesLegitimateNoOpFromMalformedOutput() {
        XCTAssertEqual(AICoachEngine.parseAnalysisResponse("[]"), .candidates([]))

        let malformed = AICoachEngine.parseAnalysisResponse("No insight right now")
        guard case .malformed = malformed else {
            return XCTFail("Expected malformed output, got \(malformed)")
        }

        let proseWrappedNoOp = AICoachEngine.parseAnalysisResponse("No insight right now: []")
        guard case .malformed = proseWrappedNoOp else {
            return XCTFail("Expected prose-wrapped JSON to remain malformed, got \(proseWrappedNoOp)")
        }
    }

    func testParserPreservesEvidenceBasisTopicAndPriority() throws {
        let output = AICoachEngine.parseAnalysisResponse("""
        [{
          "type": "talking_point",
          "content": "Ask whether the 250 ms target includes queueing.",
          "basis": "transcript",
          "source_segment_ids": [7],
          "topic": "latency-slo",
          "priority": "high"
        }]
        """)

        guard case .candidates(let candidates) = output else {
            return XCTFail("Expected parsed candidates, got \(output)")
        }
        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertEqual(candidate.basis, .transcript)
        XCTAssertEqual(candidate.sourceSegmentIDs, [7])
        XCTAssertEqual(candidate.topic, "latency-slo")
        XCTAssertEqual(candidate.priority, .high)
    }

    func testInteractiveMessagesSendCurrentQuestionExactlyOnceAndKeepTranscriptOutOfSystemRole() {
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

        let messages = AICoachEngine.makeInteractiveMessages(request: request)

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

        let message = try XCTUnwrap(AICoachEngine.makeAnalysisMessages(request: request).last?.content)
        let json = try XCTUnwrap(message.split(separator: "\n", maxSplits: 1).last)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let recent = try XCTUnwrap(object["recentTranscript"] as? [[String: Any]])
        let delta = try XCTUnwrap(object["transcriptDelta"] as? [[String: Any]])

        XCTAssertEqual(recent.compactMap { $0["id"] as? Int }, [1])
        XCTAssertEqual(delta.compactMap { $0["id"] as? Int }, [2])
    }
}

final class AICoachSessionTests: XCTestCase {
    @MainActor
    func testSessionAndMeetingManagerExposeNarrowLifecycleMutationInterface() {
        func requireLifecycleInterface<T: CoachInsightLifecycleMutating>(_: T.Type) {}

        requireLifecycleInterface(LiveCoachSession.self)
        requireLifecycleInterface(MeetingManager.self)
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

    func testReactivationCannotExceedActiveInsightBudget() async throws {
        let generator = SequencedCoachGenerator(analysisResults: [
            .candidates([CoachInsightCandidate(
                type: .talkingPoint,
                content: "Confirm who owns the production rollout.",
                basis: .transcript,
                sourceSegmentIDs: [1],
                topic: "rollout-ownership",
                priority: .high
            )]),
            .candidates([CoachInsightCandidate(
                type: .talkingPoint,
                content: "Ask which latency percentile gates production launch.",
                basis: .transcript,
                sourceSegmentIDs: [2],
                topic: "latency-gate",
                priority: .high
            )]),
        ])
        let session = LiveCoachSession(
            generator: generator,
            clock: FixedCoachClock(now: Date()),
            contextPolicy: .testing,
            admissionPolicy: CoachAdmissionPolicy(
                maxCandidatesPerGeneration: 2,
                maxActiveInsights: 1,
                maxContentCharacters: 180,
                maxContentWords: 24,
                maxTopicCharacters: 64,
                maxEvidenceReferences: 4,
                minimumPriority: .high,
                nearDuplicateThreshold: 0.82,
                topicCooldown: 300
            )
        )
        let firstTranscript = [TranscriptSegment(id: 1, text: "Production rollout ownership is undecided.")]
        guard case .admitted(let firstInsights) = await session.analyze(transcript: firstTranscript),
              let firstInsight = firstInsights.first else {
            return XCTFail("Expected the first insight")
        }
        _ = await session.setAutoInsightLifecycle(id: firstInsight.id, lifecycle: .dismissed)

        let secondTranscript = firstTranscript + [
            TranscriptSegment(id: 2, text: "Production launch needs a latency percentile gate."),
        ]
        guard case .admitted = await session.analyze(transcript: secondTranscript) else {
            return XCTFail("Expected the second insight after dismissing the first")
        }

        let reactivation = await session.setAutoInsightLifecycle(id: firstInsight.id, lifecycle: .active)
        XCTAssertEqual(reactivation, .activeBudgetExceeded)
        let snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.autoInsights.filter { $0.lifecycle == .active }.count, 1)
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

private actor SequencedCoachGenerator: AICoachGenerating {
    private var analysisResults: [CoachGenerationResult]

    init(analysisResults: [CoachGenerationResult]) {
        self.analysisResults = analysisResults
    }

    func generateInsights(for request: CoachAnalysisRequest) async throws -> CoachGenerationResult {
        guard !analysisResults.isEmpty else { return .candidates([]) }
        return analysisResults.removeFirst()
    }

    func answerQuestion(_ request: CoachQuestionRequest) async throws -> String {
        ""
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
