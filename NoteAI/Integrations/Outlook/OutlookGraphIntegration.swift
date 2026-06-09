import AppKit
import CommonCrypto
import Foundation

enum OutlookGraphSettings {
    static let clientIDKey = "noteai.outlook.clientID"
    static let tenantIDKey = "noteai.outlook.tenantID"

    static var clientID: String {
        UserDefaults.standard.string(forKey: clientIDKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static var tenantID: String {
        let value = UserDefaults.standard.string(forKey: tenantIDKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "common" : value
    }

    static var hasClientConfiguration: Bool {
        !clientID.isEmpty
    }
}

enum OutlookGraphTokenStore {
    private static let accessTokenKey = "outlook_graph_access_token"
    private static let refreshTokenKey = "outlook_graph_refresh_token"
    private static let accessTokenExpiryKey = "noteai.outlook.accessTokenExpiry"
    private static let userNameKey = "noteai.outlook.userName"
    private static let userEmailKey = "noteai.outlook.userEmail"

    static var accessToken: String? {
        KeychainHelper.load(key: accessTokenKey)
    }

    static var refreshToken: String? {
        KeychainHelper.load(key: refreshTokenKey)
    }

    static var accessTokenExpiry: Date? {
        let timestamp = UserDefaults.standard.double(forKey: accessTokenExpiryKey)
        return timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
    }

    static var userName: String {
        UserDefaults.standard.string(forKey: userNameKey) ?? ""
    }

    static var userEmail: String {
        UserDefaults.standard.string(forKey: userEmailKey) ?? ""
    }

    static var isSignedIn: Bool {
        accessToken != nil || refreshToken != nil
    }

    static func save(accessToken: String, refreshToken: String?, expiresIn: TimeInterval) {
        KeychainHelper.save(key: accessTokenKey, value: accessToken)
        if let refreshToken, !refreshToken.isEmpty {
            KeychainHelper.save(key: refreshTokenKey, value: refreshToken)
        }
        UserDefaults.standard.set(Date().addingTimeInterval(max(60, expiresIn - 120)).timeIntervalSince1970, forKey: accessTokenExpiryKey)
    }

    static func saveProfile(name: String, email: String) {
        UserDefaults.standard.set(name, forKey: userNameKey)
        UserDefaults.standard.set(email, forKey: userEmailKey)
    }

    static func clear() {
        KeychainHelper.delete(key: accessTokenKey)
        KeychainHelper.delete(key: refreshTokenKey)
        UserDefaults.standard.removeObject(forKey: accessTokenExpiryKey)
        UserDefaults.standard.removeObject(forKey: userNameKey)
        UserDefaults.standard.removeObject(forKey: userEmailKey)
    }
}

struct OutlookGraphError: LocalizedError, Equatable {
    let message: String

    var errorDescription: String? {
        message
    }
}

struct OutlookMessageSummary: Equatable, Identifiable {
    let id: String
    let conversationID: String?
    let subject: String
    let sender: String
    let sentDate: Date?
    let bodyPreview: String
    let webLink: String?
}

struct OutlookTaskCandidate: Equatable, Identifiable {
    let id: String
    let title: String
    let description: String
    let workDate: Date?
    let sourceMetadata: TaskItem.SourceMetadata

    static func from(message: OutlookMessageSummary) -> OutlookTaskCandidate {
        let title = cleanSubject(message.subject)
        let description = message.bodyPreview
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return OutlookTaskCandidate(
            id: message.id,
            title: title.isEmpty ? "Follow up on Outlook conversation" : title,
            description: description,
            workDate: message.sentDate,
            sourceMetadata: TaskItem.SourceMetadata(
                kind: .email,
                provider: "outlook",
                threadID: message.conversationID,
                messageID: message.id,
                subject: message.subject,
                sender: message.sender,
                sentDate: message.sentDate,
                url: message.webLink
            )
        )
    }

    private static func cleanSubject(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"(?i)^\s*(re|fw|fwd):\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct OutlookMailSearchRequest: Equatable {
    var query: String
    var after: Date?
    var before: Date?
    var sender: String?
    var limit: Int

    init(query: String, after: Date? = nil, before: Date? = nil, sender: String? = nil, limit: Int = 10) {
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.after = after
        self.before = before
        self.sender = sender?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.limit = min(max(limit, 1), 25)
    }
}

@MainActor
final class OutlookGraphAuthManager: ObservableObject {
    @Published var isAuthenticated = OutlookGraphTokenStore.isSignedIn
    @Published var isLoading = false
    @Published var error: String?

    private let scopes = "openid profile email offline_access Mail.Read"
    private var localServer: LocalOAuthServer?
    private var codeVerifier = ""
    private var oauthState = ""

    func signIn() {
        guard OutlookGraphSettings.hasClientConfiguration else {
            error = "Add a Microsoft Entra application client ID before signing in."
            return
        }

        isLoading = true
        error = nil
        codeVerifier = Self.generateCodeVerifier()
        oauthState = Self.generateCodeVerifier()
        let codeChallenge = Self.generateCodeChallenge(from: codeVerifier)

        let server = LocalOAuthServer()
        localServer = server
        let expectedState = oauthState
        let redirectURI = "http://localhost:\(server.port)"

        server.start(expectedState: expectedState) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.localServer?.stop()
                self.localServer = nil

                switch result {
                case .success(let code):
                    await self.exchangeCodeForTokens(code: code, redirectURI: redirectURI)
                case .failure(let error):
                    self.error = error.localizedDescription
                    self.isLoading = false
                }
            }
        }

        var components = URLComponents(string: "https://login.microsoftonline.com/\(OutlookGraphSettings.tenantID)/oauth2/v2.0/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: OutlookGraphSettings.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "response_mode", value: "query"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: expectedState),
        ]

        if let url = components.url {
            NSWorkspace.shared.open(url)
        }
    }

    func signOut() {
        OutlookGraphTokenStore.clear()
        isAuthenticated = false
        error = nil
    }

    func validAccessToken() async throws -> String {
        if let token = OutlookGraphTokenStore.accessToken,
           let expiry = OutlookGraphTokenStore.accessTokenExpiry,
           expiry > Date() {
            return token
        }
        return try await refreshAccessToken()
    }

    private func exchangeCodeForTokens(code: String, redirectURI: String) async {
        do {
            let json = try await requestToken(params: [
                ("client_id", OutlookGraphSettings.clientID),
                ("scope", scopes),
                ("code", code),
                ("redirect_uri", redirectURI),
                ("grant_type", "authorization_code"),
                ("code_verifier", codeVerifier),
            ])
            try saveTokenResponse(json)
            try await fetchProfile()
            isAuthenticated = true
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func refreshAccessToken() async throws -> String {
        guard let refreshToken = OutlookGraphTokenStore.refreshToken else {
            throw OutlookGraphError(message: "Microsoft Outlook is not signed in.")
        }
        let json = try await requestToken(params: [
            ("client_id", OutlookGraphSettings.clientID),
            ("scope", scopes),
            ("refresh_token", refreshToken),
            ("grant_type", "refresh_token"),
        ])
        try saveTokenResponse(json)
        return OutlookGraphTokenStore.accessToken ?? ""
    }

    private func requestToken(params: [(String, String)]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://login.microsoftonline.com/\(OutlookGraphSettings.tenantID)/oauth2/v2.0/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = params.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.1)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OutlookGraphError(message: String(data: data, encoding: .utf8) ?? "Microsoft sign-in failed.")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OutlookGraphError(message: "Microsoft token response was not valid JSON.")
        }
        return json
    }

    private func saveTokenResponse(_ json: [String: Any]) throws {
        guard let accessToken = json["access_token"] as? String, !accessToken.isEmpty else {
            throw OutlookGraphError(message: "Microsoft token response did not include an access token.")
        }
        let refreshToken = json["refresh_token"] as? String
        let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        OutlookGraphTokenStore.save(accessToken: accessToken, refreshToken: refreshToken, expiresIn: expiresIn)
    }

    private func fetchProfile() async throws {
        let token = try await validAccessToken()
        var request = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me?$select=displayName,userPrincipalName,mail")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        let name = json["displayName"] as? String ?? ""
        let email = json["mail"] as? String ?? json["userPrincipalName"] as? String ?? ""
        OutlookGraphTokenStore.saveProfile(name: name, email: email)
    }

    private static func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func generateCodeChallenge(from verifier: String) -> String {
        guard let data = verifier.data(using: .utf8) else { return "" }
        var hash = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &hash)
        }
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

struct OutlookGraphClient {
    var accessTokenProvider: () async throws -> String
    var session: URLSession = .shared

    func searchTaskCandidates(_ search: OutlookMailSearchRequest) async throws -> [OutlookTaskCandidate] {
        let token = try await accessTokenProvider()
        var request = URLRequest(url: searchURL(for: search))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("outlook.body-content-type=\"text\"", forHTTPHeaderField: "Prefer")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OutlookGraphError(message: String(data: data, encoding: .utf8) ?? "Outlook search failed.")
        }

        let messages = try Self.decodeMessages(from: data)
        return messages
            .filter { message in
                if let after = search.after, let sent = message.sentDate, sent < after { return false }
                if let before = search.before, let sent = message.sentDate, sent > Self.endOfDay(for: before) { return false }
                if let sender = search.sender, !sender.isEmpty, !message.sender.localizedCaseInsensitiveContains(sender) { return false }
                return true
            }
            .prefix(search.limit)
            .map(OutlookTaskCandidate.from)
    }

    func searchURL(for search: OutlookMailSearchRequest) -> URL {
        var components = URLComponents(string: "https://graph.microsoft.com/v1.0/me/messages")!
        var queryItems = [
            URLQueryItem(name: "$top", value: "\(search.limit)"),
            URLQueryItem(name: "$select", value: "id,conversationId,subject,from,sentDateTime,bodyPreview,webLink"),
        ]

        if !search.query.isEmpty {
            queryItems.append(URLQueryItem(name: "$search", value: "\"\(search.query)\""))
        } else if let after = search.after {
            queryItems.append(URLQueryItem(name: "$filter", value: "sentDateTime ge \(isoString(after))"))
        }

        components.queryItems = queryItems
        return components.url!
    }

    static func decodeMessages(from data: Data) throws -> [OutlookMessageSummary] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = json["value"] as? [[String: Any]] else {
            throw OutlookGraphError(message: "Outlook search response was not valid JSON.")
        }

        return values.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            let emailAddress = (item["from"] as? [String: Any])?["emailAddress"] as? [String: Any]
            let senderName = (emailAddress?["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let senderAddress = (emailAddress?["address"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let sender: String
            if let senderName, !senderName.isEmpty, let senderAddress, !senderAddress.isEmpty {
                sender = "\(senderName) <\(senderAddress)>"
            } else {
                sender = senderName?.isEmpty == false ? senderName! : (senderAddress ?? "")
            }

            return OutlookMessageSummary(
                id: id,
                conversationID: item["conversationId"] as? String,
                subject: item["subject"] as? String ?? "",
                sender: sender,
                sentDate: parseGraphDate(item["sentDateTime"] as? String),
                bodyPreview: item["bodyPreview"] as? String ?? "",
                webLink: item["webLink"] as? String
            )
        }
    }

    private func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func parseGraphDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }

    private static func endOfDay(for date: Date) -> Date {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: DateComponents(day: 1, second: -1), to: start) ?? date
    }
}
