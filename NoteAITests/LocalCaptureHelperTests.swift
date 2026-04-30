import XCTest
@testable import NoteAI

final class LocalCaptureHelperTests: XCTestCase {
    private final class FakeCaptureController: LocalCaptureControlling {
        var snapshot = LocalCaptureSessionSnapshot.idle
        var startRequests: [LocalCaptureStartRequest] = []
        var stopCalled = false

        func startCapture(_ request: LocalCaptureStartRequest) async throws -> LocalCaptureStartResponse {
            startRequests.append(request)
            snapshot = LocalCaptureSessionSnapshot(
                sessionId: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                state: "recording",
                recordingIndicator: "visible-recording",
                startedAt: Date(timeIntervalSince1970: 1_772_000_000),
                duration: 0,
                transcript: []
            )
            return LocalCaptureStartResponse(
                sessionId: snapshot.sessionId!,
                captureState: "recording",
                startedAt: snapshot.startedAt!,
                recordingIndicator: "visible-recording"
            )
        }

        func stopCapture() async throws -> LocalCaptureStopResponse {
            stopCalled = true
            let started = snapshot.startedAt ?? Date(timeIntervalSince1970: 1_772_000_000)
            let stopped = started.addingTimeInterval(12)
            snapshot = LocalCaptureSessionSnapshot.idle
            return LocalCaptureStopResponse(
                sessionId: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                captureState: "stopped",
                startedAt: started,
                stoppedAt: stopped,
                duration: 12,
                transcript: [
                    LocalCaptureTranscriptSegment(
                        id: 1,
                        text: "Hello from Teams.",
                        startTime: 0,
                        endTime: 3,
                        speaker: nil,
                        confidence: 0.9
                    )
                ]
            )
        }
    }

    func testHealthResponseDoesNotExposeLocalDiagnostics() throws {
        let health = LocalCaptureHelperStatusProvider(helperVersion: "0.1.0").health()
        let data = try JSONEncoder().encode(health)
        let json = String(decoding: data, as: UTF8.self)

        XCTAssertTrue(json.contains("\"pairingRequired\":true"))
        XCTAssertFalse(json.contains("microphone"))
        XCTAssertFalse(json.contains("Microsoft Teams"))
        XCTAssertFalse(json.contains("transcript"))
    }

    func testPairingTokenIsOriginBoundAndStoredHashed() throws {
        let storage = InMemoryTrustedClientStore()
        let store = LocalCaptureHelperPairingStore(trustedClientStore: storage)
        let challenge = store.createPairingRequest(
            origin: "http://localhost:3000",
            clientName: "NoteAI Web",
            clientNonce: "nonce"
        )
        let confirmed = try store.confirmPairing(
            sessionId: challenge.pairingSessionId,
            code: challenge.debugCode,
            clientNonce: "nonce"
        )

        XCTAssertTrue(store.validate(token: confirmed.accessToken, origin: "http://localhost:3000"))
        XCTAssertFalse(store.validate(token: confirmed.accessToken, origin: "https://evil.example"))
        XCTAssertFalse(storage.rawJSON.contains(confirmed.accessToken))
    }

    func testRouterReturnsHealthWithoutAuthorization() async throws {
        let router = LocalCaptureHelperRouter(
            statusProvider: LocalCaptureHelperStatusProvider(helperVersion: "0.1.0"),
            pairingStore: LocalCaptureHelperPairingStore(trustedClientStore: InMemoryTrustedClientStore()),
            allowedOrigins: ["http://localhost:3000"]
        )

        let response = await router.route(LocalCaptureHTTPRouterRequest(
            method: "GET",
            path: "/v1/health",
            headers: ["Origin": "http://localhost:3000", "Host": "127.0.0.1:47391"],
            body: Data()
        ))

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertTrue(response.bodyText.contains("\"status\":\"ready\""))
        XCTAssertEqual(response.headers["Access-Control-Allow-Origin"], "http://localhost:3000")
        XCTAssertFalse(response.bodyText.contains("microphone"))
    }

    func testServerServesHealthOnLoopbackSocket() async throws {
        let router = LocalCaptureHelperRouter(
            statusProvider: LocalCaptureHelperStatusProvider(helperVersion: "0.1.0"),
            pairingStore: LocalCaptureHelperPairingStore(trustedClientStore: InMemoryTrustedClientStore()),
            allowedOrigins: ["http://localhost:3000"]
        )
        let server = LocalCaptureHelperServer(router: router, port: 0)
        try server.start()
        defer { server.stop() }
        let port = try XCTUnwrap(server.listeningPort)

        let url = URL(string: "http://127.0.0.1:\(port)/v1/health")!
        var request = URLRequest(url: url)
        request.setValue("127.0.0.1:\(port)", forHTTPHeaderField: "Host")
        request.setValue("http://localhost:3000", forHTTPHeaderField: "Origin")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let body = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(body.contains("\"status\":\"ready\""))
        XCTAssertTrue(body.contains("\"captureControl\":false"))
    }

