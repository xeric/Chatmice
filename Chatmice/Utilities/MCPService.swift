//
//  MCPService.swift
//  Chatmice
//
//  Foundation-based Model Context Protocol (MCP) Client for stdio and HTTP/SSE servers.
//  Zero external dependencies.
//

import Foundation

public struct MCPServerConfig: Identifiable, Codable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var kind: Kind
    public var command: String?
    public var args: [String]
    public var env: [String: String]
    public var url: String?
    public var enabled: Bool

    public enum Kind: String, Codable, Sendable {
        case stdio
        case http
    }

    public init(
        name: String,
        kind: Kind = .stdio,
        command: String? = nil,
        args: [String] = [],
        env: [String: String] = [:],
        url: String? = nil,
        enabled: Bool = true
    ) {
        self.name = name
        self.kind = kind
        self.command = command
        self.args = args
        self.env = env
        self.url = url
        self.enabled = enabled
    }
}

public struct MCPStatus: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let connected: Bool
    public let toolCount: Int
    public let lastError: String?

    public init(name: String, connected: Bool, toolCount: Int, lastError: String? = nil) {
        self.name = name
        self.connected = connected
        self.toolCount = toolCount
        self.lastError = lastError
    }
}

public actor MCPService {
    public static let shared = MCPService()

    private struct MCPToolInfo: Sendable {
        let name: String
        let description: String
        let schema: JSONSchema
    }

    private enum Transport {
        case stdio(process: Process, inHandle: FileHandle, outHandle: FileHandle, errPipe: Pipe)
        case http(transport: HTTPMCPTransport)
    }

    private final class ConnectedServer {
        let config: MCPServerConfig
        var transport: Transport?
        var tools: [MCPToolInfo] = []
        var connected: Bool = false
        var lastError: String?

        init(config: MCPServerConfig, transport: Transport? = nil) {
            self.config = config
            self.transport = transport
        }
    }

    private var servers: [String: ConnectedServer] = [:]

    public init() {}

    public func sync(servers configs: [MCPServerConfig]) async {
        for (name, _) in servers where !configs.contains(where: { $0.name == name && $0.enabled }) {
            disconnect(name: name)
        }
        for cfg in configs where cfg.enabled {
            if servers[cfg.name] == nil {
                await connect(cfg)
            }
        }
    }

    public func disconnect(name: String) {
        guard let s = servers[name] else { return }
        switch s.transport {
        case .stdio(let p, _, _, _):
            p.terminate()
        case .http(let httpTransport):
            httpTransport.disconnect()
        case .none:
            break
        }
        servers[name] = nil
    }

    public func statuses() -> [MCPStatus] {
        servers.values.map {
            MCPStatus(name: $0.config.name, connected: $0.connected, toolCount: $0.tools.count, lastError: $0.lastError)
        }.sorted { $0.name < $1.name }
    }

    public func allTools(excludingServers: Set<String> = []) -> [any AgentTool] {
        var result: [any AgentTool] = []
        for (serverName, s) in servers where s.connected && !excludingServers.contains(serverName) {
            for t in s.tools {
                let toolName = "\(serverName).\(t.name)"
                let def = ToolDefinition(name: toolName, description: t.description, parameters: t.schema)
                result.append(MCPProxyTool(definition: def, serverName: serverName, rawToolName: t.name, service: self))
            }
        }
        return result
    }

    func callTool(server: String, tool: String, arguments: [String: Any]) async throws -> String {
        guard let s = servers[server], s.connected, let transport = s.transport else {
            throw ToolError.executionFailed("MCP server \(server) is not connected")
        }
        let req: [String: Any] = [
            "jsonrpc": "2.0",
            "id": Int.random(in: 1000...9999),
            "method": "tools/call",
            "params": [
                "name": tool,
                "arguments": arguments
            ]
        ]
        let resp: [String: Any]
        switch transport {
        case .stdio(_, let inH, let outH, let errPipe):
            resp = try await rpcStdio(req, inH: inH, outH: outH, errPipe: errPipe)
        case .http(let http):
            resp = try await http.rpc(req)
        }
        guard let result = resp["result"] as? [String: Any] else {
            if let err = resp["error"] as? [String: Any], let msg = err["message"] as? String {
                throw ToolError.executionFailed(msg)
            }
            throw ToolError.executionFailed("MCP invalid response format")
        }
        if let content = result["content"] as? [[String: Any]] {
            let texts = content.compactMap { $0["text"] as? String }
            return texts.joined(separator: "\n")
        }
        return String(describing: result)
    }

    private func connect(_ cfg: MCPServerConfig) async {
        switch cfg.kind {
        case .stdio:
            await connectStdio(cfg)
        case .http:
            await connectHTTP(cfg)
        }
    }

    // MARK: - Stdio Connection
    private func connectStdio(_ cfg: MCPServerConfig) async {
        guard let cmd = cfg.command, !cmd.isEmpty else {
            let s = ConnectedServer(config: cfg, transport: nil)
            s.lastError = "Command is required for stdio"
            servers[cfg.name] = s
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        let fullCmd = ([cmd] + cfg.args).joined(separator: " ")
        p.arguments = ["-lc", fullCmd]

        var env = ProcessInfo.processInfo.environment
        let userHome = FileManager.default.homeDirectoryForCurrentUser.path
        let commonPaths = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "\(userHome)/.volta/bin",
            "\(userHome)/.cargo/bin",
            "\(userHome)/.nvm/current/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        let currentPath = env["PATH"] ?? ""
        env["PATH"] = (commonPaths + [currentPath]).joined(separator: ":")
        for (k, v) in cfg.env { env[k] = v }
        p.environment = env

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe

        do {
            try p.run()
            let inH = inPipe.fileHandleForWriting
            let outH = outPipe.fileHandleForReading
            let transport = Transport.stdio(process: p, inHandle: inH, outHandle: outH, errPipe: errPipe)
            let s = ConnectedServer(config: cfg, transport: transport)
            servers[cfg.name] = s

            // Handshake
            let initReq: [String: Any] = [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": [
                    "protocolVersion": "2024-11-05",
                    "capabilities": [String: Any](),
                    "clientInfo": ["name": "Chatmice", "version": "1.0.0"]
                ]
            ]
            _ = try await rpcStdio(initReq, inH: inH, outH: outH, errPipe: errPipe)

            // Initialized notification
            let notif = try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0",
                "method": "notifications/initialized"
            ])
            inH.write(notif + Data("\n".utf8))

            // List tools
            let listReq: [String: Any] = [
                "jsonrpc": "2.0",
                "id": 2,
                "method": "tools/list",
                "params": [String: Any]()
            ]
            let listResp = try await rpcStdio(listReq, inH: inH, outH: outH, errPipe: errPipe)
            if let result = listResp["result"] as? [String: Any],
               let rawTools = result["tools"] as? [[String: Any]] {
                for rt in rawTools {
                    guard let tName = rt["name"] as? String else { continue }
                    let desc = rt["description"] as? String ?? ""
                    let rawSchema = rt["inputSchema"] as? [String: Any] ?? [:]
                    let schema = (try? JSONSchema(anyCodable: AnyCodable(rawSchema))) ?? .object(properties: [:], required: [], additionalProperties: nil)
                    s.tools.append(MCPToolInfo(name: tName, description: desc, schema: schema))
                }
            }
            s.connected = true
            s.lastError = nil
        } catch {
            p.terminate()
            let errData = errPipe.fileHandleForReading.availableData
            let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let errorMsg = errStr.isEmpty ? error.localizedDescription : errStr
            let s = ConnectedServer(config: cfg, transport: nil)
            s.lastError = errorMsg
            servers[cfg.name] = s
        }
    }

    private func rpcStdio(_ req: [String: Any], inH: FileHandle, outH: FileHandle, errPipe: Pipe? = nil, timeout: Double = 15) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: req)
        inH.write(data + Data("\n".utf8))

        return try await withThrowingTaskGroup(of: [String: Any].self) { group in
            group.addTask {
                var buffer = Data()
                while true {
                    let chunk = outH.availableData
                    if chunk.isEmpty {
                        if let errPipe = errPipe {
                            let errData = errPipe.fileHandleForReading.availableData
                            if let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !errStr.isEmpty {
                                throw ToolError.executionFailed(errStr)
                            }
                        }
                        break
                    }
                    buffer.append(chunk)
                    if let lineEnd = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                        let lineData = buffer.subdata(in: 0..<lineEnd)
                        if let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                            return obj
                        }
                    }
                }
                throw ToolError.executionFailed("MCP connection closed")
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw ToolError.executionFailed("MCP RPC timed out")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
    // MARK: - HTTP / SSE Connection
    private func connectHTTP(_ cfg: MCPServerConfig) async {
        guard let urlString = cfg.url?.trimmingCharacters(in: .whitespacesAndNewlines),
              !urlString.isEmpty,
              let url = URL(string: urlString) else {
            let s = ConnectedServer(config: cfg, transport: nil)
            s.lastError = "Invalid HTTP/SSE URL"
            servers[cfg.name] = s
            return
        }

        let transport = HTTPMCPTransport(url: url, headers: cfg.env)
        let s = ConnectedServer(config: cfg, transport: .http(transport: transport))
        servers[cfg.name] = s

        do {
            try await transport.connect(timeout: 15)

            // Handshake
            let initReq: [String: Any] = [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": [
                    "protocolVersion": "2024-11-05",
                    "capabilities": [String: Any](),
                    "clientInfo": ["name": "Chatmice", "version": "1.0.0"]
                ]
            ]
            _ = try await transport.rpc(initReq, timeout: 15)

            // Initialized notification
            let notif: [String: Any] = [
                "jsonrpc": "2.0",
                "method": "notifications/initialized"
            ]
            try await transport.notify(notif)

            // List tools
            let listReq: [String: Any] = [
                "jsonrpc": "2.0",
                "id": 2,
                "method": "tools/list",
                "params": [String: Any]()
            ]
            let listResp = try await transport.rpc(listReq, timeout: 15)
            if let result = listResp["result"] as? [String: Any],
               let rawTools = result["tools"] as? [[String: Any]] {
                for rt in rawTools {
                    guard let tName = rt["name"] as? String else { continue }
                    let desc = rt["description"] as? String ?? ""
                    let rawSchema = rt["inputSchema"] as? [String: Any] ?? [:]
                    let schema = (try? JSONSchema(anyCodable: AnyCodable(rawSchema))) ?? .object(properties: [:], required: [], additionalProperties: nil)
                    s.tools.append(MCPToolInfo(name: tName, description: desc, schema: schema))
                }
            }
            s.connected = true
            s.lastError = nil
        } catch {
            transport.disconnect()
            s.connected = false
            s.lastError = error.localizedDescription
        }
    }
}

