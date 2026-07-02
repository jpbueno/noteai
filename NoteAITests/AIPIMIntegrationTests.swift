import XCTest
import Darwin
@testable import NoteAI

final class AIPIMIntegrationTests: XCTestCase {
    func testExecutableDiscoveryIncludesConfiguredAndCommonLocations() {
        let configured = URL(fileURLWithPath: "/Applications/ai-pim-utils/bin", isDirectory: true)
        let discovery = AIPIMExecutableDiscovery(
            configuredDirectories: [configured],
            environment: [:],
            homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)
        )

        XCTAssertEqual(discovery.candidateDirectories.first, configured)
        XCTAssertTrue(discovery.candidateDirectories.contains(URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true)))
        XCTAssertTrue(discovery.candidateDirectories.contains(URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)))
        XCTAssertTrue(discovery.candidateDirectories.contains(URL(fileURLWithPath: "/Users/example/.local/bin", isDirectory: true)))
    }

    func testProcessRunnerUsesArgumentsWithoutShellExpansion() async throws {
        let command = AIPIMCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["%s", "$HOME; echo unsafe"],
            timeout: 2,
            maxOutputBytes: 1_024
        )

        let result = try await AIPIMProcessRunner().execute(command)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "$HOME; echo unsafe")
    }

    func testProcessRunnerMergesNarrowNoninteractiveOverrideIntoInheritedEnvironment() async throws {
        let runner = AIPIMProcessRunner()
        let overrideResult = try await runner.execute(AIPIMCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/printenv"),
            arguments: ["AI_PIM_UTILS_AUTH_INTERACTIVITY"],
            timeout: 2,
            maxOutputBytes: 1_024,
            environment: .noninteractive
        ))
        let inheritedResult = try await runner.execute(AIPIMCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/printenv"),
            arguments: ["PATH"],
            timeout: 2,
            maxOutputBytes: 8_192,
            environment: .noninteractive
        ))

        XCTAssertEqual(String(decoding: overrideResult.stdout, as: UTF8.self), "never\n")
        XCTAssertFalse(inheritedResult.stdout.isEmpty)
    }

    func testProcessRunnerTerminatesCommandsThatExceedTimeout() async {
        let command = AIPIMCommand(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["2"],
            timeout: 0.05,
            maxOutputBytes: 1_024
        )

        do {
            _ = try await AIPIMProcessRunner().execute(command)
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? AIPIMExecutionError, .timedOut)
        }
    }

    func testProcessRunnerTimeoutKillsPipeRetainingDescendantsPromptly() async {
        let command = AIPIMCommand(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "(trap '' TERM HUP; sleep 5) & wait"],
            timeout: 0.05,
            maxOutputBytes: 1_024
        )
        let startedAt = Date()

        do {
            _ = try await AIPIMProcessRunner().execute(command)
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? AIPIMExecutionError, .timedOut)
        }

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
    }

    func testProcessRunnerRejectsOutputBeyondConfiguredLimit() async {
        let command = AIPIMCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["1234567890"],
            timeout: 2,
            maxOutputBytes: 4
        )

        do {
            _ = try await AIPIMProcessRunner().execute(command)
            XCTFail("Expected output limit failure")
        } catch {
            XCTAssertEqual(error as? AIPIMExecutionError, .outputLimitExceeded)
        }
    }

    func testProcessRunnerOutputLimitKillsPipeRetainingDescendantsPromptly() async {
        let command = AIPIMCommand(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "(trap '' TERM HUP; sleep 5) & printf 1234567890; wait"],
            timeout: 2,
            maxOutputBytes: 4
        )
        let startedAt = Date()

        do {
            _ = try await AIPIMProcessRunner().execute(command)
            XCTFail("Expected output limit failure")
        } catch {
            XCTAssertEqual(error as? AIPIMExecutionError, .outputLimitExceeded)
        }

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
    }

    func testProcessRunnerSustainedConcurrentOutputCannotBypassOutputLimit() async {
        let command = AIPIMCommand(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", sustainedConcurrentOutputCommand],
            timeout: 2,
            maxOutputBytes: 4_096
        )
        let startedAt = ProcessInfo.processInfo.systemUptime

        do {
            _ = try await AIPIMProcessRunner().execute(command)
            XCTFail("Expected output limit failure")
        } catch {
            XCTAssertEqual(error as? AIPIMExecutionError, .outputLimitExceeded)
        }

        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - startedAt, 0.5)
    }

    func testProcessRunnerSustainedConcurrentOutputCannotBypassTimeout() async {
        let command = AIPIMCommand(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", sustainedConcurrentOutputCommand],
            timeout: 0.01,
            maxOutputBytes: 64 * 1_024 * 1_024
        )
        let startedAt = ProcessInfo.processInfo.systemUptime

        do {
            _ = try await AIPIMProcessRunner().execute(command)
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? AIPIMExecutionError, .timedOut)
        }

        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - startedAt, 0.5)
    }

    func testProcessRunnerCancellationTerminatesAndReapsProcessGroupPromptly() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("noteai-aipim-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let command = AIPIMCommand(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "printf '%s' $$ > \"$1\"; (trap '' TERM HUP; sleep 30) & wait",
                "aipim-cancellation-test",
                pidFile.path
            ],
            timeout: 1,
            maxOutputBytes: 1_024
        )
        let task = Task {
            try await AIPIMProcessRunner().execute(command)
        }
        let processID = try await waitForProcessID(in: pidFile)
        let startedAt = ProcessInfo.processInfo.systemUptime

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - startedAt, 0.5)
        let processGroupExited = await waitForProcessGroupExit(processID)
        XCTAssertTrue(processGroupExited)
    }

    func testSlackStatusRequiresSuccessAndAUserID() async {
        let executor = FakeAIPIMExecutor(results: [
            .success(jsonResult(["success": true, "data": ["user": ["id": "U123", "email": "private@example.com"]]]))
        ])
        let client = makeClient(executor: executor)

        let status = await client.status(for: .slack)

        XCTAssertEqual(status.state, .available)
        XCTAssertTrue(status.installed)
        XCTAssertTrue(status.authenticated)
        let commands = await executor.commands
        XCTAssertEqual(commands.map(\.arguments), [["me", "--output", "json"]])
        XCTAssertFalse(status.message.contains("private@example.com"))
    }

    func testSlackLoginRunsInteractiveLoginThenMachineVerification() async {
        let executor = FakeAIPIMExecutor(results: [
            .success(AIPIMCommandResult(exitCode: 0, stdout: Data("private callback".utf8))),
            .success(jsonResult(["success": true, "data": ["user": ["id": "U123"]]]))
        ])
        let client = makeClient(executor: executor)

        let status = await client.login(to: .slack)

        XCTAssertEqual(status.state, .available)
        let commands = await executor.commands
        XCTAssertEqual(commands.map(\.arguments), [
            ["auth", "login"],
            ["me", "--output", "json"]
        ])
        XCTAssertFalse(status.message.contains("private callback"))
    }

    func testTeamsStatusRequiresAuthenticatedUsername() async {
        let executor = FakeAIPIMExecutor(results: [
            .success(jsonResult(["authenticated": true, "username": "person@example.com"]))
        ])
        let client = makeClient(executor: executor)

        let status = await client.status(for: .teams)

        XCTAssertEqual(status.state, .available)
        XCTAssertTrue(status.authenticated)
        let commands = await executor.commands
        XCTAssertEqual(commands.map(\.arguments), [["auth", "status", "--json"]])
        XCTAssertFalse(status.message.contains("person@example.com"))
    }

    func testTeamsStatusFailsClosedWithoutAuthenticatedUsername() async {
        let executor = FakeAIPIMExecutor(results: [
            .success(jsonResult(["authenticated": true]))
        ])
        let client = makeClient(executor: executor)

        let status = await client.status(for: .teams)

        XCTAssertEqual(status.state, .failed)
        XCTAssertFalse(status.authenticated)
    }

    func testTeamsLoginRunsInteractiveLoginThenUsernameBearingVerification() async {
        let executor = FakeAIPIMExecutor(results: [
            .success(AIPIMCommandResult(exitCode: 0, stdout: Data())),
            .success(jsonResult(["authenticated": true, "username": "person@example.com"]))
        ])
        let client = makeClient(executor: executor)

        let status = await client.login(to: .teams)

        XCTAssertEqual(status.state, .available)
        XCTAssertTrue(status.authenticated)
        let commands = await executor.commands
        XCTAssertEqual(commands.map(\.arguments), [
            ["auth", "login"],
            ["auth", "status", "--json"]
        ])
    }

    func testTeamsLoginFailsClosedWhenVerificationHasNoUsername() async {
        let executor = FakeAIPIMExecutor(results: [
            .success(AIPIMCommandResult(exitCode: 0, stdout: Data())),
            .success(jsonResult(["authenticated": true]))
        ])
        let client = makeClient(executor: executor)

        let status = await client.login(to: .teams)

        XCTAssertEqual(status.state, .failed)
        XCTAssertFalse(status.authenticated)
    }

    func testOutlookStatusAcceptsDirectAuthenticatedShapeWithoutExposingIdentity() async {
        let executor = FakeAIPIMExecutor(results: [
            .success(jsonResult(["authenticated": true, "username": "private@example.com"]))
        ])
        let client = makeClient(executor: executor)

        let status = await client.status(for: .outlook)

        XCTAssertEqual(status.state, .available)
        XCTAssertTrue(status.installed)
        XCTAssertTrue(status.authenticated)
        let commands = await executor.commands
        XCTAssertEqual(commands.map(\.arguments), [["auth", "status", "--json"]])
        XCTAssertEqual(commands.first?.environment, .noninteractive)
        XCTAssertFalse(status.message.contains("private@example.com"))
    }

    func testOutlookStatusAcceptsSuccessfulEnvelopeShape() async {
        let executor = FakeAIPIMExecutor(results: [
            .success(jsonResult([
                "success": true,
                "data": ["authenticated": true, "username": "private@example.com"],
                "metadata": ["version": "0.105.0"]
            ]))
        ])
        let client = makeClient(executor: executor)

        let status = await client.status(for: .outlook)

        XCTAssertEqual(status.state, .available)
        XCTAssertTrue(status.authenticated)
    }

    func testOutlookStatusAcceptsAuthenticatedEnvelopeWithoutUsername() async {
        let executor = FakeAIPIMExecutor(results: [
            .success(jsonResult(["success": true, "data": ["authenticated": true]]))
        ])
        let client = makeClient(executor: executor)

        let status = await client.status(for: .outlook)

        XCTAssertEqual(status.state, .available)
        XCTAssertTrue(status.authenticated)
    }

    func testOutlookStatusFailsClosedWhenAuthenticatedFieldIsMissing() async {
        let executor = FakeAIPIMExecutor(results: [
            .success(jsonResult(["success": true, "data": ["username": "private@example.com"]]))
        ])
        let client = makeClient(executor: executor)

        let status = await client.status(for: .outlook)

        XCTAssertEqual(status.state, .failed)
        XCTAssertFalse(status.authenticated)
    }

    func testOutlookStatusMapsExitTwoToAuthenticationRequired() async {
        let executor = FakeAIPIMExecutor(results: [
            .success(AIPIMCommandResult(exitCode: 2, stdout: Data("private auth output".utf8)))
        ])
        let client = makeClient(executor: executor)

        let status = await client.status(for: .outlook)

        XCTAssertEqual(status.state, .authenticationRequired)
        XCTAssertFalse(status.authenticated)
        XCTAssertFalse(status.message.contains("private auth output"))
    }

    func testOutlookStatusTreatsExitZeroAuthenticatedFalseAsAuthenticationRequired() async {
        let executor = FakeAIPIMExecutor(results: [
            .success(jsonResult(["authenticated": false]))
        ])
        let client = makeClient(executor: executor)

        let status = await client.status(for: .outlook)

        XCTAssertEqual(status.state, .authenticationRequired)
        XCTAssertFalse(status.authenticated)
    }

    func testOutlookLoginUsesBrowserLoginThenVerifiesEnvelopeStatus() async {
        let executor = FakeAIPIMExecutor(results: [
            .success(AIPIMCommandResult(exitCode: 0, stdout: Data("private callback".utf8))),
            .success(jsonResult([
                "success": true,
                "data": ["authenticated": true, "username": "private@example.com"]
            ]))
        ])
        let client = makeClient(executor: executor)

        let status = await client.login(to: .outlook)

        XCTAssertEqual(status.state, .available)
        let commands = await executor.commands
        XCTAssertEqual(commands.map(\.arguments), [
            ["auth", "login", "--browser"],
            ["auth", "status", "--json"]
        ])
        XCTAssertEqual(commands.first?.environment, .inherited)
        XCTAssertEqual(commands.last?.environment, .noninteractive)
        XCTAssertFalse(status.message.contains("private"))
    }

    func testOutlookSearchUsesBoundedProjectedCommandAndFiltersInterval() async throws {
        let executor = FakeAIPIMExecutor(results: [
            .success(jsonResult([
                "success": true,
                "data": [
                    [
                        "id": "message-in-range",
                        "conversationId": "thread-1",
                        "subject": "Nscale routing",
                        "from": ["emailAddress": ["name": "Alex", "address": "alex@example.com"]],
                        "receivedDateTime": "2026-07-01T15:00:00Z",
                        "bodyPreview": "Shipped the routing plan.",
                        "webLink": "https://outlook.office.com/mail/message-in-range"
                    ],
                    [
                        "id": "message-before-range",
                        "receivedDateTime": "2026-06-30T23:59:59Z",
                        "bodyPreview": "Too early"
                    ],
                    [
                        "id": "message-after-range",
                        "receivedDateTime": "2026-07-03T00:00:00Z",
                        "bodyPreview": "Too late"
                    ]
                ],
                "metadata": ["count": 3]
            ]))
        ])
        let client = makeClient(executor: executor)

        let result = try await client.searchOutlook(in: makeInterval(), limit: 12)

        XCTAssertEqual(result.source, .outlook)
        XCTAssertEqual(result.items.map(\.id), ["message-in-range"])
        XCTAssertEqual(result.items.map(\.body), ["Shipped the routing plan."])
        let commands = await executor.commands
        let command = try XCTUnwrap(commands.first)
        XCTAssertEqual(command.arguments, [
            "message", "find",
            "--folder", "sent",
            "--after", "2026-07-01T00:00:00Z",
            "--before", "2026-07-03T00:00:00Z",
            "--limit", "12",
            "--fields", "id,conversationId,subject,from,receivedDateTime,bodyPreview,webLink",
            "--json"
        ])
        XCTAssertEqual(command.environment, .noninteractive)
        XCTAssertLessThanOrEqual(command.timeout, 30)
        XCTAssertLessThanOrEqual(command.maxOutputBytes, 1_048_576)
    }

    func testOutlookSearchLocallyCapsOverreturnedMessages() async throws {
        let messages = (0..<3).map { index in
            [
                "id": "message-\(index)",
                "receivedDateTime": "2026-07-01T1\(index):00:00Z",
                "bodyPreview": "Message \(index)"
            ]
        }
        let executor = FakeAIPIMExecutor(results: [
            .success(jsonResult(["success": true, "data": messages]))
        ])
        let client = makeClient(executor: executor)

        let result = try await client.searchOutlook(in: makeInterval(), limit: 2)

        XCTAssertEqual(result.items.map(\.id), ["message-2", "message-1"])
        XCTAssertTrue(result.isPartial)
        XCTAssertEqual(result.partialReasons, ["result_limit_reached"])
    }

    func testOutlookSearchConservativelyMarksRequestedLimitAsPartial() async throws {
        let messages = (0..<2).map { index in
            [
                "id": "message-\(index)",
                "receivedDateTime": "2026-07-01T1\(index):00:00Z",
                "bodyPreview": "Message \(index)"
            ]
        }
        let executor = FakeAIPIMExecutor(results: [
            .success(jsonResult(["success": true, "data": messages]))
        ])
        let client = makeClient(executor: executor)

        let result = try await client.searchOutlook(in: makeInterval(), limit: 2)

        XCTAssertTrue(result.isPartial)
        XCTAssertEqual(result.partialReasons, ["result_limit_reached"])
    }

    func testOutlookSearchDecodesSnakeCasePaginationHasMore() async throws {
        let executor = FakeAIPIMExecutor(results: [
            .success(jsonResult([
                "success": true,
                "data": [[
                    "id": "message-1",
                    "receivedDateTime": "2026-07-01T15:00:00Z",
                    "bodyPreview": "First page"
                ]],
                "metadata": ["pagination": ["has_more": true]]
            ]))
        ])
        let client = makeClient(executor: executor)

        let result = try await client.searchOutlook(in: makeInterval(), limit: 10)

        XCTAssertTrue(result.isPartial)
    }

    func testOutlookSearchDecodesCamelCasePaginationHasMore() async throws {
        let executor = FakeAIPIMExecutor(results: [
            .success(jsonResult([
                "success": true,
                "data": [[
                    "id": "message-1",
                    "receivedDateTime": "2026-07-01T15:00:00Z",
                    "bodyPreview": "First page"
                ]],
                "metadata": ["pagination": ["hasMore": true]]
            ]))
        ])
        let client = makeClient(executor: executor)

        let result = try await client.searchOutlook(in: makeInterval(), limit: 10)

        XCTAssertTrue(result.isPartial)
    }

    func testOutlookSearchAcceptsWrappedMessageEnvelope() async throws {
        let executor = FakeAIPIMExecutor(results: [
            .success(jsonResult([
                "success": true,
                "data": ["messages": [[
                    "id": "message-1",
                    "receivedDateTime": "2026-07-01T15:00:00.123Z",
                    "bodyPreview": "Version-compatible envelope"
                ]]]
            ]))
        ])
        let client = makeClient(executor: executor)

        let result = try await client.searchOutlook(in: makeInterval(), limit: 10)

        XCTAssertEqual(result.items.map(\.id), ["message-1"])
    }

    func testOutlookSearchTreatsNullDataAsEmptyResults() async throws {
        let executor = FakeAIPIMExecutor(results: [
            .success(jsonResult(["success": true, "data": NSNull()]))
        ])
        let client = makeClient(executor: executor)

        let result = try await client.searchOutlook(in: makeInterval(), limit: 10)

        XCTAssertEqual(result.items, [])
        XCTAssertFalse(result.isPartial)
    }

    func testOutlookSearchFailsClosedOnMalformedMessageData() async throws {
        let executor = FakeAIPIMExecutor(results: [
            .success(jsonResult([
                "success": true,
                "data": [["id": "message-1", "bodyPreview": "Missing received date"]]
            ]))
        ])
        let client = makeClient(executor: executor)

        do {
            _ = try await client.searchOutlook(in: makeInterval(), limit: 10)
            XCTFail("Expected malformed Outlook response to fail")
        } catch {
            XCTAssertEqual(error as? AIPIMError, .invalidResponse(.outlook))
        }
    }

    func testOutlookSearchMapsExitTwoToAuthenticationRequired() async throws {
        let executor = FakeAIPIMExecutor(results: [
            .success(AIPIMCommandResult(exitCode: 2, stdout: Data("private auth output".utf8)))
        ])
        let client = makeClient(executor: executor)

        do {
            _ = try await client.searchOutlook(in: makeInterval(), limit: 10)
            XCTFail("Expected Outlook authentication requirement")
        } catch {
            XCTAssertEqual(error as? AIPIMError, .authenticationRequired(.outlook))
        }
    }

    func testOutlookTaskSearchFiltersQueryAndSenderAndPreservesMinimalMetadata() async throws {
        let executor = FakeAIPIMExecutor(results: [
            .success(jsonResult([
                "success": true,
                "data": [
                    [
                        "id": "message-3",
                        "conversationId": "thread-3",
                        "subject": "Gateway routing notes",
                        "from": ["emailAddress": ["name": "Alex", "address": "alex@example.com"]],
                        "receivedDateTime": "2026-07-01T14:00:00Z",
                        "bodyPreview": "Earlier gateway routing request.",
                        "webLink": "https://outlook.office.com/mail/message-3"
                    ],
                    [
                        "id": "message-1",
                        "conversationId": "thread-1",
                        "subject": "RE: Nscale routing follow-up",
                        "from": ["emailAddress": ["name": "Alex", "address": "alex@example.com"]],
                        "receivedDateTime": "2026-07-01T15:00:00Z",
                        "bodyPreview": " Please send the gateway routing summary.   Thanks. ",
                        "webLink": "https://outlook.office.com/mail/message-1"
                    ],
                    [
                        "id": "message-2",
                        "subject": "Nscale routing follow-up",
                        "from": ["emailAddress": ["name": "Taylor", "address": "taylor@example.com"]],
                        "receivedDateTime": "2026-07-01T16:00:00Z",
                        "bodyPreview": "Wrong sender"
                    ]
                ]
            ]))
        ])
        let client = makeClient(executor: executor)
        let interval = try makeInterval()
        let request = OutlookMailSearchRequest(
            query: "gateway routing",
            after: interval.start,
            before: interval.end,
            sender: "alex@example.com",
            limit: 10
        )

        let candidates = try await client.searchOutlookTaskCandidates(request)

        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertEqual(candidates.map(\.id), ["message-1", "message-3"])
        XCTAssertEqual(candidate.title, "Nscale routing follow-up")
        XCTAssertEqual(candidate.description, "Please send the gateway routing summary. Thanks.")
        XCTAssertEqual(candidate.sourceMetadata.kind, .email)
        XCTAssertEqual(candidate.sourceMetadata.provider, "outlook")
        XCTAssertEqual(candidate.sourceMetadata.threadID, "thread-1")
        XCTAssertEqual(candidate.sourceMetadata.messageID, "message-1")
        XCTAssertEqual(candidate.sourceMetadata.subject, "RE: Nscale routing follow-up")
        XCTAssertEqual(candidate.sourceMetadata.sender, "Alex <alex@example.com>")
        XCTAssertEqual(candidate.sourceMetadata.url, "https://outlook.office.com/mail/message-1")
        let commands = await executor.commands
        XCTAssertEqual(commands.first?.arguments, [
            "message", "find",
            "--folder", "inbox",
            "--after", "2026-07-01T00:00:00Z",
            "--before", "2026-07-03T00:00:00Z",
            "--limit", "25",
            "--fields", "id,conversationId,subject,from,receivedDateTime,bodyPreview,webLink",
            "--json"
        ])
        XCTAssertEqual(commands.first?.environment, .noninteractive)
    }

    func testOutlookTaskSearchFetchesBoundedMaximumBeforeFilteringAndCapsOutput() async throws {
        let executor = FakeAIPIMExecutor(results: [
            .success(jsonResult([
                "success": true,
                "data": [
                    [
                        "id": "unrelated-newer",
                        "subject": "Unrelated",
                        "from": ["emailAddress": ["address": "other@example.com"]],
                        "receivedDateTime": "2026-07-01T16:00:00Z",
                        "bodyPreview": "Not a match"
                    ],
                    [
                        "id": "matching-older",
                        "subject": "Gateway routing follow-up",
                        "from": ["emailAddress": ["address": "alex@example.com"]],
                        "receivedDateTime": "2026-07-01T15:00:00Z",
                        "bodyPreview": "Please send the routing summary"
                    ],
                    [
                        "id": "matching-oldest",
                        "subject": "Gateway routing notes",
                        "from": ["emailAddress": ["address": "alex@example.com"]],
                        "receivedDateTime": "2026-07-01T14:00:00Z",
                        "bodyPreview": "Another routing request"
                    ]
                ]
            ]))
        ])
        let client = makeClient(executor: executor)
        let interval = try makeInterval()

        let candidates = try await client.searchOutlookTaskCandidates(OutlookMailSearchRequest(
            query: "gateway routing",
            after: interval.start,
            before: interval.end,
            sender: "alex@example.com",
            limit: 1
        ))

        XCTAssertEqual(candidates.map(\.id), ["matching-older"])
        let commands = await executor.commands
        let command = try XCTUnwrap(commands.first)
        XCTAssertEqual(Array(command.arguments[8...9]), ["--limit", "25"])
    }

    func testSlackSearchUsesBoundedFilterAndRejectsUntrustedMatches() async throws {
        let interval = try makeInterval()
        let validTimestamp = String(interval.start.addingTimeInterval(3_600).timeIntervalSince1970)
        let executor = FakeAIPIMExecutor(results: [
            .success(jsonResult(["success": true, "data": ["user": ["id": "U123"]]])),
            .success(jsonResult([
                "success": true,
                "data": [
                    "messages": [
                        "total": 4,
                        "matches": [
                            ["ts": validTimestamp, "user": "U123", "username": "JP", "text": "Shipped native sources", "channel": ["id": "C1", "name": "noteai"]],
                            ["ts": validTimestamp, "user": "U999", "username": "Other", "text": "Not mine", "channel": ["id": "C1", "name": "noteai"]],
                            ["ts": validTimestamp, "user": "U123", "username": "JP", "text": "   ", "channel": ["id": "C1", "name": "noteai"]],
                            ["ts": "bad", "user": "U123", "username": "JP", "text": "Bad timestamp", "channel": ["id": "C1", "name": "noteai"]]
                        ],
                        "pagination": ["page": 1, "page_count": 1]
                    ]
                ]
            ]))
        ])
        let client = makeClient(executor: executor)

        let result = try await client.searchSlack(in: interval, limit: 25)

        XCTAssertEqual(result.items.map(\.body), ["Shipped native sources"])
        let commands = await executor.commands
        XCTAssertEqual(commands[1].arguments, [
            "message", "search",
            "--query", "from:me after:2026-07-01 before:2026-07-03",
            "--limit", "25",
            "--page", "1",
            "--output", "json"
        ])
        XCTAssertLessThanOrEqual(commands[1].timeout, 30)
        XCTAssertLessThanOrEqual(commands[1].maxOutputBytes, 1_048_576)
    }

    func testTeamsSearchCorrelatesMemberAndNormalizesHTMLWithPartialCoverage() async throws {
        let interval = try makeInterval()
        let executor = FakeAIPIMExecutor(results: [
            .success(jsonResult(["authenticated": true, "username": "JP@EXAMPLE.COM"])),
            .success(jsonResult(["success": true, "data": [["id": "chat-1", "chatType": "group", "topic": "NoteAI"]]])),
            .success(jsonResult(["success": true, "data": [
                ["email": "jp@example.com", "userId": "user-1"],
                ["email": "other@example.com", "userId": "user-2"]
            ]])),
            .success(jsonResult(["success": true, "data": [
                [
                    "id": "message-1",
                    "createdDateTime": "2026-07-01T15:00:00Z",
                    "from": ["user": ["id": "user-1", "displayName": "JP"]],
                    "body": ["contentType": "html", "content": "<p>Shipped <b>NoteAI</b>&nbsp;adapter.</p><p>Next step ready.</p>"]
                ],
                [
                    "id": "message-2",
                    "createdDateTime": "2026-07-01T16:00:00Z",
                    "from": ["user": ["id": "user-2", "displayName": "Other"]],
                    "body": ["contentType": "text", "content": "Someone else's work"]
                ]
            ]]))
        ])
        let client = makeClient(executor: executor)

        let result = try await client.searchTeams(in: interval, limit: 20, messagesPerChat: 2)

        XCTAssertEqual(result.items.map(\.body), ["Shipped NoteAI adapter.\nNext step ready."])
        XCTAssertTrue(result.isPartial)
        XCTAssertTrue(result.partialReasons.contains("channel_coverage_missing"))
        let commands = await executor.commands
        XCTAssertEqual(commands[1].arguments, ["chat", "list", "--limit", "50", "--fields", "id,chatType,topic", "--json"])
        XCTAssertEqual(commands[2].arguments, ["chat", "members", "chat-1", "--fields", "email,userId", "--json"])
        XCTAssertEqual(commands[3].arguments, ["chat", "read", "chat-1", "--limit", "2", "--fields", "id,createdDateTime,from,body,subject,webUrl", "--json"])
    }

    func testTeamsSearchFailsClosedOnMalformedAuthenticatedIdentity() async {
        let executor = FakeAIPIMExecutor(results: [
            .success(jsonResult(["authenticated": true, "diagnostics": ["cache": "private-path"]]))
        ])
        let client = makeClient(executor: executor)

        do {
            _ = try await client.searchTeams(in: try makeInterval(), limit: 20, messagesPerChat: 2)
            XCTFail("Expected malformed identity to fail")
        } catch {
            XCTAssertEqual(error as? AIPIMError, .invalidResponse(.teams))
        }
        let commands = await executor.commands
        XCTAssertEqual(commands.count, 1)
    }

    func testTeamsSearchRejectsOptionLikeChatIDsAndFailsWhenNoneAreReadable() async throws {
        let executor = FakeAIPIMExecutor(results: [
            .success(jsonResult(["authenticated": true, "username": "jp@example.com"])),
            .success(jsonResult(["success": true, "data": [["id": "--verbose"]]]))
        ])
        let client = makeClient(executor: executor)

        do {
            _ = try await client.searchTeams(in: makeInterval(), limit: 20, messagesPerChat: 2)
            XCTFail("Expected unreadable Teams source failure")
        } catch {
            XCTAssertEqual(error as? AIPIMError, .commandFailed(.teams))
        }

        let commands = await executor.commands
        XCTAssertEqual(commands.count, 2)
    }

    func testTeamsSearchFailsWhenEveryListedChatReadFails() async throws {
        let executor = FakeAIPIMExecutor(results: [
            .success(jsonResult(["authenticated": true, "username": "jp@example.com"])),
            .success(jsonResult(["success": true, "data": [["id": "chat-1"], ["id": "chat-2"]]])),
            .failure(AIPIMExecutionError.launchFailed),
            .success(jsonResult(["success": true, "data": [["email": "jp@example.com", "userId": "user-1"]]])),
            .failure(AIPIMExecutionError.launchFailed)
        ])
        let client = makeClient(executor: executor)

        do {
            _ = try await client.searchTeams(in: makeInterval(), limit: 20, messagesPerChat: 2)
            XCTFail("Expected unreadable Teams source failure")
        } catch {
            XCTAssertEqual(error as? AIPIMError, .commandFailed(.teams))
        }
    }

    func testTeamsSearchPreservesPartialCoverageWhenAtLeastOneChatIsReadable() async throws {
        let executor = FakeAIPIMExecutor(results: [
            .success(jsonResult(["authenticated": true, "username": "jp@example.com"])),
            .success(jsonResult(["success": true, "data": [["id": "chat-1"], ["id": "chat-2"]]])),
            .failure(AIPIMExecutionError.launchFailed),
            .success(jsonResult(["success": true, "data": [["email": "jp@example.com", "userId": "user-1"]]])),
            .success(jsonResult(["success": true, "data": []]))
        ])
        let client = makeClient(executor: executor)

        let result = try await client.searchTeams(in: makeInterval(), limit: 20, messagesPerChat: 2)

        XCTAssertEqual(result.items, [])
        XCTAssertTrue(result.isPartial)
        XCTAssertTrue(result.partialReasons.contains("member_resolution_failed"))
        XCTAssertTrue(result.partialReasons.contains("channel_coverage_missing"))
    }

    func testTeamsSearchPropagatesCancellationDuringChatReads() async throws {
        let executor = FakeAIPIMExecutor(results: [
            .success(jsonResult(["authenticated": true, "username": "jp@example.com"])),
            .success(jsonResult(["success": true, "data": [["id": "chat-1"]]])),
            .failure(CancellationError())
        ])
        let client = makeClient(executor: executor)

        do {
            _ = try await client.searchTeams(in: makeInterval(), limit: 20, messagesPerChat: 2)
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testTeamsSearchLocallyCapsOverreturnedChats() async throws {
        let chats = (0..<51).map { ["id": "chat-\($0)"] }
        var results: [Result<AIPIMCommandResult, Error>] = [
            .success(jsonResult(["authenticated": true, "username": "jp@example.com"])),
            .success(jsonResult(["success": true, "data": chats])),
            .success(jsonResult(["success": true, "data": [["email": "jp@example.com", "userId": "user-1"]]])),
            .success(jsonResult(["success": true, "data": []]))
        ]
        results.append(contentsOf: (0..<49).map { _ in
            .success(jsonResult(["success": true, "data": []]))
        })
        let executor = FakeAIPIMExecutor(results: results)
        let client = makeClient(executor: executor)

        let result = try await client.searchTeams(in: makeInterval(), limit: 20, messagesPerChat: 2)

        let memberCommands = await executor.commands.filter { $0.arguments.prefix(2) == ["chat", "members"] }
        XCTAssertEqual(memberCommands.count, 50)
        XCTAssertTrue(result.partialReasons.contains("chat_limit_reached"))
    }

    func testTeamsSearchLocallyCapsOverreturnedMessages() async throws {
        let messages = (0..<3).map { index in
            [
                "id": "message-\(index)",
                "createdDateTime": "2026-07-01T1\(index):00:00Z",
                "from": ["user": ["id": "user-1"]],
                "body": ["contentType": "text", "content": "Message \(index)"]
            ] as [String: Any]
        }
        let executor = FakeAIPIMExecutor(results: [
            .success(jsonResult(["authenticated": true, "username": "jp@example.com"])),
            .success(jsonResult(["success": true, "data": [["id": "chat-1"]]])),
            .success(jsonResult(["success": true, "data": [["email": "jp@example.com", "userId": "user-1"]]])),
            .success(jsonResult(["success": true, "data": messages]))
        ])
        let client = makeClient(executor: executor)

        let result = try await client.searchTeams(in: makeInterval(), limit: 20, messagesPerChat: 2)

        XCTAssertEqual(result.items.map(\.id), ["message-0", "message-1"])
        XCTAssertTrue(result.partialReasons.contains("message_limit_reached"))
    }

    func testTeamsAdapterReportsSearchedPartialChatCoverage() async throws {
        let interval = try makeInterval()
        let item = AIPIMWorkActivityItem(
            id: "message-1",
            source: .teams,
            timestamp: interval.start.addingTimeInterval(60),
            title: "NoteAI",
            body: "Shipped native Teams source",
            url: nil,
            contextName: "NoteAI"
        )
        let adapter = TeamsWorkActivitySourceAdapter { _, _, _ in
            AIPIMSearchResult(source: .teams, items: [item], isPartial: true, partialReasons: ["channel_coverage_missing"])
        }
        let query = WorkActivityQuery(
            prompt: "what did i work on this week?",
            range: WorkActivityDateRange(start: interval.start, end: interval.end, label: "this week"),
            limit: 18
        )

        let result = await adapter.searchWorkActivity(query)

        XCTAssertEqual(result.status, .searched)
        XCTAssertEqual(result.records.compactMap(\.detail), ["Shipped native Teams source"])
        XCTAssertEqual(result.coverageNote, "Teams chat coverage is partial; Teams channels are not included.")
    }

    func testSlackAdapterMapsValidSearchItemsToSearchedRecords() async throws {
        let interval = try makeInterval()
        let item = AIPIMWorkActivityItem(
            id: "message-1",
            source: .slack,
            timestamp: interval.start.addingTimeInterval(60),
            title: "#noteai",
            body: "Shipped native Slack source",
            url: nil,
            contextName: "noteai"
        )
        let adapter = SlackWorkActivitySourceAdapter { _, _ in
            AIPIMSearchResult(source: .slack, items: [item], isPartial: false, partialReasons: [])
        }
        let query = WorkActivityQuery(
            prompt: "what did i work on this week?",
            range: WorkActivityDateRange(start: interval.start, end: interval.end, label: "this week"),
            limit: 18
        )

        let result = await adapter.searchWorkActivity(query)

        XCTAssertEqual(result.status, .searched)
        XCTAssertEqual(result.records.map(\.source), [.slack])
        XCTAssertEqual(result.records.compactMap(\.detail), ["Shipped native Slack source"])
        XCTAssertNil(result.coverageNote)
    }

    func testOutlookAdapterMapsValidSearchItemsToSearchedRecords() async throws {
        let interval = try makeInterval()
        let item = AIPIMWorkActivityItem(
            id: "message-1",
            source: .outlook,
            timestamp: interval.start.addingTimeInterval(60),
            title: "Nscale routing",
            body: "Completed Outlook follow-up",
            url: nil,
            contextName: "Alex <alex@example.com>"
        )
        let adapter = OutlookWorkActivitySourceAdapter { _, _ in
            AIPIMSearchResult(source: .outlook, items: [item], isPartial: false, partialReasons: [])
        }
        let query = WorkActivityQuery(
            prompt: "what did i work on this week?",
            range: WorkActivityDateRange(start: interval.start, end: interval.end, label: "this week"),
            limit: 18
        )

        let result = await adapter.searchWorkActivity(query)

        XCTAssertEqual(result.status, .searched)
        XCTAssertEqual(result.records.map(\.source), [.outlook])
        XCTAssertEqual(result.records.compactMap(\.detail), ["Completed Outlook follow-up"])
        XCTAssertNil(result.coverageNote)
    }

    @MainActor
    func testNormalWeeklyChatRequestInvokesOutlookSlackAndTeamsAndClaimsAllSearched() async throws {
        let outlookInvoked = expectation(description: "Outlook adapter invoked")
        let slackInvoked = expectation(description: "Slack adapter invoked")
        let teamsInvoked = expectation(description: "Teams adapter invoked")
        let now = Date()
        let dependencies = ChatWorkActivityDependencies(
            snapshot: { .empty },
            sourceStatus: { .localOnly },
            externalAdapters: { _ in
                [
                    OutlookWorkActivitySourceAdapter { _, _ in
                        outlookInvoked.fulfill()
                        return AIPIMSearchResult(
                            source: .outlook,
                            items: [AIPIMWorkActivityItem(
                                id: "outlook-1",
                                source: .outlook,
                                timestamp: now,
                                title: "Outlook update",
                                body: "Completed Outlook work",
                                url: nil,
                                contextName: nil
                            )],
                            isPartial: false,
                            partialReasons: []
                        )
                    },
                    SlackWorkActivitySourceAdapter { _, _ in
                        slackInvoked.fulfill()
                        return AIPIMSearchResult(
                            source: .slack,
                            items: [AIPIMWorkActivityItem(
                                id: "slack-1",
                                source: .slack,
                                timestamp: now,
                                title: "Slack update",
                                body: "Completed Slack work",
                                url: nil,
                                contextName: nil
                            )],
                            isPartial: false,
                            partialReasons: []
                        )
                    },
                    TeamsWorkActivitySourceAdapter { _, _, _ in
                        teamsInvoked.fulfill()
                        return AIPIMSearchResult(
                            source: .teams,
                            items: [AIPIMWorkActivityItem(
                                id: "teams-1",
                                source: .teams,
                                timestamp: now,
                                title: "Teams update",
                                body: "Completed Teams work",
                                url: nil,
                                contextName: nil
                            )],
                            isPartial: true,
                            partialReasons: ["channel_coverage_missing"]
                        )
                    }
                ]
            }
        )
        let chatManager = ChatManager(workActivityDependencies: dependencies)

        chatManager.send("what did I work on this week?")

        await fulfillment(of: [outlookInvoked, slackInvoked, teamsInvoked], timeout: 2)
        try await waitForChatCompletion(chatManager)
        let output = try XCTUnwrap(chatManager.messages.last?.content)
        XCTAssertTrue(output.contains("Sources searched: NoteAI local records, Outlook email, Slack, Teams."))
        XCTAssertTrue(output.contains("Outlook email: Outlook update"))
        XCTAssertTrue(output.contains("Slack message: Slack update"))
        XCTAssertTrue(output.contains("Teams chat: Teams update"))
    }

    @MainActor
    func testNormalWeeklyChatRequestReportsSlackSkippedAndTeamsErrorWithoutFalseSearchClaims() async throws {
        let slackInvoked = expectation(description: "Slack adapter invoked")
        let teamsInvoked = expectation(description: "Teams adapter invoked")
        let dependencies = ChatWorkActivityDependencies(
            snapshot: { .empty },
            sourceStatus: { .localOnly },
            externalAdapters: { _ in
                [
                    SlackWorkActivitySourceAdapter { _, _ in
                        slackInvoked.fulfill()
                        throw AIPIMError.authenticationRequired(.slack)
                    },
                    TeamsWorkActivitySourceAdapter { _, _, _ in
                        teamsInvoked.fulfill()
                        throw AIPIMError.invalidResponse(.teams)
                    }
                ]
            }
        )
        let chatManager = ChatManager(workActivityDependencies: dependencies)

        chatManager.send("what did I work on this week?")

        await fulfillment(of: [slackInvoked, teamsInvoked], timeout: 2)
        try await waitForChatCompletion(chatManager)
        let output = try XCTUnwrap(chatManager.messages.last?.content)
        XCTAssertTrue(output.contains("Sources searched: NoteAI local records."))
        XCTAssertTrue(output.contains("Sources skipped: Slack source search requires sign-in"))
        XCTAssertTrue(output.contains("Source errors: Teams source search failed"))
        XCTAssertFalse(output.contains("Sources searched: NoteAI local records, Slack"))
        XCTAssertFalse(output.contains("Sources searched: NoteAI local records, Teams"))
    }

    @MainActor
    func testClearChatPreventsCancelledWorkActivityResponseFromPublishingLater() async throws {
        let sourceStarted = expectation(description: "External source started")
        let dependencies = ChatWorkActivityDependencies(
            snapshot: { .empty },
            sourceStatus: { .localOnly },
            externalAdapters: { _ in
                [
                    SlackWorkActivitySourceAdapter { _, _ in
                        sourceStarted.fulfill()
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        return AIPIMSearchResult(
                            source: .slack,
                            items: [],
                            isPartial: false,
                            partialReasons: []
                        )
                    }
                ]
            }
        )
        let chatManager = ChatManager(workActivityDependencies: dependencies)

        chatManager.send("what did I work on this week?")
        await fulfillment(of: [sourceStarted], timeout: 2)
        chatManager.clearChat()
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(chatManager.messages.count, 1)
        XCTAssertEqual(chatManager.messages.first?.content, "Chat cleared. How can I help?")
        XCTAssertFalse(chatManager.isTyping)
    }

    @MainActor
    func testAccountSourceModelTransitionsConnectReconnectAndRefresh() async {
        let connector = FakeAIPIMSourceConnector(
            statusResults: [
                sourceStatus(.outlook, state: .authenticationRequired),
                sourceStatus(.outlook, state: .authenticationRequired)
            ],
            loginResults: [sourceStatus(.outlook, state: .available)]
        )
        let model = AIPIMAccountSourceModel(connector: connector)

        XCTAssertEqual(model.actionTitle(for: .outlook), "Connect")

        await model.refresh(.outlook)
        XCTAssertEqual(model.actionTitle(for: .outlook), "Connect")

        await model.connect(.outlook)
        XCTAssertEqual(model.actionTitle(for: .outlook), "Reconnect")

        await model.refresh(.outlook)
        XCTAssertEqual(model.actionTitle(for: .outlook), "Connect")
        let actions = await connector.actions
        XCTAssertEqual(actions, [.status(.outlook), .login(.outlook), .status(.outlook)])
    }

    @MainActor
    func testAccountSourceModelRefreshAllChecksOutlookSlackAndTeams() async {
        let connector = FakeAIPIMSourceConnector(
            statusResults: AIPIMSource.allCases.map { sourceStatus($0, state: .available) },
            loginResults: []
        )
        let model = AIPIMAccountSourceModel(connector: connector)

        await model.refreshAll()

        let actions = await connector.actions
        let refreshedSources = actions.compactMap { action -> AIPIMSource? in
            guard case .status(let source) = action else { return nil }
            return source
        }
        XCTAssertEqual(
            Set(refreshedSources.map(\.rawValue)),
            Set(AIPIMSource.allCases.map(\.rawValue))
        )
    }

    private func makeClient(executor: FakeAIPIMExecutor) -> AIPIMClient {
        AIPIMClient(
            locator: FakeAIPIMLocator(),
            executor: executor,
            calendar: utcCalendar()
        )
    }

    private func makeInterval() throws -> DateInterval {
        let formatter = ISO8601DateFormatter()
        let start = try XCTUnwrap(formatter.date(from: "2026-07-01T00:00:00Z"))
        let end = try XCTUnwrap(formatter.date(from: "2026-07-03T00:00:00Z"))
        return DateInterval(start: start, end: end)
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func jsonResult(_ object: Any) -> AIPIMCommandResult {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return AIPIMCommandResult(exitCode: 0, stdout: data)
    }

    @MainActor
    private func waitForChatCompletion(_ manager: ChatManager) async throws {
        for _ in 0..<100 where manager.isTyping {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(manager.isTyping)
    }

    private func sourceStatus(
        _ source: AIPIMSource,
        state: AIPIMConnectionState
    ) -> AIPIMSourceStatus {
        AIPIMSourceStatus(
            source: source,
            state: state,
            installed: true,
            authenticated: state == .available,
            message: state == .available ? "Authenticated." : "Sign-in required."
        )
    }

    private var sustainedConcurrentOutputCommand: String {
        "/usr/bin/yes x & a=$!; "
            + "/usr/bin/yes y >&2 & b=$!; "
            + "sleep 1; kill $a $b; wait"
    }

    private func waitForProcessID(in file: URL) async throws -> pid_t {
        for _ in 0..<100 {
            if let value = try? String(contentsOf: file, encoding: .utf8),
               let processID = pid_t(value.trimmingCharacters(in: .whitespacesAndNewlines)),
               processID > 0 {
                return processID
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw AIPIMTestError.processDidNotStart
    }

    private func waitForProcessGroupExit(_ processID: pid_t) async -> Bool {
        for _ in 0..<50 {
            if Darwin.kill(-processID, 0) != 0, errno != EPERM {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }
}

private enum AIPIMTestError: Error {
    case processDidNotStart
}

private struct FakeAIPIMLocator: AIPIMExecutableLocating {
    func executableURL(for source: AIPIMSource) -> URL? {
        URL(fileURLWithPath: "/test/bin/\(source.binaryName)")
    }
}

private actor FakeAIPIMExecutor: AIPIMCommandExecuting {
    private(set) var commands: [AIPIMCommand] = []
    private var results: [Result<AIPIMCommandResult, Error>]

    init(results: [Result<AIPIMCommandResult, Error>]) {
        self.results = results
    }

    func execute(_ command: AIPIMCommand) async throws -> AIPIMCommandResult {
        commands.append(command)
        guard !results.isEmpty else {
            XCTFail("Unexpected command: \(command.arguments)")
            throw AIPIMExecutionError.launchFailed
        }
        return try results.removeFirst().get()
    }
}

private actor FakeAIPIMSourceConnector: AIPIMSourceConnecting {
    enum Action: Equatable {
        case status(AIPIMSource)
        case login(AIPIMSource)
    }

    private(set) var actions: [Action] = []
    private var statusResults: [AIPIMSourceStatus]
    private var loginResults: [AIPIMSourceStatus]

    init(statusResults: [AIPIMSourceStatus], loginResults: [AIPIMSourceStatus]) {
        self.statusResults = statusResults
        self.loginResults = loginResults
    }

    func status(for source: AIPIMSource) async -> AIPIMSourceStatus {
        actions.append(.status(source))
        return statusResults.removeFirst()
    }

    func login(to source: AIPIMSource) async -> AIPIMSourceStatus {
        actions.append(.login(source))
        return loginResults.removeFirst()
    }
}
