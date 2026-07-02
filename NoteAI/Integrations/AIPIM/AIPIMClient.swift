import Foundation

struct AIPIMClient: AIPIMSourceConnecting, Sendable {
    private static let commandTimeout: TimeInterval = 30
    private static let authTimeout: TimeInterval = 120
    private static let teamsCommandTimeout: TimeInterval = 10
    private static let teamsSearchTimeout: TimeInterval = 60
    private static let outputLimitBytes = 1_048_576
    private static let slackResultLimit = 100
    private static let teamsChatLimit = 50
    private static let teamsMessageLimit = 200
    private static let normalizedResultLimit = 100
    private static let itemBodyLimit = 8_000

    private let locator: any AIPIMExecutableLocating
    private let executor: any AIPIMCommandExecuting
    private let calendar: Calendar

    init(
        locator: any AIPIMExecutableLocating = AIPIMExecutableDiscovery(),
        executor: any AIPIMCommandExecuting = AIPIMProcessRunner(),
        calendar: Calendar = .current
    ) {
        self.locator = locator
        self.executor = executor
        self.calendar = calendar
    }

    func status(for source: AIPIMSource) async -> AIPIMSourceStatus {
        guard let executableURL = locator.executableURL(for: source) else {
            return status(
                source,
                state: .unavailable,
                installed: false,
                authenticated: false,
                message: "\(source.displayName) CLI is not installed."
            )
        }

        do {
            let result = try await executor.execute(AIPIMCommand(
                executableURL: executableURL,
                arguments: statusArguments(for: source),
                timeout: Self.commandTimeout,
                maxOutputBytes: Self.outputLimitBytes
            ))
            if result.exitCode == 2 {
                return authenticationRequiredStatus(source)
            }
            guard result.exitCode == 0 else {
                return failedStatus(source, message: "\(source.displayName) status check failed.")
            }
            return parseStatus(source, data: result.stdout)
        } catch {
            return statusFromExecutionFailure(source, error: error)
        }
    }

    func login(to source: AIPIMSource) async -> AIPIMSourceStatus {
        guard let executableURL = locator.executableURL(for: source) else {
            return status(
                source,
                state: .unavailable,
                installed: false,
                authenticated: false,
                message: "\(source.displayName) CLI is not installed."
            )
        }

        do {
            let result = try await executor.execute(AIPIMCommand(
                executableURL: executableURL,
                arguments: ["auth", "login"],
                timeout: Self.authTimeout,
                maxOutputBytes: Self.outputLimitBytes
            ))
            guard result.exitCode == 0 else {
                return failedStatus(source, message: "\(source.displayName) authentication failed.")
            }

            let verification = await status(for: source)
            guard verification.state == .available, verification.authenticated else {
                return status(
                    source,
                    state: verification.state,
                    installed: verification.installed,
                    authenticated: false,
                    message: "\(source.displayName) authentication verification failed."
                )
            }
            return status(
                source,
                state: .available,
                installed: true,
                authenticated: true,
                message: "\(source.displayName) authentication completed."
            )
        } catch {
            return statusFromExecutionFailure(source, error: error)
        }
    }

    func searchSlack(in interval: DateInterval, limit: Int) async throws -> AIPIMSearchResult {
        guard (1...Self.slackResultLimit).contains(limit) else {
            throw AIPIMError.invalidLimit(.slack)
        }

        let identityData = try await run(
            .slack,
            arguments: ["me", "--output", "json"],
            timeout: Self.commandTimeout
        )
        let identity = try decode(SlackIdentityResponse.self, from: identityData, source: .slack)
        guard identity.success,
              let userID = identity.data?.user?.id?.trimmedNonempty else {
            throw AIPIMError.invalidResponse(.slack)
        }

        let bounds = slackDateBounds(for: interval)
        let searchData = try await run(
            .slack,
            arguments: [
                "message", "search",
                "--query", "from:me after:\(bounds.after) before:\(bounds.before)",
                "--limit", String(limit),
                "--page", "1",
                "--output", "json"
            ],
            timeout: Self.commandTimeout
        )
        let response = try decode(SlackSearchResponse.self, from: searchData, source: .slack)
        guard response.success, let messages = response.data?.messages else {
            throw AIPIMError.invalidResponse(.slack)
        }

        let normalized = messages.matches.compactMap {
            normalizeSlackMatch($0, authenticatedUserID: userID, interval: interval)
        }
        let items = Array(normalized.prefix(limit))
        let isPartial = normalized.count > limit
            || (messages.total.map { $0 > messages.matches.count } ?? false)
            || (messages.pagination?.pageCount.map { $0 > 1 } ?? false)

        return AIPIMSearchResult(
            source: .slack,
            items: items,
            isPartial: isPartial,
            partialReasons: isPartial ? ["result_limit_reached"] : []
        )
    }

