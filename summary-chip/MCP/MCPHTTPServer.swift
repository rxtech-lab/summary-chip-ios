#if os(macOS)
import Foundation
import MCP
import Network
import os

enum MCPServerError: LocalizedError {
    case portInUse(Int)
    case listenerFailed(String)
    case badRequest(String)

    var errorDescription: String? {
        switch self {
        case .portInUse(let port): "Port \(port) is already in use. Choose another port."
        case .listenerFailed(let message): "The MCP server could not start: \(message)"
        case .badRequest(let message): message
        }
    }
}

/// Streamable HTTP MCP server on the loopback interface (Network.framework). Each client session gets
/// its own `Server` + `StatefulHTTPServerTransport`, keyed by `MCP-Session-Id`. Every request must
/// carry `Authorization: Bearer <token>`, so other apps on the Mac can't use the signed-in account.
actor MCPHTTPServer {
    static let path = "/mcp"
    private static let maxBodyBytes = 8 * 1024 * 1024
    /// Clients that never send DELETE leave sessions behind; the oldest are dropped past this.
    private static let maxSessions = 32
    private static let log = Logger(subsystem: "com.rxlab.summary-chip", category: "MCP")

    private struct Session {
        let server: MCP.Server
        let transport: StatefulHTTPServerTransport
    }

    private let token: String
    private let tools: ChippyMCPTools
    private let version: String
    private var listener: NWListener?
    private var port = 0
    private var sessions: [String: Session] = [:]
    private var sessionOrder: [String] = []

    init(token: String, tools: ChippyMCPTools, version: String) {
        self.token = token
        self.tools = tools
        self.version = version
    }

    func start(port: Int) async throws {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)), port > 0 else {
            throw MCPServerError.listenerFailed("Invalid port \(port)")
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredInterfaceType = .loopback
        parameters.acceptLocalOnly = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: nwPort)
        } catch {
            throw MCPServerError.listenerFailed(error.localizedDescription)
        }
        self.listener = listener
        self.port = port

        let ready = AsyncThrowingStream<Void, Error>.makeStream()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.continuation.yield(())
                ready.continuation.finish()
            case .failed(let error):
                if case .posix(let code) = error, code == .EADDRINUSE {
                    ready.continuation.finish(throwing: MCPServerError.portInUse(port))
                } else {
                    ready.continuation.finish(throwing: MCPServerError.listenerFailed(error.localizedDescription))
                }
            case .cancelled:
                ready.continuation.finish()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            Task { await self.handle(connection) }
        }
        listener.start(queue: .global(qos: .userInitiated))
        do {
            for try await _ in ready.stream { break }
        } catch {
            listener.cancel()
            self.listener = nil
            throw error
        }
        Self.log.info("MCP server listening on 127.0.0.1:\(port, privacy: .public)")
    }

    func stop() async {
        listener?.cancel()
        listener = nil
        for session in sessions.values { await session.server.stop() }
        sessions.removeAll()
        sessionOrder.removeAll()
    }

    // MARK: Routing

    private func handle(_ connection: NWConnection) async {
        connection.start(queue: .global(qos: .userInitiated))
        do {
            let request = try await readRequest(from: connection)
            try await route(request, connection: connection)
        } catch {
            try? await writeError(status: 400, message: error.localizedDescription, to: connection)
        }
    }

    private func route(_ request: MCP.HTTPRequest, connection: NWConnection) async throws {
        let path = request.path?.split(separator: "?").first.map(String.init) ?? ""
        guard path == Self.path || path == Self.path + "/" else {
            try await writeError(status: 404, message: "Not found. The MCP endpoint is \(Self.path).", to: connection)
            return
        }
        guard isAuthorized(request) else {
            Self.log.notice("Rejected an MCP request without a valid access token")
            try await writeError(
                status: 401,
                message: "Missing or invalid access token. Copy the connection settings from Chippy → Settings → MCP Server.",
                to: connection
            )
            return
        }

        let method = request.method.uppercased()
        if let id = request.header(HTTPHeaderName.sessionID), let session = sessions[id] {
            let response = await session.transport.handleRequest(request)
            try await write(response, to: connection)
            if method == "DELETE" { await removeSession(id) }
            return
        }
        // Only an initialize request can open a session.
        if method == "POST", let body = request.body, Self.isInitialize(body) {
            try await openSession(with: request, connection: connection)
            return
        }
        let status = request.header(HTTPHeaderName.sessionID) == nil ? 400 : 404
        try await writeError(status: status, message: "Missing or unknown MCP-Session-Id. Initialize a new session.", to: connection)
    }

    private func isAuthorized(_ request: MCP.HTTPRequest) -> Bool {
        guard let header = request.header(HTTPHeaderName.authorization) else { return false }
        let prefix = "bearer "
        guard header.count > prefix.count, header.lowercased().hasPrefix(prefix) else { return false }
        let presented = Array(header.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces).utf8)
        let expected = Array(token.utf8)
        // Constant-time comparison.
        guard presented.count == expected.count else { return false }
        return zip(presented, expected).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private func openSession(with request: MCP.HTTPRequest, connection: NWConnection) async throws {
        let transport = StatefulHTTPServerTransport(validationPipeline: StandardValidationPipeline(validators: [
            OriginValidator.localhost(port: port),
            AcceptHeaderValidator(mode: .sseRequired),
            ContentTypeValidator(),
            ProtocolVersionValidator(),
            SessionValidator(),
        ]))
        let server = MCP.Server(
            name: "chippy",
            version: version,
            title: "Chippy",
            instructions: ChippyMCPTools.instructions,
            capabilities: .init(tools: .init(listChanged: false))
        )
        let tools = tools
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: ChippyMCPTools.tools)
        }
        await server.withMethodHandler(CallTool.self) { params in
            await tools.call(name: params.name, arguments: params.arguments)
        }
        try await server.start(transport: transport)

        let response = await transport.handleRequest(request)
        if let id = response.headers[HTTPHeaderName.sessionID] {
            sessions[id] = Session(server: server, transport: transport)
            sessionOrder.append(id)
            while sessionOrder.count > Self.maxSessions {
                await removeSession(sessionOrder[0])
            }
        } else {
            // Validation failed; nothing to keep.
            await server.stop()
        }
        try await write(response, to: connection)
    }

    private func removeSession(_ id: String) async {
        sessionOrder.removeAll { $0 == id }
        if let session = sessions.removeValue(forKey: id) { await session.server.stop() }
    }

    private static func isInitialize(_ body: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["method"] as? String == "initialize"
    }

    // MARK: Responses

    private func write(_ response: MCP.HTTPResponse, to connection: NWConnection) async throws {
        if case .stream(let stream, let headers) = response {
            var headers = headers
            headers["Transfer-Encoding"] = "chunked"
            headers["Connection"] = "keep-alive"
            try await send(Self.head(status: 200, headers: headers), on: connection)
            do {
                for try await chunk in stream { try await send(Self.chunk(chunk), on: connection) }
                try await send(Self.chunk(Data()), on: connection)
            } catch {
                // The client went away or the stream failed; just close.
            }
            connection.cancel()
            return
        }
        let body = response.bodyData ?? Data()
        var headers = response.headers
        headers["Content-Length"] = "\(body.count)"
        headers["Connection"] = "close"
        try await send(Self.head(status: response.statusCode, headers: headers) + body, on: connection)
        connection.cancel()
    }

    private func writeError(status: Int, message: String, to connection: NWConnection) async throws {
        let body = (try? JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "error": ["code": -32600, "message": message],
            "id": NSNull(),
        ] as [String: Any])) ?? Data()
        let headers = ["Content-Type": "application/json", "Content-Length": "\(body.count)", "Connection": "close"]
        try await send(Self.head(status: status, headers: headers) + body, on: connection)
        connection.cancel()
    }

    private static func head(status: Int, headers: [String: String]) -> Data {
        var head = "HTTP/1.1 \(status) \(reason(status))\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        return Data(head.utf8)
    }

    private static func chunk(_ data: Data) -> Data {
        var out = Data(String(format: "%X\r\n", data.count).utf8)
        out.append(data)
        out.append(Data("\r\n".utf8))
        return out
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 406: "Not Acceptable"
        case 413: "Payload Too Large"
        case 415: "Unsupported Media Type"
        default: "Status"
        }
    }

    // MARK: Request parsing

    private func readRequest(from connection: NWConnection) async throws -> MCP.HTTPRequest {
        let separator = Data("\r\n\r\n".utf8)
        var buffer = Data()
        while buffer.range(of: separator) == nil {
            let chunk = try await receive(from: connection)
            guard !chunk.isEmpty else { break }
            buffer.append(chunk)
            if buffer.count > 64 * 1024, buffer.range(of: separator) == nil {
                throw MCPServerError.badRequest("Request headers are too large")
            }
        }
        guard let headerEnd = buffer.range(of: separator),
              let head = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            throw MCPServerError.badRequest("Malformed HTTP request")
        }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2 else { throw MCPServerError.badRequest("Malformed request line") }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = headers.first { $0.key.lowercased() == "content-length" }.flatMap { Int($0.value) } ?? 0
        guard length <= Self.maxBodyBytes else { throw MCPServerError.badRequest("Request body is too large") }
        var body = Data(buffer[headerEnd.upperBound...])
        while body.count < length {
            let chunk = try await receive(from: connection)
            guard !chunk.isEmpty else { break }
            body.append(chunk)
        }
        if body.count > length { body = body.prefix(length) }
        return MCP.HTTPRequest(
            method: String(requestLine[0]),
            headers: headers,
            body: body.isEmpty ? nil : body,
            path: String(requestLine[1])
        )
    }

    private func receive(from connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: data ?? Data()) }
            }
        }
    }

    private func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
}
#endif