    func testStatusRequiresPairedBearerToken() async throws {
        let router = LocalCaptureHelperRouter(
            statusProvider: LocalCaptureHelperStatusProvider(helperVersion: "0.1.0"),
            pairingStore: LocalCaptureHelperPairingStore(trustedClientStore: InMemoryTrustedClientStore()),
            allowedOrigins: ["http://localhost:3000"]
        )

        let response = await router.route(LocalCaptureHTTPRouterRequest(
            method: "GET",
            path: "/v1/status",
            headers: ["Origin": "http://localhost:3000", "Host": "127.0.0.1:47391"],
            body: Data()
        ))

        XCTAssertEqual(response.statusCode, 401)
        XCTAssertTrue(response.bodyText.contains("pairing_required"))
    }

    @MainActor
    func testCaptureStartRequiresPairedBearerToken() async throws {
        let router = LocalCaptureHelperRouter(
            statusProvider: LocalCaptureHelperStatusProvider(helperVersion: "0.1.0"),
            pairingStore: LocalCaptureHelperPairingStore(trustedClientStore: InMemoryTrustedClientStore()),
            captureController: FakeCaptureController(),
            allowedOrigins: ["http://localhost:3000"]
        )

        let response = await router.route(LocalCaptureHTTPRouterRequest(
            method: "POST",
            path: "/v1/capture/start",
            headers: ["Origin": "http://localhost:3000", "Host": "127.0.0.1:47391"],
            body: Data(#"{"source":"teamsDesktop","title":"Weekly Sync","includeMicrophone":true,"allowDesktopAudioFallback":true}"#.utf8)
        ))

        XCTAssertEqual(response.statusCode, 401)
        XCTAssertTrue(response.bodyText.contains("pairing_required"))
    }

    @MainActor
    func testPairedCaptureStartDelegatesToCaptureController() async throws {
        let storage = InMemoryTrustedClientStore()
        let pairingStore = LocalCaptureHelperPairingStore(trustedClientStore: storage)
        let challenge = pairingStore.createPairingRequest(
            origin: "http://localhost:3000",
            clientName: "NoteAI Web",
            clientNonce: "nonce"
        )
        let token = try pairingStore.confirmPairing(
            sessionId: challenge.pairingSessionId,
            code: challenge.debugCode,
            clientNonce: "nonce"
        ).accessToken
        let controller = FakeCaptureController()
        let router = LocalCaptureHelperRouter(
            statusProvider: LocalCaptureHelperStatusProvider(helperVersion: "0.1.0"),
            pairingStore: pairingStore,
            captureController: controller,
            allowedOrigins: ["http://localhost:3000"]
        )

        let response = await router.route(LocalCaptureHTTPRouterRequest(
            method: "POST",
            path: "/v1/capture/start",
            headers: [
                "Origin": "http://localhost:3000",
                "Host": "127.0.0.1:47391",
                "Authorization": "Bearer \(token)",
            ],
            body: Data(#"{"source":"teamsDesktop","title":"Weekly Sync","includeMicrophone":true,"allowDesktopAudioFallback":true}"#.utf8)
        ))

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(controller.startRequests.first?.source, "teamsDesktop")
        XCTAssertEqual(controller.startRequests.first?.title, "Weekly Sync")
        XCTAssertTrue(response.bodyText.contains("\"captureState\":\"recording\""))
        XCTAssertTrue(response.bodyText.contains("\"recordingIndicator\":\"visible-recording\""))
    }

    @MainActor
    func testPairedCaptureStopReturnsFinalTranscript() async throws {
        let storage = InMemoryTrustedClientStore()
        let pairingStore = LocalCaptureHelperPairingStore(trustedClientStore: storage)
        let challenge = pairingStore.createPairingRequest(
            origin: "http://localhost:3000",
            clientName: "NoteAI Web",
            clientNonce: "nonce"
        )
        let token = try pairingStore.confirmPairing(
            sessionId: challenge.pairingSessionId,
            code: challenge.debugCode,
            clientNonce: "nonce"
        ).accessToken
        let controller = FakeCaptureController()
        let router = LocalCaptureHelperRouter(
            statusProvider: LocalCaptureHelperStatusProvider(helperVersion: "0.1.0"),
            pairingStore: pairingStore,
            captureController: controller,
            allowedOrigins: ["http://localhost:3000"]
        )
        _ = try await controller.startCapture(LocalCaptureStartRequest(
            source: "teamsDesktop",
            title: "Weekly Sync",
            includeMicrophone: true,
            allowDesktopAudioFallback: true
        ))

        let response = await router.route(LocalCaptureHTTPRouterRequest(
            method: "POST",
            path: "/v1/capture/stop",
            headers: [
                "Origin": "http://localhost:3000",
                "Host": "127.0.0.1:47391",
                "Authorization": "Bearer \(token)",
            ],
            body: Data()
        ))

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertTrue(controller.stopCalled)
        XCTAssertTrue(response.bodyText.contains("\"captureState\":\"stopped\""))
        XCTAssertTrue(response.bodyText.contains("Hello from Teams."))
    }
}
