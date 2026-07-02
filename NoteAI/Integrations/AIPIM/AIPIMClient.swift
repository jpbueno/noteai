import Foundation

struct AIPIMClient: AIPIMSourceConnecting, Sendable {
    private static let commandTimeout: TimeInterval = 30
    private static let authTimeout: TimeInterval = 120
    private static let teamsCommandTimeout: TimeInterval = 10
    private static let teamsSearchTimeout: TimeInterval = 60
    private static let outputLimitBytes = 1_048_576
    private static let outlookResultLimit = 25
    private static let outlookDefaultLookbackDays = 30
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
                maxOutputBytes: Self.outputLimitBytes,
                environment: .noninteractive
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
                arguments: loginArguments(for: source),
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

    func searchOutlook(in interval: DateInterval, limit: Int) async throws -> AIPIMSearchResult {
        guard (1...Self.outlookResultLimit).contains(limit), interval.start < interval.end else {
            throw AIPIMError.invalidLimit(.outlook)
        }

        let response = try await findOutlookMessages(in: interval, folder: .sent, limit: limit)
        let normalized = try normalizeAndSortOutlookMessages(response.messages, interval: interval)
        let items = normalized.prefix(limit).compactMap { message -> AIPIMWorkActivityItem? in
            guard let timestamp = message.sentDate else { return nil }
            return AIPIMWorkActivityItem(
                id: message.id,
                source: .outlook,
                timestamp: timestamp,
                title: message.subject.trimmedNonempty ?? "Outlook conversation",
                body: message.bodyPreview,
                url: message.webLink.flatMap(URL.init(string:)),
                contextName: message.sender.trimmedNonempty
            )
        }
        let isPartial = normalized.count > limit || response.hasMore

        return AIPIMSearchResult(
            source: .outlook,
            items: Array(items),
            isPartial: isPartial,
            partialReasons: isPartial ? ["result_limit_reached"] : []
        )
    }

