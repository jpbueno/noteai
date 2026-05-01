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

struct LocalCaptureTranscriptSegment: Codable, Equatable {
    var id: Int
    var text: String
    var startTime: Float
    var endTime: Float
    var speaker: String?
    var confidence: Float
}

struct LocalCaptureSessionSnapshot: Codable, Equatable {
    var sessionId: UUID?
    var state: String
    var recordingIndicator: String
    var startedAt: Date?
    var duration: TimeInterval
    var transcript: [LocalCaptureTranscriptSegment]

    static let idle = LocalCaptureSessionSnapshot(
        sessionId: nil,
        state: "idle",
        recordingIndicator: "visible-idle",
        startedAt: nil,
        duration: 0,
        transcript: []
    )
}

// /v1/events is intentionally a small SSE Interface for this slice:
// authenticated localhost-only clients receive one capture.snapshot event and
// the connection closes. Reconnects get a fresh snapshot; raw audio is not
// streamed until a bounded, separately authorized audio Interface exists.
struct LocalCaptureHelperEventStreamPolicy: Codable, Equatable {
    var transport: String
    var endpoint: String
    var authentication: String
    var reconnect: String
    var backpressure: String
    var transcriptSemantics: String
    var audioStreaming: String
    var reconnectRetryMilliseconds: Int

    static let current = LocalCaptureHelperEventStreamPolicy(
        transport: "server-sent-events-over-loopback-http",
        endpoint: "/v1/events",
        authentication: "origin-bound-bearer-token",
        reconnect: "clients may reconnect and receive a fresh snapshot; Last-Event-ID replay is unsupported in this slice",
        backpressure: "bounded snapshot response closes after the current event; future live streams should coalesce transcript snapshots instead of queueing unbounded events",
        transcriptSemantics: "capture.snapshot carries the complete current transcript snapshot and a transcriptRevision derived from the latest segment id",
        audioStreaming: "unsupported",
        reconnectRetryMilliseconds: 5_000
    )
}

struct LocalCaptureHelperEventEnvelope: Codable, Equatable {
    var type: String
    var protocolVersion: String
    var emittedAt: Date
    var snapshot: LocalCaptureSessionSnapshot
    var transcriptRevision: Int
    var audioStreaming: String
}

struct LocalCaptureStartRequest: Codable, Equatable {
    var source: String
    var title: String?
    var includeMicrophone: Bool
    var allowDesktopAudioFallback: Bool
}

struct LocalCaptureStartResponse: Codable, Equatable {
    var sessionId: UUID
    var captureState: String
    var startedAt: Date
    var recordingIndicator: String
}

struct LocalCaptureStopResponse: Codable, Equatable {
    var sessionId: UUID
    var captureState: String
    var startedAt: Date
    var stoppedAt: Date
    var duration: TimeInterval
    var transcript: [LocalCaptureTranscriptSegment]
}

@MainActor
protocol LocalCaptureControlling: AnyObject {
    var snapshot: LocalCaptureSessionSnapshot { get }
    func startCapture(_ request: LocalCaptureStartRequest) async throws -> LocalCaptureStartResponse
    func stopCapture() async throws -> LocalCaptureStopResponse
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
