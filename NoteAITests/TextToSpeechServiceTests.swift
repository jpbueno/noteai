import XCTest
@testable import NoteAI

@MainActor
final class TextToSpeechServiceTests: XCTestCase {
    func testSpeechConnectionKeepsCredentialsWithTheirProvider() {
        let direct = SpeechConnection.resolve(
            selectedProvider: .nvidia, ttsKey: "dedicated-without-a-prefix",
            nvidiaKey: "nvidia-key", openAIKey: "openai-key"
        )
        XCTAssertEqual(direct?.endpoint.absoluteString, "https://api.openai.com/v1/audio/speech")
        XCTAssertEqual(direct?.model, "gpt-4o-mini-tts")
        XCTAssertEqual(direct?.apiKey, "dedicated-without-a-prefix")

        let selected = SpeechConnection.resolve(
            selectedProvider: .openAI, ttsKey: "", nvidiaKey: "nvidia-key", openAIKey: "openai-key"
        )
        XCTAssertEqual(selected?.provider, .openAI)
        XCTAssertEqual(selected?.apiKey, "openai-key")

        let fallback = SpeechConnection.resolve(
            selectedProvider: .anthropic, ttsKey: "", nvidiaKey: "nvidia-key", openAIKey: "openai-key"
        )
        XCTAssertEqual(fallback?.endpoint.absoluteString, "https://inference-api.nvidia.com/v1/audio/speech")
        XCTAssertEqual(fallback?.model, "openai/openai/gpt-4o-mini-tts")
        XCTAssertEqual(fallback?.apiKey, "nvidia-key")
        XCTAssertNil(SpeechConnection.resolve(selectedProvider: .openRouter, ttsKey: "", nvidiaKey: "", openAIKey: ""))
    }

    func testBlankTextDoesNotRequestAudioAndMissingConnectionIsActionable() async {
        let transport = ControlledSpeechTransport()
        let service = makeService(transport: transport, connection: nil)
        service.speak(" \n\t ")
        await Task.yield()
        XCTAssertEqual(service.state, .idle)
        XCTAssertNil(service.error)
        XCTAssertTrue(transport.requests.isEmpty)

        service.speak("Read this")
        XCTAssertEqual(service.state, .idle)
        XCTAssertTrue(service.error?.contains("Settings > AI") == true)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testRequestsUseSpeechModelAndExactText() async throws {
        let transport = ControlledSpeechTransport()
        let player = TestSpeechPlayback()
        let service = makeService(transport: transport, player: player)
        service.speak("  Read this exactly.\n")
        await waitUntil { transport.requests.count == 1 }

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://inference-api.nvidia.com/v1/audio/speech")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
        let body = try jsonBody(request)
        XCTAssertEqual(body["model"], "openai/openai/gpt-4o-mini-tts")
        XCTAssertEqual(body["voice"], "nova")
        XCTAssertEqual(body["input"], "  Read this exactly.\n")
        XCTAssertEqual(body["response_format"], "mp3")
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)

        transport.succeed(0, data: Data([1, 2, 3]))
        await waitUntil { service.state == .playing }
        XCTAssertTrue(player.isPlaying)
        service.stop()
    }

    func testLongUnicodeTextIsReadInOrderWithinSpeechTokenBudget() async throws {
        let transport = ControlledSpeechTransport()
        let player = TestSpeechPlayback()
        let service = makeService(transport: transport, player: player)
        // One enormous extended grapheme must still fit into bounded requests.
        let combiningCluster = "e" + String(repeating: "\u{0301}", count: 2000)
        let text = String(repeating: "A", count: 4095) + "👩🏽‍💻\n" + combiningCluster + "\nFinal sentence."
        service.speak(text)
        var reconstructed = ""
        var part = 0
        while reconstructed.utf8.count < text.utf8.count && part < 20 {
            await waitUntil { transport.requests.count == part + 1 }
            let input = try XCTUnwrap(try jsonBody(transport.requests[part])["input"])
            XCTAssertFalse(input.isEmpty)
            XCTAssertLessThanOrEqual(input.utf8.count, 1800)
            reconstructed += input
            transport.succeed(part)
            await waitUntil { service.state == .playing }
            XCTAssertEqual(transport.requests.count, part + 1, "Next part must wait for playback to finish")
            XCTAssertLessThanOrEqual(service.progress, 1)
            player.finish()
            part += 1
        }
        await waitUntil { service.state == .idle }
        XCTAssertEqual(Array(reconstructed.utf8), Array(text.utf8))
        XCTAssertGreaterThan(part, 1)
        XCTAssertNil(service.error)
    }

