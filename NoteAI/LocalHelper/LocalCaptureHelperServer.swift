import AppKit
import Foundation
import Network

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
}

final class LocalCaptureHelperServer {
    private let router: LocalCaptureHelperRouter
    private let queue = DispatchQueue(label: "com.noteai.local-capture-helper")
    private var listener: NWListener?
    private let port: UInt16

    init(router: LocalCaptureHelperRouter, port: UInt16 = LocalCaptureHelperProtocol.defaultPort) {
        self.router = router
        self.port = port
    }

    func start() throws {
        guard listener == nil else { return }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw LocalCaptureHelperServerError.invalidPort
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        if let loopback = IPv4Address("127.0.0.1") {
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(loopback), port: nwPort)
        }

        let listener = try NWListener(using: parameters, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self, let data, let request = Self.parseRequest(data) else {
                connection.cancel()
                return
            }

            Task {
                let response = await self.router.route(request)
                connection.send(
                    content: Self.serialize(response),
                    completion: .contentProcessed { _ in
                        connection.cancel()
                    }
                )
            }
        }
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
}
