import Foundation
import AppKit
import CommonCrypto

/// Google Sign-In via OAuth 2.0 with localhost redirect.
/// Uses a temporary local HTTP server to catch the callback — no custom URL scheme needed.
@MainActor
final class GoogleAuthManager: NSObject, ObservableObject {
    @Published var isAuthenticated = false
    @Published var userProfile: GoogleUserProfile?
    @Published var isLoading = false
    @Published var error: String?

    // Google's official desktop OAuth client ID (same one used by gcloud CLI)
    // This is a public client ID that supports loopback redirects for desktop apps.
    private let clientID = "764086051850-6qr4p6gpi6hn506pt8ejuq83di341hur.apps.googleusercontent.com"
    private let clientSecret = "d-FL95Q19q7MQmFpd7hHD0Ty" // Public secret for desktop apps (not actually secret)
    private let scopes = "openid email profile"

    private var localServer: LocalOAuthServer?
    private var codeVerifier = ""
    private var oauthState = ""

    override init() {
        super.init()
        restoreSession()
    }

    // MARK: - Sign In

    func signIn() {
        isLoading = true
        error = nil
        localServer?.stop()
        localServer = nil

        // PKCE
        codeVerifier = generateCodeVerifier()
        oauthState = generateCodeVerifier()
        let codeChallenge = generateCodeChallenge(from: codeVerifier)

        // Start local server to receive callback
        let server = LocalOAuthServer()
        localServer = server

        let expectedState = oauthState
        server.start(expectedState: expectedState) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.localServer?.stop()
                self.localServer = nil

                switch result {
                case .success(let code):
                    await self.exchangeCodeForTokens(code: code, redirectURI: "http://127.0.0.1:\(server.port)")
                case .failure(let err):
                    self.isLoading = false
                    self.error = err.localizedDescription
                }
            }
        }

        // Build auth URL with localhost redirect
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: "http://127.0.0.1:\(server.port)"),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: expectedState),
        ]

        if let url = components.url {
            if !NSWorkspace.shared.open(url) {
                localServer?.stop()
                localServer = nil
                isLoading = false
                error = "Could not open Google sign-in in your browser."
            }
        } else {
            localServer?.stop()
            localServer = nil
            isLoading = false
            error = "Could not build Google sign-in URL."
        }
    }

    func signOut() {
        KeychainHelper.delete(key: "google_access_token")
        KeychainHelper.delete(key: "google_refresh_token")
        UserDefaults.standard.removeObject(forKey: "google_user_name")
        UserDefaults.standard.removeObject(forKey: "google_user_email")
        UserDefaults.standard.removeObject(forKey: "google_user_photo")
        UserDefaults.standard.removeObject(forKey: "skippedAuth")
        isAuthenticated = false
        userProfile = nil
    }

    // MARK: - Token Exchange

    private func exchangeCodeForTokens(code: String, redirectURI: String) async {
        isLoading = true
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let params: [(String, String)] = [
            ("code", code),
            ("client_id", clientID),
            ("client_secret", clientSecret),
            ("redirect_uri", redirectURI),
            ("grant_type", "authorization_code"),
            ("code_verifier", codeVerifier),
        ]
        let body = OAuthFormURLEncoder.body(params)
        request.httpBody = body.data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let errBody = String(data: data, encoding: .utf8) ?? ""
                error = "Sign-in failed: \(errBody)"
                isLoading = false
                return
            }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let accessToken = json?["access_token"] as? String ?? ""
            let refreshToken = json?["refresh_token"] as? String ?? ""

            let profile = try await fetchUserProfile(accessToken: accessToken)
            KeychainHelper.save(key: "google_access_token", value: accessToken)
            if !refreshToken.isEmpty {
                KeychainHelper.save(key: "google_refresh_token", value: refreshToken)
            }
            persistUserProfile(profile)
            UserDefaults.standard.removeObject(forKey: "skippedAuth")
            isAuthenticated = true
            isLoading = false
        } catch {
            self.error = "Sign-in error: \(error.localizedDescription)"
            isLoading = false
        }
    }

    // MARK: - User Profile

    private func fetchUserProfile(accessToken: String) async throws -> GoogleUserProfile {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        return try GoogleUserProfilePayload.profile(from: json)
    }

    private func persistUserProfile(_ profile: GoogleUserProfile) {
        userProfile = profile
        UserDefaults.standard.set(profile.name, forKey: "google_user_name")
        UserDefaults.standard.set(profile.email, forKey: "google_user_email")
        UserDefaults.standard.set(profile.photoURL, forKey: "google_user_photo")
    }

    // MARK: - Session Restore

    private func restoreSession() {
        let state = GoogleAccountSessionState.resolve(
            accessToken: KeychainHelper.load(key: "google_access_token"),
            name: UserDefaults.standard.string(forKey: "google_user_name") ?? "",
            email: UserDefaults.standard.string(forKey: "google_user_email") ?? "",
            photoURL: UserDefaults.standard.string(forKey: "google_user_photo") ?? "",
            skippedAuth: UserDefaults.standard.bool(forKey: "skippedAuth")
        )
        if case .signedIn(let profile) = state {
            userProfile = profile
            isAuthenticated = true
        }
    }

    // MARK: - PKCE

    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func generateCodeChallenge(from verifier: String) -> String {
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

// MARK: - Local OAuth Server

/// Tiny HTTP server that listens on localhost to receive the Google OAuth redirect.
final class LocalOAuthServer {
    let port: UInt16
    private var serverSocket: Int32 = -1
    private var isRunning = false

    init() {
        // Pick a random available port
        self.port = UInt16.random(in: 49152...65535)
    }

    func start(expectedState: String, completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                serverSocket = socket(AF_INET, SOCK_STREAM, 0)
                guard serverSocket >= 0 else { throw OAuthServerError.socketFailed }

                var opt: Int32 = 1
                setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))

                var addr = sockaddr_in()
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = port.bigEndian
                addr.sin_addr.s_addr = inet_addr("127.0.0.1")

                let bindResult = withUnsafePointer(to: &addr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bindPtr in
                        bind(serverSocket, bindPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                guard bindResult >= 0 else { throw OAuthServerError.bindFailed }

                listen(serverSocket, 1)
                isRunning = true

                // Wait for one connection
                let clientSocket = accept(serverSocket, nil, nil)
                guard clientSocket >= 0 else { throw OAuthServerError.acceptFailed }

                // Read the request
                var buffer = [UInt8](repeating: 0, count: 4096)
                let bytesRead = read(clientSocket, &buffer, buffer.count)
                let requestString = String(bytes: buffer[0..<max(bytesRead, 0)], encoding: .utf8) ?? ""

                let authCode = OAuthCallbackParser.authorizationCode(
                    from: requestString,
                    expectedState: expectedState
                )

                // Send response
                let html: String
                if authCode != nil {
                    html = """
                    <html><body style="background:#191919;color:#eee;font-family:system-ui;display:flex;justify-content:center;align-items:center;height:100vh;margin:0">
                    <div style="text-align:center"><h1>Signed in!</h1><p>You can close this tab and return to NoteAI.</p></div>
                    </body></html>
                    """
                } else {
                    html = "<html><body><h1>Error</h1><p>No authorization code received.</p></body></html>"
                }
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n\(html)"
                _ = response.withCString { write(clientSocket, $0, strlen($0)) }
                close(clientSocket)

                if let code = authCode {
                    completion(.success(code))
                } else {
                    completion(.failure(OAuthServerError.noCode))
                }
            } catch {
                completion(.failure(error))
            }
        }
    }

    func stop() {
        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }
        isRunning = false
    }

    enum OAuthServerError: LocalizedError {
        case socketFailed, bindFailed, acceptFailed, noCode
        var errorDescription: String? {
            switch self {
            case .socketFailed: return "Failed to create socket"
            case .bindFailed: return "Failed to bind to port"
            case .acceptFailed: return "Failed to accept connection"
            case .noCode: return "No authorization code in callback"
            }
        }
    }
}

enum OAuthCallbackParser {
    static func authorizationCode(from requestString: String, expectedState: String) -> String? {
        guard let firstLine = requestString.split(separator: "\r\n").first else { return nil }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let path = String(parts[1])
        guard let components = URLComponents(string: path),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
              let state = components.queryItems?.first(where: { $0.name == "state" })?.value,
              state == expectedState else {
            return nil
        }
        return code
    }
}

// MARK: - User Profile

struct GoogleUserProfile: Equatable {
    let name: String
    let email: String
    let photoURL: String

    var initials: String {
        let parts = name.split(separator: " ")
        let first = parts.first?.prefix(1) ?? ""
        let last = parts.count > 1 ? parts.last!.prefix(1) : ""
        return "\(first)\(last)".uppercased()
    }
}
