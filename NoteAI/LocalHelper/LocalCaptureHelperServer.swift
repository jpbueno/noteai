import AppKit
import Darwin
import Foundation

struct LocalCaptureHTTPRouterRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data

    func header(_ name: String) -> String? {
        let wanted = name.lowercased()
        return headers.first { $0.key.lowercased() == wanted }?.value
    }
}

struct LocalCaptureHTTPRouterResponse {
    var statusCode: Int
    var headers: [String: String]
    var body: Data

    var bodyText: String {
        String(data: body, encoding: .utf8) ?? ""
    }
}

@MainActor
protocol LocalCapturePairingPresenting: AnyObject {
    func showPairingRequest(origin: String, clientName: String, code: String, expiresAt: Date)
}

@MainActor
final class LocalCapturePairingPresenter: LocalCapturePairingPresenting {
    func showPairingRequest(origin: String, clientName: String, code: String, expiresAt: Date) {
        let alert = NSAlert()
        alert.messageText = "Pair NoteAI Web"
        alert.informativeText = """
        \(clientName) at \(origin) wants to trust this Mac for Teams Desktop capture diagnostics.

        Enter this code in the web app:

        \(code)

        The code expires at \(expiresAt.formatted(date: .omitted, time: .shortened)).
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

final class LocalCaptureHelperRouter {
    private let statusProvider: LocalCaptureHelperStatusProvider
    private let pairingStore: LocalCaptureHelperPairingStore
    private let captureController: LocalCaptureControlling?
    private weak var pairingPresenter: LocalCapturePairingPresenting?
    private let allowedOrigins: Set<String>
    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    init(
        statusProvider: LocalCaptureHelperStatusProvider = LocalCaptureHelperStatusProvider(),
        pairingStore: LocalCaptureHelperPairingStore = LocalCaptureHelperPairingStore(),
        captureController: LocalCaptureControlling? = nil,
        pairingPresenter: LocalCapturePairingPresenting? = nil,
        allowedOrigins: [String] = LocalCaptureHelperRouter.defaultAllowedOrigins
    ) {
        self.statusProvider = statusProvider
        self.pairingStore = pairingStore
        self.captureController = captureController
        self.pairingPresenter = pairingPresenter
        self.allowedOrigins = Set(allowedOrigins)
    }

    static let defaultAllowedOrigins = [
        "http://localhost:3000",
        "http://127.0.0.1:3000",
        "http://localhost:3001",
        "http://127.0.0.1:3001",
        "http://localhost:3002",
        "http://127.0.0.1:3002",
        "https://noteai-web.noteai-jp.workers.dev",
    ]

    func route(_ request: LocalCaptureHTTPRouterRequest) async -> LocalCaptureHTTPRouterResponse {
        guard isLoopbackHost(request.header("Host")) else {
            return jsonError("invalid_host", "Local helper only accepts loopback Host headers.", statusCode: 403, origin: nil)
        }

        let origin = request.header("Origin")
        guard origin.map(isAllowedOrigin) ?? true else {
            return jsonError("origin_not_allowed", "Origin is not trusted by the local helper.", statusCode: 403, origin: nil)
        }

        if request.method.uppercased() == "OPTIONS" {
            return LocalCaptureHTTPRouterResponse(
                statusCode: 204,
                headers: corsHeaders(origin: origin),
                body: Data()
            )
        }

        switch (request.method.uppercased(), request.path) {
        case ("GET", "/v1/health"):
            var health = statusProvider.health()
            health.capabilities.captureControl = captureController != nil
            health.capabilities.events = true
            health.capabilities.audioStreaming = false
            return json(health, statusCode: 200, origin: origin)
        case ("POST", "/v1/pair/request"):
            return pairRequest(request, origin: origin)
        case ("POST", "/v1/pair/confirm"):
            return pairConfirm(request, origin: origin)
        case ("GET", "/v1/status"):
            guard let origin, isAuthorized(request: request, origin: origin) else {
                return jsonError("pairing_required", "Pair NoteAI Web with the local helper before reading diagnostics.", statusCode: 401, origin: origin)
            }
            var status = await statusProvider.status()
            if let snapshot = await captureController?.snapshot {
                status.captureState = snapshot.state
                status.recordingIndicator = snapshot.recordingIndicator
            }
            return json(status, statusCode: 200, origin: origin)
        case ("GET", "/v1/events"):
            guard let origin, isAuthorized(request: request, origin: origin) else {
                return jsonError("pairing_required", "Pair NoteAI Web with the local helper before streaming capture events.", statusCode: 401, origin: origin)
            }
            return await events(origin: origin)
        case ("POST", "/v1/capture/start"):
            guard let origin, isAuthorized(request: request, origin: origin) else {
                return jsonError("pairing_required", "Pair NoteAI Web with the local helper before starting capture.", statusCode: 401, origin: origin)
            }
            return await captureStart(request, origin: origin)
        case ("POST", "/v1/capture/stop"):
            guard let origin, isAuthorized(request: request, origin: origin) else {
                return jsonError("pairing_required", "Pair NoteAI Web with the local helper before stopping capture.", statusCode: 401, origin: origin)
            }
            return await captureStop(origin: origin)
        default:
            return jsonError("not_found", "No local helper route matches this request.", statusCode: 404, origin: origin)
        }
    }

    private func events(origin: String) async -> LocalCaptureHTTPRouterResponse {
        let snapshot = await captureController?.snapshot ?? .idle
        let event = LocalCaptureHelperEventEnvelope(
            type: "capture.snapshot",
            protocolVersion: LocalCaptureHelperProtocol.version,
            emittedAt: Date(),
            snapshot: snapshot,
            transcriptRevision: snapshot.transcript.map(\.id).max() ?? 0,
            audioStreaming: LocalCaptureHelperEventStreamPolicy.current.audioStreaming
        )
        let data = (try? encoder.encode(event)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let retry = LocalCaptureHelperEventStreamPolicy.current.reconnectRetryMilliseconds
        let body = """
        id: 1
        event: \(event.type)
        retry: \(retry)
        data: \(data)

        """

        return LocalCaptureHTTPRouterResponse(
            statusCode: 200,
            headers: eventStreamHeaders(origin: origin),
            body: Data(body.utf8)
        )
    }

    private func pairRequest(
        _ request: LocalCaptureHTTPRouterRequest,
        origin requestOrigin: String?
    ) -> LocalCaptureHTTPRouterResponse {
        guard let payload = try? decoder.decode(LocalCapturePairRequest.self, from: request.body),
              payload.origin == requestOrigin,
              isAllowedOrigin(payload.origin) else {
            return jsonError("invalid_pairing_request", "Pairing request origin is invalid.", statusCode: 400, origin: requestOrigin)
        }

        let challenge = pairingStore.createPairingRequest(
            origin: payload.origin,
            clientName: payload.clientName,
            clientNonce: payload.clientNonce
        )

        Task { @MainActor [pairingPresenter] in
            pairingPresenter?.showPairingRequest(
                origin: payload.origin,
                clientName: payload.clientName,
                code: challenge.debugCode,
                expiresAt: challenge.expiresAt
            )
        }

        return json(
            LocalCapturePairRequestResponse(
                pairingSessionId: challenge.pairingSessionId,
                expiresAt: challenge.expiresAt,
                codeLength: challenge.codeLength
            ),
            statusCode: 200,
            origin: requestOrigin
        )
    }

    private func pairConfirm(
        _ request: LocalCaptureHTTPRouterRequest,
        origin requestOrigin: String?
    ) -> LocalCaptureHTTPRouterResponse {
        guard let requestOrigin,
              let payload = try? decoder.decode(LocalCapturePairConfirmRequest.self, from: request.body) else {
            return jsonError("invalid_pairing_confirmation", "Pairing confirmation is invalid.", statusCode: 400, origin: requestOrigin)
        }

        do {
            let response = try pairingStore.confirmPairing(
                sessionId: payload.pairingSessionId,
                code: payload.code,
                clientNonce: payload.clientNonce
            )
            guard response.origin == requestOrigin else {
                return jsonError("origin_mismatch", "Pairing origin does not match this request.", statusCode: 403, origin: requestOrigin)
            }
            return json(response, statusCode: 200, origin: requestOrigin)
        } catch {
            return jsonError("pairing_failed", error.localizedDescription, statusCode: 401, origin: requestOrigin)
        }
    }

    private func captureStart(
        _ request: LocalCaptureHTTPRouterRequest,
        origin: String
    ) async -> LocalCaptureHTTPRouterResponse {
        guard let captureController else {
            return jsonError("capture_control_disabled", "Teams Desktop capture control is not enabled.", statusCode: 409, origin: origin)
        }
        guard let payload = try? decoder.decode(LocalCaptureStartRequest.self, from: request.body),
              payload.source == "teamsDesktop" else {
            return jsonError("invalid_capture_request", "Capture start request is invalid.", statusCode: 400, origin: origin)
        }

        do {
            let response = try await captureController.startCapture(payload)
            return json(response, statusCode: 200, origin: origin)
        } catch {
            return jsonError("capture_start_failed", error.localizedDescription, statusCode: 409, origin: origin)
        }
    }

    private func captureStop(origin: String) async -> LocalCaptureHTTPRouterResponse {
        guard let captureController else {
            return jsonError("capture_control_disabled", "Teams Desktop capture control is not enabled.", statusCode: 409, origin: origin)
        }

        do {
            let response = try await captureController.stopCapture()
            return json(response, statusCode: 200, origin: origin)
        } catch {
            return jsonError("capture_stop_failed", error.localizedDescription, statusCode: 409, origin: origin)
        }
    }

    private func isAuthorized(request: LocalCaptureHTTPRouterRequest, origin: String) -> Bool {
        guard let authorization = request.header("Authorization") else { return false }
        let prefix = "Bearer "
        guard authorization.hasPrefix(prefix) else { return false }
        let token = String(authorization.dropFirst(prefix.count))
        return pairingStore.validate(token: token, origin: origin)
    }

    private func isAllowedOrigin(_ origin: String) -> Bool {
        allowedOrigins.contains(origin)
    }

    private func isLoopbackHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "localhost" ||
            host == "127.0.0.1" ||
            host == "[::1]" ||
            host.hasPrefix("localhost:") ||
            host.hasPrefix("127.0.0.1:") ||
            host.hasPrefix("[::1]:")
    }

    private func json<T: Encodable>(
        _ value: T,
        statusCode: Int,
        origin: String?
    ) -> LocalCaptureHTTPRouterResponse {
        let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return LocalCaptureHTTPRouterResponse(
            statusCode: statusCode,
            headers: corsHeaders(origin: origin),
            body: data
        )
    }

    private func jsonError(
        _ error: String,
        _ message: String,
        statusCode: Int,
        origin: String?
    ) -> LocalCaptureHTTPRouterResponse {
        json(
            LocalCaptureHelperErrorResponse(error: error, message: message),
            statusCode: statusCode,
            origin: origin
        )
    }

    private func corsHeaders(origin: String?) -> [String: String] {
        var headers = [
            "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
            "Access-Control-Allow-Headers": "Authorization, Content-Type, X-NoteAI-Client, X-NoteAI-Protocol",
            "Access-Control-Allow-Private-Network": "true",
            "Cache-Control": "no-store",
            "Content-Type": "application/json",
        ]
        if let origin, isAllowedOrigin(origin) {
            headers["Access-Control-Allow-Origin"] = origin
            headers["Vary"] = "Origin"
        }
        return headers
    }

    private func eventStreamHeaders(origin: String?) -> [String: String] {
        var headers = corsHeaders(origin: origin)
        headers["Content-Type"] = "text/event-stream; charset=utf-8"
        headers["Cache-Control"] = "no-store, no-transform"
        return headers
    }
}

final class LocalCaptureHelperServer {
    private let router: LocalCaptureHelperRouter
    private let queue = DispatchQueue(label: "com.noteai.local-capture-helper")
    private var socketFileDescriptor: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let port: UInt16
    private(set) var listeningPort: UInt16?

    init(router: LocalCaptureHelperRouter, port: UInt16 = LocalCaptureHelperProtocol.defaultPort) {
        self.router = router
        self.port = port
    }

    func start() throws {
        guard socketFileDescriptor == -1 else { return }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LocalCaptureHelperServerError.socketCreationFailed(errno) }

        var reuse: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            let code = errno
            close(fd)
            throw LocalCaptureHelperServerError.socketOptionFailed(code)
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            close(fd)
            throw LocalCaptureHelperServerError.invalidLoopbackAddress
        }

        let bindResult = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let code = errno
            close(fd)
            throw LocalCaptureHelperServerError.bindFailed(code)
        }

        let listeningPort = try Self.boundPort(for: fd)

        guard listen(fd, SOMAXCONN) == 0 else {
            let code = errno
            close(fd)
            throw LocalCaptureHelperServerError.listenFailed(code)
        }

        let currentFlags = fcntl(fd, F_GETFL, 0)
        if currentFlags >= 0 {
            _ = fcntl(fd, F_SETFL, currentFlags | O_NONBLOCK)
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptPendingConnections()
        }
        source.setCancelHandler {
            close(fd)
        }
        socketFileDescriptor = fd
        self.listeningPort = listeningPort
        acceptSource = source
        source.resume()
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        socketFileDescriptor = -1
        listeningPort = nil
    }

    private func acceptPendingConnections() {
        while socketFileDescriptor >= 0 {
            let clientFD = accept(socketFileDescriptor, nil, nil)
            if clientFD < 0 {
                if errno == EWOULDBLOCK || errno == EAGAIN {
                    return
                }
                return
            }
            handle(clientFD: clientFD)
        }
    }

    private func handle(clientFD: Int32) {
        queue.async { [weak self] in
            guard let self,
                  let data = Self.readRequestData(from: clientFD),
                  let request = Self.parseRequest(data) else {
                close(clientFD)
                return
            }

            Task {
                let response = await self.router.route(request)
                Self.sendAll(Self.serialize(response), to: clientFD)
                close(clientFD)
            }
        }
    }

    private static func readRequestData(from fd: Int32) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        let maxRequestBytes = 1024 * 1024
        var emptyPollCount = 0

        while data.count < maxRequestBytes {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count > 0 {
                emptyPollCount = 0
                data.append(contentsOf: buffer.prefix(count))
                if hasCompleteRequest(data) {
                    return data
                }
                continue
            }

            if count == 0 {
                return data.isEmpty ? nil : data
            }

            if errno == EINTR {
                continue
            }

            if errno == EWOULDBLOCK || errno == EAGAIN {
                if hasCompleteRequest(data) {
                    return data
                }
                guard emptyPollCount < 100 else { return nil }
                emptyPollCount += 1
                usleep(10_000)
                continue
            }

            return nil
        }

        return nil
    }

    private static func hasCompleteRequest(_ data: Data) -> Bool {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: delimiter) else { return false }

        let headerData = data[..<headerRange.lowerBound]
        let headerText = String(decoding: headerData, as: UTF8.self)
        let contentLength = headerText
            .components(separatedBy: "\r\n")
            .compactMap { line -> Int? in
                guard line.lowercased().hasPrefix("content-length:") else { return nil }
                let value = line.split(separator: ":", maxSplits: 1).last?
                    .trimmingCharacters(in: .whitespaces)
                return value.flatMap(Int.init)
            }
            .first ?? 0

        let bodyByteCount = data.distance(from: headerRange.upperBound, to: data.endIndex)
        return bodyByteCount >= contentLength
    }

    private static func sendAll(_ data: Data, to fd: Int32) {
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let result = send(fd, baseAddress.advanced(by: sent), data.count - sent, 0)
                if result <= 0 { return }
                sent += result
            }
        }
    }

    private static func boundPort(for fd: Int32) throws -> UInt16 {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(fd, sockaddrPointer, &length)
            }
        }
        guard result == 0 else {
            throw LocalCaptureHelperServerError.boundPortLookupFailed(errno)
        }
        return UInt16(bigEndian: address.sin_port)
    }

    private static func parseRequest(_ data: Data) -> LocalCaptureHTTPRouterRequest? {
        guard let raw = String(data: data, encoding: .utf8),
              let headerEnd = raw.range(of: "\r\n\r\n") else {
            return nil
        }
        let headerText = String(raw[..<headerEnd.lowerBound])
        let bodyText = String(raw[headerEnd.upperBound...])
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<separator])
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let path = parts[1].split(separator: "?", maxSplits: 1).first.map(String.init) ?? parts[1]
        return LocalCaptureHTTPRouterRequest(
            method: parts[0],
            path: path,
            headers: headers,
            body: Data(bodyText.utf8)
        )
    }

    private static func serialize(_ response: LocalCaptureHTTPRouterResponse) -> Data {
        var headers = response.headers
        headers["Content-Length"] = "\(response.body.count)"
        headers["Connection"] = "close"

        let reason = reasonPhrase(for: response.statusCode)
        var raw = "HTTP/1.1 \(response.statusCode) \(reason)\r\n"
        for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
            raw += "\(key): \(value)\r\n"
        }
        raw += "\r\n"

        var data = Data(raw.utf8)
        data.append(response.body)
        return data
    }

    private static func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 409: return "Conflict"
        default: return "Error"
        }
    }
}

enum LocalCaptureHelperServerError: Error {
    case invalidPort
    case invalidLoopbackAddress
    case socketCreationFailed(Int32)
    case socketOptionFailed(Int32)
    case bindFailed(Int32)
    case boundPortLookupFailed(Int32)
    case listenFailed(Int32)
}