// MARK: - HTTP / SSE Transport Implementation
private final class HTTPMCPTransport: @unchecked Sendable {
    let initialURL: URL
    let headers: [String: String]
    private(set) var postURL: URL?
    private var sseTask: Task<Void, Never>?
    private let lock = NSLock()
    private var pendingContinuations: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private let session: URLSession

    init(url: URL, headers: [String: String] = [:]) {
        self.initialURL = url
        self.headers = headers
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }

    func connect(timeout: Double = 15) async throws {
        var request = URLRequest(url: initialURL)
        request.httpMethod = "GET"
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        for (k, v) in headers {
            request.setValue(v, forHTTPHeaderField: k)
        }

        do {
            let (bytes, response) = try await session.bytes(for: request)
            if let http = response as? HTTPURLResponse {
                let ct = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
                if http.statusCode == 200 && ct.contains("text/event-stream") {
                    try await startSSEStream(bytes: bytes, sseURL: initialURL, timeout: timeout)
                    return
                }
            }

            // If not SSE, try appending /sse if missing
            if !initialURL.path.hasSuffix("/sse") {
                let sseCandidate = initialURL.appendingPathComponent("sse")
                var sseReq = URLRequest(url: sseCandidate)
                sseReq.httpMethod = "GET"
                sseReq.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
                sseReq.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

                if let (subBytes, subResp) = try? await session.bytes(for: sseReq),
                   let subHttp = subResp as? HTTPURLResponse,
                   subHttp.statusCode == 200,
                   (subHttp.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true) {
                    try await startSSEStream(bytes: subBytes, sseURL: sseCandidate, timeout: timeout)
                    return
                }
            }

            // Fallback: direct HTTP POST (Streamable HTTP / Stateless MCP)
            self.postURL = initialURL
        } catch {
            // If GET fails completely, treat initialURL as direct HTTP POST endpoint
            self.postURL = initialURL
        }
    }

