import XCTest
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

    func testTeamsSearchRejectsOptionLikeChatIDsBeforeExecution() async throws {
        let executor = FakeAIPIMExecutor(results: [
            .success(jsonResult(["authenticated": true, "username": "jp@example.com"])),
            .success(jsonResult(["success": true, "data": [["id": "--verbose"]]]))
        ])
        let client = makeClient(executor: executor)

        let result = try await client.searchTeams(in: makeInterval(), limit: 20, messagesPerChat: 2)

        let commands = await executor.commands
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(result.items, [])
        XCTAssertTrue(result.partialReasons.contains("chat_read_failed"))
    }

    func testTeamsSearchLocallyCapsOverreturnedChats() async throws {
        let chats = (0..<51).map { ["id": "chat-\($0)"] }
        var results: [Result<AIPIMCommandResult, Error>] = [
            .success(jsonResult(["authenticated": true, "username": "jp@example.com"])),
            .success(jsonResult(["success": true, "data": chats]))
        ]
        results.append(contentsOf: (0..<50).map { _ in
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

    func testChatAndSettingsWireSlackAndTeamsSources() throws {
        let root = repositoryRoot()
        let chat = try String(contentsOf: root.appendingPathComponent("NoteAI/UI/Chat/ChatManager.swift"))
        let settings = try String(contentsOf: root.appendingPathComponent("NoteAI/UI/Settings/SettingsView.swift"))

        XCTAssertTrue(chat.contains("SlackWorkActivitySourceAdapter"))
        XCTAssertTrue(chat.contains("TeamsWorkActivitySourceAdapter"))
        XCTAssertTrue(settings.contains("Section(\"Work Activity Sources\")"))
        XCTAssertTrue(settings.contains("Connect"))
        XCTAssertTrue(settings.contains("Reconnect"))
        XCTAssertTrue(settings.contains("ai-pim-utils"))
        XCTAssertTrue(settings.contains("Teams channels are not included"))
        XCTAssertTrue(settings.contains("NoteAI never stores tokens"))
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

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
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
