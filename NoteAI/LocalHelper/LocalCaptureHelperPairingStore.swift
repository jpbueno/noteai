import CryptoKit
import Foundation
import Security

struct LocalCapturePairingChallenge: Equatable {
    var pairingSessionId: String
    var expiresAt: Date
    var codeLength: Int
    var debugCode: String
}

struct LocalCaptureTrustedClient: Codable, Equatable {
    var tokenId: String
    var origin: String
    var clientName: String
    var tokenHash: String
    var createdAt: Date
}

protocol LocalCaptureTrustedClientStore: AnyObject {
    func loadClients() -> [LocalCaptureTrustedClient]
    func saveClients(_ clients: [LocalCaptureTrustedClient])
}

final class KeychainTrustedClientStore: LocalCaptureTrustedClientStore {
    private let key = "localCaptureHelperTrustedClients"

    func loadClients() -> [LocalCaptureTrustedClient] {
        guard let raw = KeychainHelper.load(key: key),
              let data = raw.data(using: .utf8),
              let clients = try? JSONDecoder().decode([LocalCaptureTrustedClient].self, from: data) else {
            return []
        }
        return clients
    }

    func saveClients(_ clients: [LocalCaptureTrustedClient]) {
        guard let data = try? JSONEncoder().encode(clients),
              let raw = String(data: data, encoding: .utf8) else {
            return
        }
        KeychainHelper.save(key: key, value: raw)
    }
}

final class InMemoryTrustedClientStore: LocalCaptureTrustedClientStore {
    private(set) var rawJSON = "[]"

    func loadClients() -> [LocalCaptureTrustedClient] {
        guard let data = rawJSON.data(using: .utf8),
              let clients = try? JSONDecoder().decode([LocalCaptureTrustedClient].self, from: data) else {
            return []
        }
        return clients
    }

    func saveClients(_ clients: [LocalCaptureTrustedClient]) {
        guard let data = try? JSONEncoder().encode(clients),
              let raw = String(data: data, encoding: .utf8) else {
            return
        }
        rawJSON = raw
    }
}

enum LocalCaptureHelperPairingError: LocalizedError {
    case sessionNotFound
    case expired
    case invalidCode
    case nonceMismatch

    var errorDescription: String? {
        switch self {
        case .sessionNotFound:
            return "Pairing session was not found."
        case .expired:
            return "Pairing session expired."
        case .invalidCode:
            return "Pairing code is invalid."
        case .nonceMismatch:
            return "Pairing nonce does not match."
        }
    }
}

final class LocalCaptureHelperPairingStore {
    private struct PendingSession {
        var sessionId: String
        var origin: String
        var clientName: String
        var clientNonce: String
        var code: String
        var expiresAt: Date
    }

    private let trustedClientStore: LocalCaptureTrustedClientStore
    private let lock = NSLock()
    private var pendingSessions: [String: PendingSession] = [:]
    private let sessionDuration: TimeInterval

    init(
        trustedClientStore: LocalCaptureTrustedClientStore = KeychainTrustedClientStore(),
        sessionDuration: TimeInterval = 120
    ) {
        self.trustedClientStore = trustedClientStore
        self.sessionDuration = sessionDuration
    }

    func createPairingRequest(
        origin: String,
        clientName: String,
        clientNonce: String,
        now: Date = Date()
    ) -> LocalCapturePairingChallenge {
        let sessionId = UUID().uuidString
        let code = Self.randomDigits(count: 6)
        let expiresAt = now.addingTimeInterval(sessionDuration)
        let pending = PendingSession(
            sessionId: sessionId,
            origin: origin,
            clientName: clientName,
            clientNonce: clientNonce,
            code: code,
            expiresAt: expiresAt
        )

        lock.lock()
        pendingSessions[sessionId] = pending
        lock.unlock()

        return LocalCapturePairingChallenge(
            pairingSessionId: sessionId,
            expiresAt: expiresAt,
            codeLength: code.count,
            debugCode: code
        )
    }

    func confirmPairing(
        sessionId: String,
        code: String,
        clientNonce: String,
        now: Date = Date()
    ) throws -> LocalCapturePairConfirmResponse {
        lock.lock()
        guard let pending = pendingSessions[sessionId] else {
            lock.unlock()
            throw LocalCaptureHelperPairingError.sessionNotFound
        }
        if pending.expiresAt < now {
            pendingSessions.removeValue(forKey: sessionId)
            lock.unlock()
            throw LocalCaptureHelperPairingError.expired
        }
        guard pending.clientNonce == clientNonce else {
            lock.unlock()
            throw LocalCaptureHelperPairingError.nonceMismatch
        }
        guard pending.code == code.trimmingCharacters(in: .whitespacesAndNewlines) else {
            lock.unlock()
            throw LocalCaptureHelperPairingError.invalidCode
        }
        pendingSessions.removeValue(forKey: sessionId)
        lock.unlock()

        let token = Self.randomToken()
        let tokenId = UUID().uuidString
        let client = LocalCaptureTrustedClient(
            tokenId: tokenId,
            origin: pending.origin,
            clientName: pending.clientName,
            tokenHash: Self.hashToken(token, origin: pending.origin),
            createdAt: now
        )
        var clients = trustedClientStore.loadClients()
        clients.removeAll { $0.origin == pending.origin && $0.clientName == pending.clientName }
        clients.append(client)
        trustedClientStore.saveClients(clients)

        return LocalCapturePairConfirmResponse(
            accessToken: token,
            tokenId: tokenId,
            origin: pending.origin,
            expiresAt: nil
        )
    }

    func validate(token: String, origin: String) -> Bool {
        let actual = Self.hashToken(token, origin: origin)
        return trustedClientStore.loadClients().contains { client in
            client.origin == origin && Self.constantTimeEqual(client.tokenHash, actual)
        }
    }

    func revoke(tokenId: String) {
        var clients = trustedClientStore.loadClients()
        clients.removeAll { $0.tokenId == tokenId }
        trustedClientStore.saveClients(clients)
    }

    private static func randomDigits(count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(Int($0) % 10) }.joined()
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func hashToken(_ token: String, origin: String) -> String {
        let data = Data("\(origin):\(token)".utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        guard lhs.utf8.count == rhs.utf8.count else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(lhs.utf8, rhs.utf8) {
            diff |= a ^ b
        }
        return diff == 0
    }
}
