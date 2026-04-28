import XCTest
@testable import NoteAI

final class LocalCaptureHelperTests: XCTestCase {
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
}
