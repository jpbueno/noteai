import Foundation

enum AIPIMSource: String, CaseIterable, Sendable {
    case slack
    case teams

    var displayName: String {
        switch self {
        case .slack: return "Slack"
        case .teams: return "Teams"
        }
    }

    var binaryName: String {
        switch self {
        case .slack: return "slack-cli"
        case .teams: return "teams-cli"
        }
    }
}

protocol AIPIMSourceConnecting: Sendable {
    func status(for source: AIPIMSource) async -> AIPIMSourceStatus
    func login(to source: AIPIMSource) async -> AIPIMSourceStatus
}

enum AIPIMConnectionState: Equatable, Sendable {
    case available
    case authenticationRequired
    case unavailable
    case failed
}

struct AIPIMSourceStatus: Equatable, Sendable {
    let source: AIPIMSource
    let state: AIPIMConnectionState
    let installed: Bool
    let authenticated: Bool
    let message: String

    static func unchecked(_ source: AIPIMSource) -> AIPIMSourceStatus {
        AIPIMSourceStatus(
            source: source,
            state: .unavailable,
            installed: false,
            authenticated: false,
            message: "Status not checked."
        )
    }
}

struct AIPIMWorkActivityItem: Equatable, Sendable {
    let id: String
    let source: AIPIMSource
    let timestamp: Date
    let title: String
    let body: String
    let url: URL?
    let contextName: String?
}

struct AIPIMSearchResult: Equatable, Sendable {
    let source: AIPIMSource
    let items: [AIPIMWorkActivityItem]
    let isPartial: Bool
    let partialReasons: [String]
}

enum AIPIMError: Error, Equatable, Sendable {
    case unavailable(AIPIMSource)
    case authenticationRequired(AIPIMSource)
    case timedOut(AIPIMSource)
    case outputLimitExceeded(AIPIMSource)
    case commandFailed(AIPIMSource)
    case invalidResponse(AIPIMSource)
    case invalidLimit(AIPIMSource)
}

extension AIPIMError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unavailable(let source):
            return "\(source.displayName) requires ai-pim-utils."
        case .authenticationRequired(let source):
            return "\(source.displayName) authentication is required."
        case .timedOut(let source):
            return "\(source.displayName) search timed out."
        case .outputLimitExceeded(let source):
            return "\(source.displayName) returned more data than NoteAI can safely process."
        case .commandFailed(let source):
            return "\(source.displayName) search failed."
        case .invalidResponse(let source):
            return "\(source.displayName) returned an invalid response."
        case .invalidLimit(let source):
            return "\(source.displayName) search limit is invalid."
        }
    }
}

enum AIPIMInstallHelp {
    static let commands = [
        "brew tap ai-cli/ai-pim-utils",
        "brew install --cask ai-pim-utils"
    ]
}