    func testWhitespaceOnlyPartsAreSkippedBeforeAndBetweenSpokenText() async throws {
        let transport = ControlledSpeechTransport()
        let player = TestSpeechPlayback()
        let service = makeService(transport: transport, player: player)
        let expected = String(repeating: "A", count: 2200) + "Tail"
        let text = " " + String(repeating: "A", count: 2200) + String(repeating: " ", count: 4000) + "Tail"
        service.speak(text)
        var spoken = ""
        var part = 0
        while spoken.count < expected.count && part < 20 {
            await waitUntil { transport.requests.count == part + 1 }
            let input = try XCTUnwrap(try jsonBody(transport.requests[part])["input"])
            XCTAssertFalse(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            spoken += input.filter { !$0.isWhitespace }
            transport.succeed(part)
            await waitUntil { service.state == .playing }
            player.finish()
            part += 1
        }
        await waitUntil { service.state == .idle }
        XCTAssertEqual(spoken, expected)
        XCTAssertNil(service.error)
    }

    func testPauseResumeAndStopDiscardRemainingText() async {
        let transport = ControlledSpeechTransport()
        let player = TestSpeechPlayback()
        let service = makeService(transport: transport, player: player)
        service.speak(String(repeating: "x", count: 5000))
        await waitUntil { transport.requests.count == 1 }
        transport.succeed(0)
        await waitUntil { service.state == .playing }
        service.togglePlayPause()
        XCTAssertEqual(service.state, .paused)
        XCTAssertFalse(player.isPlaying)
        service.togglePlayPause()
        XCTAssertEqual(service.state, .playing)
        XCTAssertTrue(player.isPlaying)
        service.stop()
        XCTAssertEqual(service.state, .idle)
        XCTAssertEqual(service.progress, 0)
        XCTAssertFalse(player.isPlaying)
        try? await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testStoppedRequestCannotOverrideNewPlaybackOrReportCancellation() async {
        let transport = ControlledSpeechTransport()
        let player = TestSpeechPlayback()
        let service = makeService(transport: transport, player: player)
        service.speak("Old text")
        await waitUntil { transport.requests.count == 1 }
        service.speak("New text")
        await waitUntil { transport.requests.count == 2 }
        transport.succeed(1)
        await waitUntil { service.state == .playing }
        transport.fail(0, error: URLError(.cancelled))
        await waitUntil { transport.completedRequests.contains(0) }
        XCTAssertEqual(service.state, .playing)
        XCTAssertNil(service.error)
        XCTAssertTrue(player.isPlaying)
        service.stop()
    }

    func testStaleSuccessCannotReplaceNewPlayback() async {
        let transport = ControlledSpeechTransport()
        let player = TestSpeechPlayback()
        let service = makeService(transport: transport, player: player)
        service.speak("Old text")
        await waitUntil { transport.requests.count == 1 }
        service.speak("New text")
        await waitUntil { transport.requests.count == 2 }
        transport.succeed(1)
        await waitUntil { service.state == .playing }
        transport.succeed(0)
        await waitUntil { transport.completedRequests.contains(0) }
        XCTAssertEqual(service.state, .playing)
        XCTAssertEqual(player.playCount, 1)
        XCTAssertNil(service.error)
        service.stop()
    }

    func testProviderErrorDoesNotEchoSensitiveResponseBody() async {
        let transport = ControlledSpeechTransport()
        let service = makeService(transport: transport)
        service.speak("Private pasted document")
        await waitUntil { transport.requests.count == 1 }
        transport.succeed(0, status: 401, data: Data("private document fixture-key".utf8))
        await waitUntil { service.state == .idle }
        XCTAssertTrue(service.error?.contains("401") == true)
        XCTAssertFalse(service.error?.contains("private document") == true)
        XCTAssertFalse(service.error?.contains("fixture-key") == true)
    }

    private func makeService(
        transport: ControlledSpeechTransport,
        player: TestSpeechPlayback? = nil,
        connection: SpeechConnection? = SpeechConnection(provider: .nvidia, apiKey: "fixture-key")
    ) -> TextToSpeechService {
        TextToSpeechService(
            connectionProvider: { connection },
            voiceProvider: { "nova" },
            loadAudio: { request in try await transport.load(request) },
            makePlayer: { _ in player ?? TestSpeechPlayback() }
        )
    }

    private func jsonBody(_ request: URLRequest) throws -> [String: String] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
    }

    private func waitUntil(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for speech state", file: file, line: line)
    }
}

@MainActor
private final class ControlledSpeechTransport {
    var requests: [URLRequest] = []
    var completedRequests: Set<Int> = []
    private var continuations: [Int: CheckedContinuation<(Data, URLResponse), Error>] = [:]

    func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let index = requests.count
        requests.append(request)
        defer { completedRequests.insert(index) }
        return try await withCheckedThrowingContinuation { continuations[index] = $0 }
    }

    func succeed(_ index: Int, status: Int = 200, data: Data = Data([1])) {
        let response = HTTPURLResponse(url: requests[index].url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "audio/mpeg"])!
        continuations.removeValue(forKey: index)?.resume(returning: (data, response))
    }

    func fail(_ index: Int, error: Error) {
        continuations.removeValue(forKey: index)?.resume(throwing: error)
    }
}

@MainActor
private final class TestSpeechPlayback: SpeechPlayback {
    var isPlaying = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 1
    var playCount = 0
    func play() -> Bool { isPlaying = true; playCount += 1; if currentTime >= duration { currentTime = 0 }; return true }
    func pause() { isPlaying = false }
    func stop() { isPlaying = false }
    func finish() { isPlaying = false; currentTime = duration }
}
