import Foundation

enum LocalCaptureHelperProtocol {
    static let version = "2026-04-28"
    static let defaultPort: UInt16 = 47391
}

struct LocalCaptureHelperCapabilities: Codable, Equatable {
    var status: Bool
    var pairing: Bool
    var captureControl: Bool
    var events: Bool
    var audioStreaming: Bool
}

struct LocalCaptureHelperHealthResponse: Codable, Equatable {
    var protocolVersion: String
    var helperVersion: String
    var appName: String
    var status: String
    var pairingRequired: Bool
    var capabilities: LocalCaptureHelperCapabilities
}

struct LocalCaptureHelperPermission: Codable, Equatable {
    var status: String
    var action: String?
    var reason: String?
    var requiresMacOS: String?
}

struct LocalCaptureHelperPermissions: Codable, Equatable {
    var microphone: LocalCaptureHelperPermission
    var screenRecording: LocalCaptureHelperPermission
    var processTap: LocalCaptureHelperPermission
}

struct LocalCaptureHelperTeamsStatus: Codable, Equatable {
    var detected: Bool
    var bundleId: String?
    var pid: Int?
    var displayName: String?
    var frontmost: Bool
    var audioActivity: String
}

struct LocalCaptureHelperSourceStatus: Codable, Equatable {
    var status: String
    var adapter: String?
    var level: Double
    var reason: String?
}

struct LocalCaptureHelperSources: Codable, Equatable {
    var microphone: LocalCaptureHelperSourceStatus
    var teamsAudio: LocalCaptureHelperSourceStatus
    var desktopAudioFallback: LocalCaptureHelperSourceStatus
}

struct LocalCaptureHelperDiagnostic: Codable, Equatable {
    var severity: String
    var code: String
    var message: String
}

struct LocalCaptureHelperStatusResponse: Codable, Equatable {
    var protocolVersion: String
    var helperVersion: String
    var captureState: String
    var recordingIndicator: String
    var permissions: LocalCaptureHelperPermissions
    var teams: LocalCaptureHelperTeamsStatus
    var sources: LocalCaptureHelperSources
    var diagnostics: [LocalCaptureHelperDiagnostic]
}

struct LocalCapturePairRequest: Codable, Equatable {
    var origin: String
    var clientName: String
    var clientNonce: String
}

struct LocalCapturePairRequestResponse: Codable, Equatable {
    var pairingSessionId: String
    var expiresAt: Date
    var codeLength: Int
}

struct LocalCapturePairConfirmRequest: Codable, Equatable {
    var pairingSessionId: String
    var code: String
    var clientNonce: String
}

struct LocalCapturePairConfirmResponse: Codable, Equatable {
    var accessToken: String
    var tokenId: String
    var origin: String
    var expiresAt: Date?
}

struct LocalCaptureHelperErrorResponse: Codable, Equatable {
    var error: String
    var message: String
}