    func searchTeams(
        in interval: DateInterval,
        limit: Int,
        messagesPerChat: Int
    ) async throws -> AIPIMSearchResult {
        guard (1...Self.normalizedResultLimit).contains(limit),
              (1...Self.teamsMessageLimit).contains(messagesPerChat) else {
            throw AIPIMError.invalidLimit(.teams)
        }

        let deadline = Date().addingTimeInterval(Self.teamsSearchTimeout)
        let authData = try await run(
            .teams,
            arguments: ["auth", "status", "--json"],
            timeout: Self.teamsCommandTimeout
        )
        let auth = try decode(TeamsAuthResponse.self, from: authData, source: .teams)
        guard auth.authenticated else {
            throw AIPIMError.authenticationRequired(.teams)
        }
        guard let username = auth.username?.trimmedNonempty else {
            throw AIPIMError.invalidResponse(.teams)
        }

        let chatListData = try await run(
            .teams,
            arguments: [
                "chat", "list",
                "--limit", String(Self.teamsChatLimit),
                "--fields", "id,chatType,topic",
                "--json"
            ],
            timeout: teamsTimeout(deadline: deadline)
        )
        let chatList = try decode(TeamsChatListResponse.self, from: chatListData, source: .teams)
        guard chatList.success else {
            throw AIPIMError.invalidResponse(.teams)
        }

        var partialReasons = ["channel_coverage_missing"]
        if chatList.data.count >= Self.teamsChatLimit {
            partialReasons.append("chat_limit_reached")
        }
        var items: [AIPIMWorkActivityItem] = []
        var readableChatCount = 0

        for chat in chatList.data.prefix(Self.teamsChatLimit) {
            if items.count >= limit {
                partialReasons.append("result_limit_reached")
                break
            }
            guard Date() < deadline else {
                partialReasons.append("time_limit_reached")
                break
            }
            guard let chatID = safeCLIIdentifier(chat.id) else {
                partialReasons.append("chat_read_failed")
                continue
            }

            let memberData: Data
            do {
                memberData = try await run(
                    .teams,
                    arguments: [
                        "chat", "members", chatID,
                        "--fields", "email,userId",
                        "--json"
                    ],
                    timeout: teamsTimeout(deadline: deadline)
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch AIPIMError.authenticationRequired {
                throw AIPIMError.authenticationRequired(.teams)
            } catch {
                partialReasons.append("member_resolution_failed")
                continue
            }

            guard let members = try? decode(TeamsMemberListResponse.self, from: memberData, source: .teams),
                  members.success,
                  let authorUserID = teamsUserID(in: members.data, username: username) else {
                partialReasons.append("member_resolution_failed")
                continue
            }
            guard Date() < deadline else {
                partialReasons.append("time_limit_reached")
                break
            }

            let messageData: Data
            do {
                messageData = try await run(
                    .teams,
                    arguments: [
                        "chat", "read", chatID,
                        "--limit", String(messagesPerChat),
                        "--fields", "id,createdDateTime,from,body,subject,webUrl",
                        "--json"
                    ],
                    timeout: teamsTimeout(deadline: deadline)
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch AIPIMError.authenticationRequired {
                throw AIPIMError.authenticationRequired(.teams)
            } catch {
                partialReasons.append("chat_read_failed")
                continue
            }

            guard let messages = try? decode(TeamsMessageListResponse.self, from: messageData, source: .teams),
                  messages.success else {
                partialReasons.append("chat_read_failed")
                continue
            }
            readableChatCount += 1
            if messages.data.count >= messagesPerChat,
               messagesCanOmitRange(messages.data, interval: interval) {
                partialReasons.append("message_limit_reached")
            }

            for message in messages.data.prefix(messagesPerChat) {
                guard let item = normalizeTeamsMessage(
                    message,
                    chat: chat,
                    authorUserID: authorUserID,
                    interval: interval
                ) else { continue }
                if items.count >= limit {
                    partialReasons.append("result_limit_reached")
                    break
                }
                items.append(item)
            }
        }

        if !chatList.data.isEmpty, readableChatCount == 0 {
            throw AIPIMError.commandFailed(.teams)
        }

        let reasons = partialReasons.uniqued()
        return AIPIMSearchResult(
            source: .teams,
            items: items,
            isPartial: true,
            partialReasons: reasons
        )
    }

    private func run(
        _ source: AIPIMSource,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> Data {
        guard let executableURL = locator.executableURL(for: source) else {
            throw AIPIMError.unavailable(source)
        }

        let result: AIPIMCommandResult
        do {
            result = try await executor.execute(AIPIMCommand(
                executableURL: executableURL,
                arguments: arguments,
                timeout: min(max(0.01, timeout), Self.commandTimeout),
                maxOutputBytes: Self.outputLimitBytes
            ))
        } catch is CancellationError {
            throw CancellationError()
        } catch AIPIMExecutionError.timedOut {
            throw AIPIMError.timedOut(source)
        } catch AIPIMExecutionError.outputLimitExceeded {
            throw AIPIMError.outputLimitExceeded(source)
        } catch {
            throw AIPIMError.commandFailed(source)
        }

        if result.exitCode == 2 {
            throw AIPIMError.authenticationRequired(source)
        }
        guard result.exitCode == 0 else {
            throw AIPIMError.commandFailed(source)
        }
        return result.stdout
    }

    private func parseStatus(_ source: AIPIMSource, data: Data) -> AIPIMSourceStatus {
        switch source {
        case .slack:
            guard let response = try? JSONDecoder().decode(SlackIdentityResponse.self, from: data),
                  response.success,
                  response.data?.user?.id?.trimmedNonempty != nil else {
                return failedStatus(source, message: "Slack status returned an invalid response.")
            }
        case .teams:
            guard let response = try? JSONDecoder().decode(TeamsAuthResponse.self, from: data) else {
                return failedStatus(source, message: "Teams status returned an invalid response.")
            }
            guard response.authenticated else {
                return authenticationRequiredStatus(source)
            }
            guard response.username?.trimmedNonempty != nil else {
                return failedStatus(source, message: "Teams status returned an invalid identity response.")
            }
        }

        return status(
            source,
            state: .available,
            installed: true,
            authenticated: true,
            message: "\(source.displayName) is authenticated."
        )
    }

    private func statusArguments(for source: AIPIMSource) -> [String] {
        switch source {
        case .slack: return ["me", "--output", "json"]
        case .teams: return ["auth", "status", "--json"]
        }
    }

    private func statusFromExecutionFailure(_ source: AIPIMSource, error: Error) -> AIPIMSourceStatus {
        let message: String
        if error as? AIPIMExecutionError == .timedOut {
            message = "\(source.displayName) status check timed out."
        } else if error as? AIPIMExecutionError == .outputLimitExceeded {
            message = "\(source.displayName) status output exceeded the safe limit."
        } else {
            message = "\(source.displayName) status check failed."
        }
        return failedStatus(source, message: message)
    }

    private func authenticationRequiredStatus(_ source: AIPIMSource) -> AIPIMSourceStatus {
        status(
            source,
            state: .authenticationRequired,
            installed: true,
            authenticated: false,
            message: "\(source.displayName) authentication is required."
        )
    }

    private func failedStatus(_ source: AIPIMSource, message: String) -> AIPIMSourceStatus {
        status(source, state: .failed, installed: true, authenticated: false, message: message)
    }

    private func status(
        _ source: AIPIMSource,
        state: AIPIMConnectionState,
        installed: Bool,
        authenticated: Bool,
        message: String
    ) -> AIPIMSourceStatus {
        AIPIMSourceStatus(
            source: source,
            state: state,
            installed: installed,
            authenticated: authenticated,
            message: message
        )
    }

    private func decode<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        source: AIPIMSource
    ) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw AIPIMError.invalidResponse(source)
        }
    }

    private func slackDateBounds(for interval: DateInterval) -> (after: String, before: String) {
        let start = calendar.startOfDay(for: interval.start)
        let endDay = calendar.startOfDay(for: interval.end)
        let exclusiveEnd = interval.end == endDay
            ? endDay
            : (calendar.date(byAdding: .day, value: 1, to: endDay) ?? interval.end)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return (formatter.string(from: start), formatter.string(from: exclusiveEnd))
    }

    private func normalizeSlackMatch(
        _ match: SlackMatch,
        authenticatedUserID: String,
        interval: DateInterval
    ) -> AIPIMWorkActivityItem? {
        guard match.user == authenticatedUserID,
              let timestampText = match.timestamp?.trimmedNonempty,
              let seconds = TimeInterval(timestampText),
              seconds.isFinite else { return nil }
        let timestamp = Date(timeIntervalSince1970: seconds)
        guard timestamp >= interval.start, timestamp < interval.end,
              let id = (match.timestamp ?? match.id)?.trimmedNonempty,
              let body = match.text?.trimmedNonempty else { return nil }

        let channelName = match.channel?.name?.trimmedNonempty
        let username = match.username?.trimmedNonempty
        guard channelName != nil || username != nil else { return nil }
        let title = channelName.map { "#\($0)" } ?? username ?? "Slack message"

        return AIPIMWorkActivityItem(
            id: id,
            source: .slack,
            timestamp: timestamp,
            title: title,
            body: body.clipped(to: Self.itemBodyLimit),
            url: match.permalink.flatMap(URL.init(string:)),
            contextName: channelName
        )
    }

    private func teamsUserID(in members: [TeamsMember], username: String) -> String? {
        let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return members.first {
            $0.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedUsername
                && $0.userID?.trimmedNonempty != nil
        }?.userID?.trimmedNonempty
    }

    private func safeCLIIdentifier(_ value: String?) -> String? {
        guard let identifier = value?.trimmedNonempty,
              identifier.count <= 2_048,
              !identifier.hasPrefix("-"),
              identifier.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return identifier
    }

    private func normalizeTeamsMessage(
        _ message: TeamsMessage,
        chat: TeamsChat,
        authorUserID: String,
        interval: DateInterval
    ) -> AIPIMWorkActivityItem? {
        guard let id = message.id?.trimmedNonempty,
              let timestampText = message.createdDateTime,
              let timestamp = parseISO8601(timestampText),
              timestamp >= interval.start,
              timestamp < interval.end,
              message.sender?.user?.id == authorUserID else { return nil }

        let content = message.body?.content ?? ""
        let body = message.body?.contentType?.lowercased() == "html"
            ? AIPIMHTMLTextNormalizer.normalize(content)
            : content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalizedBody = body.trimmedNonempty else { return nil }

        let title = message.subject?.trimmedNonempty
            ?? chat.topic?.trimmedNonempty
            ?? message.sender?.user?.displayName?.trimmedNonempty
            ?? "Teams message"

        return AIPIMWorkActivityItem(
            id: id,
            source: .teams,
            timestamp: timestamp,
            title: title,
            body: normalizedBody.clipped(to: Self.itemBodyLimit),
            url: message.webURL.flatMap(URL.init(string:)),
            contextName: chat.topic?.trimmedNonempty
        )
    }

    private func messagesCanOmitRange(_ messages: [TeamsMessage], interval: DateInterval) -> Bool {
        let timestamps = messages.compactMap { $0.createdDateTime.flatMap(parseISO8601) }
        guard timestamps.count == messages.count, let oldest = timestamps.min() else {
            return true
        }
        return oldest >= interval.start
    }

    private func parseISO8601(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private func teamsTimeout(deadline: Date) -> TimeInterval {
        min(Self.teamsCommandTimeout, max(0.01, deadline.timeIntervalSinceNow))
    }
}

private struct SlackIdentityResponse: Decodable {
    let success: Bool
    let data: SlackIdentityData?
}

private struct SlackIdentityData: Decodable {
    let user: SlackUser?
}

private struct SlackUser: Decodable {
    let id: String?
}

private struct SlackSearchResponse: Decodable {
    let success: Bool
    let data: SlackSearchData?
}

private struct SlackSearchData: Decodable {
    let messages: SlackMessages?
}

private struct SlackMessages: Decodable {
    let total: Int?
    let matches: [SlackMatch]
    let pagination: SlackPagination?
}

private struct SlackPagination: Decodable {
    let pageCount: Int?

    enum CodingKeys: String, CodingKey {
        case pageCount = "page_count"
    }
}

private struct SlackMatch: Decodable {
    let timestamp: String?
    let id: String?
    let user: String?
    let username: String?
    let text: String?
    let permalink: String?
    let channel: SlackChannel?

    enum CodingKeys: String, CodingKey {
        case timestamp = "ts"
        case id, user, username, text, permalink, channel
    }
}

private struct SlackChannel: Decodable {
    let id: String?
    let name: String?
}

private struct TeamsAuthResponse: Decodable {
    let authenticated: Bool
    let username: String?
}

private struct TeamsChat: Decodable {
    let id: String?
    let chatType: String?
    let topic: String?
}

private struct TeamsMember: Decodable {
    let email: String?
    let userID: String?

    enum CodingKeys: String, CodingKey {
        case email
        case userID = "userId"
    }
}

private struct TeamsMessage: Decodable {
    let id: String?
    let createdDateTime: String?
    let sender: TeamsSender?
    let body: TeamsMessageBody?
    let subject: String?
    let webURL: String?

    enum CodingKeys: String, CodingKey {
        case id, createdDateTime, body, subject
        case sender = "from"
        case webURL = "webUrl"
    }
}

private struct TeamsSender: Decodable {
    let user: TeamsSenderUser?
}

private struct TeamsSenderUser: Decodable {
    let id: String?
    let displayName: String?
}

private struct TeamsMessageBody: Decodable {
    let contentType: String?
    let content: String?
}

private struct TeamsChatListResponse: Decodable {
    let success: Bool
    let data: [TeamsChat]

    private struct Wrapped: Decodable { let chats: [TeamsChat] }
    private enum CodingKeys: String, CodingKey { case success, data }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        success = try container.decode(Bool.self, forKey: .success)
        if let values = try? container.decode([TeamsChat].self, forKey: .data) {
            data = values
        } else {
            data = try container.decode(Wrapped.self, forKey: .data).chats
        }
    }
}

private struct TeamsMemberListResponse: Decodable {
    let success: Bool
    let data: [TeamsMember]

    private struct Wrapped: Decodable { let members: [TeamsMember] }
    private enum CodingKeys: String, CodingKey { case success, data }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        success = try container.decode(Bool.self, forKey: .success)
        if let values = try? container.decode([TeamsMember].self, forKey: .data) {
            data = values
        } else {
            data = try container.decode(Wrapped.self, forKey: .data).members
        }
    }
}

private struct TeamsMessageListResponse: Decodable {
    let success: Bool
    let data: [TeamsMessage]

