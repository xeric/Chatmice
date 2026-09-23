//
//  MCPService.swift
//  Chatmice / macai
//
//  Foundation-based Model Context Protocol (MCP) Client for stdio and HTTP servers.
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

    public init(name: String, kind: Kind = .stdio, command: String? = nil, args: [String] = [], env: [String: String] = [:], url: String? = nil, enabled: Bool = true) {
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

    private final class ConnectedServer {
        let config: MCPServerConfig
        let process: Process?
        let inHandle: FileHandle?
        let outHandle: FileHandle?
        var tools: [MCPToolInfo] = []
        var connected: Bool = false
        var lastError: String?

        init(config: MCPServerConfig, process: Process?, inHandle: FileHandle?, outHandle: FileHandle?) {
            self.config = config
            self.process = process
            self.inHandle = inHandle
            self.outHandle = outHandle
        }
    }

    private var servers: [String: ConnectedServer] = [:]

    public init() {}

    public func sync(servers configs: [MCPServerConfig]) async {
        for (name, s) in servers where !configs.contains(where: { $0.name == name && $0.enabled }) {
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
        s.process?.terminate()
        servers[name] = nil
    }

    public func statuses() -> [MCPStatus] {
        servers.values.map {
            MCPStatus(name: $0.config.name, connected: $0.connected, toolCount: $0.tools.count, lastError: $0.lastError)
        }.sorted { $0.name < $1.name }
    }

    public func allTools() -> [any AgentTool] {
        var result: [any AgentTool] = []
        for (serverName, s) in servers where s.connected {
            for t in s.tools {
                let toolName = "\(serverName).\(t.name)"
                let def = ToolDefinition(name: toolName, description: t.description, parameters: t.schema)
                result.append(MCPProxyTool(definition: def, serverName: serverName, rawToolName: t.name, service: self))
            }
        }
        return result
    }

    func callTool(server: String, tool: String, arguments: [String: Any]) async throws -> String {
        guard let s = servers[server], s.connected, let inH = s.inHandle, let outH = s.outHandle else {
            throw ToolError.executionFailed("MCP 服务器 \(server) 未连接")
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
        let resp = try await rpc(req, inH: inH, outH: outH)
        guard let result = resp["result"] as? [String: Any] else {
            if let err = resp["error"] as? [String: Any], let msg = err["message"] as? String {
                throw ToolError.executionFailed(msg)
            }
            throw ToolError.executionFailed("MCP 返回格式错误")
        }
        if let content = result["content"] as? [[String: Any]] {
            let texts = content.compactMap { $0["text"] as? String }
            return texts.joined(separator: "\n")
        }
        return String(describing: result)
    }

    private func connect(_ cfg: MCPServerConfig) async {
        guard cfg.kind == .stdio, let cmd = cfg.command else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        let fullCmd = ([cmd] + cfg.args).joined(separator: " ")
        p.arguments = ["-lc", fullCmd]
        var env = ProcessInfo.processInfo.environment
        for (k, v) in cfg.env { env[k] = v }
        p.environment = env

        let inPipe = Pipe()
        let outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice

        do {
            try p.run()
            let s = ConnectedServer(config: cfg, process: p, inHandle: inPipe.fileHandleForWriting, outHandle: outPipe.fileHandleForReading)
            servers[cfg.name] = s

            // Handshake
            let initReq: [String: Any] = [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": [
                    "protocolVersion": "2025-11-25",
                    "capabilities": [String: Any](),
                    "clientInfo": ["name": "Chatmice", "version": "1.0.0"]
                ]
            ]
            _ = try await rpc(initReq, inH: inPipe.fileHandleForWriting, outH: outPipe.fileHandleForReading)

            // Initialized notification
            let notif = try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0",
                "method": "notifications/initialized"
            ])
            inPipe.fileHandleForWriting.write(notif + Data("\n".utf8))

            // List tools
            let listReq: [String: Any] = [
                "jsonrpc": "2.0",
                "id": 2,
                "method": "tools/list",
                "params": [String: Any]()
            ]
            let listResp = try await rpc(listReq, inH: inPipe.fileHandleForWriting, outH: outPipe.fileHandleForReading)
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
            let s = ConnectedServer(config: cfg, process: nil, inHandle: nil, outHandle: nil)
            s.lastError = error.localizedDescription
            servers[cfg.name] = s
        }
    }

    private func rpc(_ req: [String: Any], inH: FileHandle, outH: FileHandle, timeout: Double = 10) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: req)
        inH.write(data + Data("\n".utf8))

        return try await withThrowingTaskGroup(of: [String: Any].self) { group in
            group.addTask {
                var buffer = Data()
                while true {
                    let chunk = outH.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    if let lineEnd = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                        let lineData = buffer.subdata(in: 0..<lineEnd)
                        if let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                            return obj
                        }
                    }
                }
                throw ToolError.executionFailed("MCP 连接断开")
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw ToolError.executionFailed("MCP RPC 超时")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
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
