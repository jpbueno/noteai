import Darwin
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
        let testPort: UInt16 = 47591
        let server = LocalCaptureHelperServer(router: router, port: testPort)
        try server.start()
        defer { server.stop() }

        let response = try Self.rawHTTPGet(port: testPort, path: "/v1/health", origin: "http://localhost:3000")

        XCTAssertTrue(response.contains("HTTP/1.1 200 OK"), response)
        XCTAssertTrue(response.contains("\"status\":\"ready\""), response)
        XCTAssertTrue(response.contains("\"captureControl\":false"), response)
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

    private static func rawHTTPGet(port: UInt16, path: String, origin: String) throws -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw posixError(errno) }
        defer { close(fd) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            throw POSIXError(.EADDRNOTAVAIL)
        }

        let connectResult = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else { throw posixError(errno) }

        let request = "GET \(path) HTTP/1.1\r\n" +
            "Host: 127.0.0.1:\(port)\r\n" +
            "Origin: \(origin)\r\n" +
            "Connection: close\r\n" +
            "\r\n"
        let requestBytes = Array(request.utf8)
        try requestBytes.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var sent = 0
            while sent < requestBytes.count {
                let result = send(fd, baseAddress.advanced(by: sent), requestBytes.count - sent, 0)
                guard result > 0 else { throw posixError(errno) }
                sent += result
            }
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count > 0 {
                data.append(buffer, count: count)
                continue
            }
            if count == 0 { break }
            if errno == EINTR { continue }
            throw posixError(errno)
        }

        return String(decoding: data, as: UTF8.self)
    }

    private static func posixError(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