    private func startSSEStream(bytes: URLSession.AsyncBytes, sseURL: URL, timeout: Double) async throws {
        self.sseTask = Task { [weak self] in
            guard let self = self else { return }
            var currentEvent: String?
            var currentData = ""
            do {
                for try await line in bytes.lines {
                    if Task.isCancelled { break }
                    if line.isEmpty {
                        if let event = currentEvent {
                            self.handleSSEEvent(event: event, data: currentData, sseURL: sseURL)
                        } else if !currentData.isEmpty {
                            self.handleSSEEvent(event: "message", data: currentData, sseURL: sseURL)
                        }
                        currentEvent = nil
                        currentData = ""
                        continue
                    }
                    if line.hasPrefix(":") { continue }
                    if line.hasPrefix("event:") {
                        currentEvent = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                    } else if line.hasPrefix("data:") {
                        let piece = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        currentData = currentData.isEmpty ? piece : (currentData + "\n" + piece)
                    }
                }
            } catch {
                self.lock.lock()
                for (_, cont) in self.pendingContinuations {
                    cont.resume(throwing: error)
                }
                self.pendingContinuations.removeAll()
                self.lock.unlock()
            }
        }

        // Wait for postURL from SSE endpoint event
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            lock.lock()
            let url = self.postURL
            lock.unlock()
            if url != nil {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        // If no endpoint event, fall back to sseURL
        lock.lock()
        self.postURL = sseURL
        lock.unlock()
    }

    private func handleSSEEvent(event: String, data: String, sseURL: URL) {
        let trimmed = data.trimmingCharacters(in: .whitespacesAndNewlines)
        if event == "endpoint" {
            lock.lock()
            if let rel = URL(string: trimmed, relativeTo: sseURL) {
                self.postURL = rel.absoluteURL
            } else {
                self.postURL = URL(string: trimmed)
            }
            lock.unlock()
        } else if event == "message" || event == "message_delta" || event.isEmpty {
            guard let jsonData = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                return
            }
            if let id = json["id"] as? Int {
                lock.lock()
                let cont = pendingContinuations.removeValue(forKey: id)
                lock.unlock()
                cont?.resume(returning: json)
            }
        }
    }