    func searchOutlookTaskCandidates(
        _ search: OutlookMailSearchRequest
    ) async throws -> [OutlookTaskCandidate] {
        let interval = try outlookTaskInterval(for: search)
        let response = try await findOutlookMessages(
            in: interval,
            folder: .inbox,
            limit: Self.outlookResultLimit
        )
        let messages = try normalizeAndSortOutlookMessages(response.messages, interval: interval)
        let queryTerms = search.query
            .split(whereSeparator: \.isWhitespace)
            .map { String($0).lowercased() }
        let senderFilter = search.sender?.trimmedNonempty?.lowercased()

        return messages
            .filter { message in
                if let senderFilter,
                   !message.sender.lowercased().contains(senderFilter) {
                    return false
                }
                guard !queryTerms.isEmpty else { return true }
                let searchableText = [message.subject, message.sender, message.bodyPreview]
                    .joined(separator: "\n")
                    .lowercased()
                return queryTerms.allSatisfy(searchableText.contains)
            }
            .prefix(search.limit)
            .map(OutlookTaskCandidate.from)
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
                maxOutputBytes: Self.outputLimitBytes,
                environment: .noninteractive
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
        case .outlook:
            guard let response = try? JSONDecoder().decode(OutlookAuthResponse.self, from: data),
                  response.success else {
                return failedStatus(source, message: "Outlook status returned an invalid response.")
            }
            guard response.authenticated else {
                return authenticationRequiredStatus(source)
            }
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
        case .outlook: return ["auth", "status", "--json"]
        case .slack: return ["me", "--output", "json"]
        case .teams: return ["auth", "status", "--json"]
        }
    }

    private func loginArguments(for source: AIPIMSource) -> [String] {
        switch source {
        case .outlook: return ["auth", "login", "--browser"]
        case .slack, .teams: return ["auth", "login"]
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

    private enum OutlookFolder: String {
        case sent
        case inbox
    }

    private func findOutlookMessages(
        in interval: DateInterval,
        folder: OutlookFolder,
        limit: Int
    ) async throws -> OutlookMessageFindResult {
        guard (1...Self.outlookResultLimit).contains(limit), interval.start < interval.end else {
            throw AIPIMError.invalidLimit(.outlook)
        }

        let bounds = outlookDateBounds(for: interval)
        let data = try await run(
            .outlook,
            arguments: [
                "message", "find",
                "--folder", folder.rawValue,
                "--after", bounds.after,
                "--before", bounds.before,
                "--limit", String(limit),
                "--fields", "id,conversationId,subject,from,receivedDateTime,bodyPreview,webLink",
                "--json"
            ],
            timeout: Self.commandTimeout
        )
        let response = try decode(OutlookMessageFindResponse.self, from: data, source: .outlook)
        guard response.success else {
            throw AIPIMError.invalidResponse(.outlook)
        }
        let total = response.metadata?.total ?? response.metadata?.count
        return OutlookMessageFindResult(
            messages: response.data,
            hasMore: response.data.count >= limit
                || response.metadata?.pagination?.hasMore == true
                || total.map { $0 > response.data.count } == true
        )
    }

    private func outlookTaskInterval(for search: OutlookMailSearchRequest) throws -> DateInterval {
        let now = Date()
        let exclusiveEnd = search.before ?? now

        let start = search.after
            ?? calendar.date(
                byAdding: .day,
                value: -Self.outlookDefaultLookbackDays,
                to: exclusiveEnd
            )
            ?? exclusiveEnd.addingTimeInterval(-2_592_000)
        guard start < exclusiveEnd else {
            throw AIPIMError.invalidResponse(.outlook)
        }
        return DateInterval(start: start, end: exclusiveEnd)
    }

    private func outlookDateBounds(for interval: DateInterval) -> (after: String, before: String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return (formatter.string(from: interval.start), formatter.string(from: interval.end))
    }

    private func normalizeAndSortOutlookMessages(
        _ messages: [OutlookCLIMessage],
        interval: DateInterval
    ) throws -> [OutlookMessageSummary] {
        try messages
            .compactMap { try normalizeOutlookMessage($0, interval: interval) }
            .sorted {
                ($0.sentDate ?? .distantPast) > ($1.sentDate ?? .distantPast)
            }
    }

    private func normalizeOutlookMessage(
        _ message: OutlookCLIMessage,
        interval: DateInterval
    ) throws -> OutlookMessageSummary? {
        guard let id = message.id.trimmedNonempty,
              let timestamp = parseISO8601(message.receivedDateTime) else {
            throw AIPIMError.invalidResponse(.outlook)
        }
        guard timestamp >= interval.start, timestamp < interval.end else { return nil }

        return OutlookMessageSummary(
            id: id,
            conversationID: message.conversationID?.trimmedNonempty,
            subject: message.subject?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            sender: message.sender?.displayValue ?? "",
            sentDate: timestamp,
            bodyPreview: (message.bodyPreview ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .clipped(to: Self.itemBodyLimit),
            webLink: message.webLink?.trimmedNonempty
        )
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

private struct OutlookMessageFindResult {
    let messages: [OutlookCLIMessage]
    let hasMore: Bool
}

private struct OutlookAuthResponse: Decodable {
    let success: Bool
    let authenticated: Bool
    let username: String?

    private struct Payload: Decodable {
        let authenticated: Bool
        let username: String?

        private enum CodingKeys: String, CodingKey {
            case authenticated, username
            case userName
            case email
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            authenticated = try container.decode(Bool.self, forKey: .authenticated)
            username = try container.decodeIfPresent(String.self, forKey: .username)
                ?? container.decodeIfPresent(String.self, forKey: .userName)
                ?? container.decodeIfPresent(String.self, forKey: .email)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case success, data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        success = try container.decodeIfPresent(Bool.self, forKey: .success) ?? true
        let payload = try container.decodeIfPresent(Payload.self, forKey: .data)
            ?? Payload(from: decoder)
        authenticated = payload.authenticated
        username = payload.username
    }
}

private struct OutlookMessageFindResponse: Decodable {
    let success: Bool
    let data: [OutlookCLIMessage]
    let metadata: OutlookMessageMetadata?

    private enum CodingKeys: String, CodingKey {
        case success, data, metadata
    }

    private enum DataCodingKeys: String, CodingKey {
        case messages, items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        success = try container.decode(Bool.self, forKey: .success)
        metadata = try? container.decode(OutlookMessageMetadata.self, forKey: .metadata)
        if try container.decodeNil(forKey: .data) {
            data = []
        } else if let messages = try? container.decode([OutlookCLIMessage].self, forKey: .data) {
            data = messages
        } else {
            let wrapped = try container.nestedContainer(keyedBy: DataCodingKeys.self, forKey: .data)
            if wrapped.contains(.messages) {
                data = try wrapped.decodeIfPresent([OutlookCLIMessage].self, forKey: .messages) ?? []
            } else if wrapped.contains(.items) {
                data = try wrapped.decodeIfPresent([OutlookCLIMessage].self, forKey: .items) ?? []
            } else {
                throw DecodingError.dataCorruptedError(
                    forKey: .data,
                    in: container,
                    debugDescription: "Outlook message data is missing."
                )
            }
        }
    }
}

private struct OutlookMessageMetadata: Decodable {
    let count: Int?
    let total: Int?
    let pagination: OutlookMessagePagination?

    private enum CodingKeys: String, CodingKey {
        case count, total, pagination
        case totalCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        count = try? container.decode(Int.self, forKey: .count)
        total = (try? container.decode(Int.self, forKey: .total))
            ?? (try? container.decode(Int.self, forKey: .totalCount))
        pagination = try? container.decode(OutlookMessagePagination.self, forKey: .pagination)
    }
}

private struct OutlookMessagePagination: Decodable {
    let hasMore: Bool

    private enum CodingKeys: String, CodingKey {
        case hasMore
        case hasMoreSnake = "has_more"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hasMore = try container.decodeIfPresent(Bool.self, forKey: .hasMoreSnake)
            ?? container.decodeIfPresent(Bool.self, forKey: .hasMore)
            ?? false
    }
}

private struct OutlookCLIMessage: Decodable {
    let id: String
    let conversationID: String?
    let subject: String?
    let sender: OutlookCLISender?
    let receivedDateTime: String
    let bodyPreview: String?
    let webLink: String?

    private enum CodingKeys: String, CodingKey {
        case id, subject, from, receivedDateTime, bodyPreview, webLink
        case conversationID = "conversationId"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        conversationID = try container.decodeIfPresent(String.self, forKey: .conversationID)
        subject = try container.decodeIfPresent(String.self, forKey: .subject)
        sender = try container.decodeIfPresent(OutlookCLISender.self, forKey: .from)
        receivedDateTime = try container.decode(String.self, forKey: .receivedDateTime)
        bodyPreview = try container.decodeIfPresent(String.self, forKey: .bodyPreview)
        webLink = try container.decodeIfPresent(String.self, forKey: .webLink)
    }
}

private struct OutlookCLISender: Decodable {
    let name: String?
    let address: String?

    var displayValue: String {
        let normalizedName = name?.trimmedNonempty
        let normalizedAddress = address?.trimmedNonempty
        if let normalizedName, let normalizedAddress {
            return "\(normalizedName) <\(normalizedAddress)>"
        }
        return normalizedName ?? normalizedAddress ?? ""
    }

    private struct EmailAddress: Decodable {
        let name: String?
        let address: String?
    }

    private enum CodingKeys: String, CodingKey {
        case emailAddress, name, address
    }

    init(from decoder: Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(String.self) {
            name = nil
            address = value
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let emailAddress = try container.decodeIfPresent(EmailAddress.self, forKey: .emailAddress) {
            name = emailAddress.name
            address = emailAddress.address
        } else {
            name = try container.decodeIfPresent(String.self, forKey: .name)
            address = try container.decodeIfPresent(String.self, forKey: .address)
        }
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