    private struct Wrapped: Decodable { let messages: [TeamsMessage] }
    private enum CodingKeys: String, CodingKey { case success, data }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        success = try container.decode(Bool.self, forKey: .success)
        if let values = try? container.decode([TeamsMessage].self, forKey: .data) {
            data = values
        } else {
            data = try container.decode(Wrapped.self, forKey: .data).messages
        }
    }
}

private enum AIPIMHTMLTextNormalizer {
    static func normalize(_ html: String) -> String {
        var value = html.replacingOccurrences(
            of: #"(?is)<(script|style)\b[^>]*>.*?</\1\s*>"#,
            with: "",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"(?is)<br\s*/?>|</?(p|div|li|blockquote|table|tr|td|th)\b[^>]*>"#,
            with: "\n",
            options: .regularExpression
        )
        value = value.replacingOccurrences(of: #"(?is)<[^>]+>"#, with: "", options: .regularExpression)
        value = decodeEntities(value)

        return value
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .split(whereSeparator: \.isNewline)
            .map { line in
                line.replacingOccurrences(of: #"[ \t\r\f\v]+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func decodeEntities(_ value: String) -> String {
        [
            "&nbsp;": " ",
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&quot;": "\"",
            "&#39;": "'",
            "&apos;": "'"
        ].reduce(value) { result, pair in
            result.replacingOccurrences(of: pair.key, with: pair.value)
        }
    }
}

private extension String {
    var trimmedNonempty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    func clipped(to limit: Int) -> String {
        guard count > limit else { return self }
        return String(prefix(limit))
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