    func rpc(_ req: [String: Any], timeout: Double = 30) async throws -> [String: Any] {
        guard let targetURL = postURL else {
            throw ToolError.executionFailed("MCP HTTP endpoint not ready")
        }
        let id = req["id"] as? Int ?? Int.random(in: 1000...9999)
        var postReq = URLRequest(url: targetURL)
        postReq.httpMethod = "POST"
        postReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        postReq.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        for (k, v) in headers {
            postReq.setValue(v, forHTTPHeaderField: k)
        }
        postReq.httpBody = try JSONSerialization.data(withJSONObject: req)

        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            pendingContinuations[id] = continuation
            lock.unlock()

            Task {
                do {
                    let (data, response) = try await session.data(for: postReq)
                    let http = response as? HTTPURLResponse
                    let status = http?.statusCode ?? 0

                    // 1. Direct JSON-RPC in HTTP response body
                    if (200...299).contains(status), !data.isEmpty,
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       (json["result"] != nil || json["error"] != nil) {
                        self.lock.lock()
                        let removed = self.pendingContinuations.removeValue(forKey: id)
                        self.lock.unlock()
                        removed?.resume(returning: json)
                        return
                    }

                    // 2. HTTP error response
                    if status >= 400 {
                        let errStr = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
                        self.lock.lock()
                        let removed = self.pendingContinuations.removeValue(forKey: id)
                        self.lock.unlock()
                        removed?.resume(throwing: ToolError.executionFailed("MCP HTTP \(status): \(errStr)"))
                        return
                    }

                    // 3. For 202 Accepted (standard SSE), the response will be pushed asynchronously over the SSE stream!
                } catch {
                    self.lock.lock()
                    let removed = self.pendingContinuations.removeValue(forKey: id)
                    self.lock.unlock()
                    removed?.resume(throwing: error)
                }
            }

            // Timeout watchdog
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.lock.lock()
                let removed = self.pendingContinuations.removeValue(forKey: id)
                self.lock.unlock()
                removed?.resume(throwing: ToolError.executionFailed("MCP RPC timed out"))
            }
        }
    }

    func notify(_ req: [String: Any]) async throws {
        guard let targetURL = postURL else { return }
        var postReq = URLRequest(url: targetURL)
        postReq.httpMethod = "POST"
        postReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        postReq.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        for (k, v) in headers {
            postReq.setValue(v, forHTTPHeaderField: k)
        }
        postReq.httpBody = try JSONSerialization.data(withJSONObject: req)
        _ = try? await session.data(for: postReq)
    }

    func disconnect() {
        sseTask?.cancel()
        sseTask = nil
        lock.lock()
        for (_, cont) in pendingContinuations {
            cont.resume(throwing: ToolError.executionFailed("Connection closed"))
        }
        pendingContinuations.removeAll()
        lock.unlock()
    }
}

private struct MCPProxyTool: AgentTool {
    let definition: ToolDefinition
    let serverName: String
    let rawToolName: String
    let service: MCPService

    func call(arguments: String, context: ToolContext) async throws -> String {
        let argsObj = (try? JSONSerialization.jsonObject(with: arguments.data(using: .utf8) ?? Data())) as? [String: Any] ?? [:]
        return try await service.callTool(server: serverName, tool: rawToolName, arguments: argsObj)
    }
}
