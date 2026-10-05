//
//  ChatmiceTools.swift
//  Chatmice
//
//  Core tool abstractions and registry for MCP, Bash, and Skills.
//

import Foundation

enum ToolSourceID {
    static let fileTool = "builtin:file-tool"
    static let codeExecution = "builtin:code-execution"
    static let skills = "builtin:skills"
    static let computerUse = "builtin:computer-use"
    static let webSearch = "builtin:web-search"
    static func skill(_ identifier: String) -> String {
        "skill:\(identifier)"
    }

    static func skillIdentifier(from sourceID: String) -> String? {
        let prefix = "skill:"
        guard sourceID.hasPrefix(prefix) else { return nil }
        return String(sourceID.dropFirst(prefix.count))
    }
    static func mcpServer(_ name: String) -> String {
        "mcp:\(name)"
    }

    static func mcpServerName(from sourceID: String) -> String? {
        let prefix = "mcp:"
        guard sourceID.hasPrefix(prefix) else { return nil }
        return String(sourceID.dropFirst(prefix.count))
    }
}

enum ToolSourceKind: Sendable, Equatable {
    case fileTool
    case codeExecution
    case skills
    case computerUse
    case webSearch
    case mcp

    var systemImage: String {
        switch self {
        case .fileTool: return "folder"
        case .codeExecution: return "terminal"
        case .skills: return "books.vertical"
        case .computerUse: return "display"
        case .webSearch: return "globe"
        case .mcp: return "server.rack"
        }
    }
}

struct ToolSourceDescriptor: Identifiable, Sendable {
    let id: String
    let name: String
    let detail: String
    let kind: ToolSourceKind
    let isAvailable: Bool
}

enum ToolSourceCatalog {
    static func load(
        fileToolsEnabled: Bool? = nil,
        bashEnabled: Bool? = nil,
        skillsEnabled: Bool? = nil,
        computerEnabled: Bool? = nil
    ) async -> [ToolSourceDescriptor] {
        let defaults = UserDefaults.standard
        let resolvedFileToolsEnabled =
            fileToolsEnabled ?? (defaults.object(forKey: "chatmiceFileToolsEnabled") as? Bool ?? true)
        let resolvedBashEnabled =
            bashEnabled ?? (defaults.object(forKey: "chatmiceBashEnabled") as? Bool ?? true)
        let resolvedSkillsEnabled =
            skillsEnabled ?? (defaults.object(forKey: "chatmiceSkillsEnabled") as? Bool ?? true)
        let resolvedComputerEnabled =
            computerEnabled ?? (defaults.object(forKey: "chatmiceComputerEnabled") as? Bool ?? false)
        let webSearchSettings = WebSearchSettings.load()
        let serverJSON = defaults.string(forKey: "mcpServersJSON") ?? "[]"
        let configs = (try? JSONDecoder().decode([MCPServerConfig].self, from: Data(serverJSON.utf8))) ?? []
        let statuses = await MCPService.shared.statuses()
        let statusByName = Dictionary(uniqueKeysWithValues: statuses.map { ($0.name, $0) })
        let configsByName = Dictionary(configs.map { ($0.name, $0) }, uniquingKeysWith: { _, latest in latest })

        var sources = [
            ToolSourceDescriptor(
                id: ToolSourceID.fileTool,
                name: "File Tool",
                detail: resolvedFileToolsEnabled
                    ? "Files, directories, and read-only SQLite" : "Disabled globally",
                kind: .fileTool,
                isAvailable: resolvedFileToolsEnabled
            ),
            ToolSourceDescriptor(
                id: ToolSourceID.codeExecution,
                name: "Code Execution",
                detail: resolvedBashEnabled ? "Bash and sandboxed Python" : "Disabled globally",
                kind: .codeExecution,
                isAvailable: resolvedBashEnabled
            ),
            ToolSourceDescriptor(
                id: ToolSourceID.skills,
                name: "Skills",
                detail: resolvedSkillsEnabled ? "Installed skill instructions" : "Disabled globally",
                kind: .skills,
                isAvailable: resolvedSkillsEnabled
            ),
            ToolSourceDescriptor(
                id: ToolSourceID.computerUse,
                name: "Computer Use",
                detail: resolvedComputerEnabled ? "Screenshot, mouse, and keyboard" : "Disabled globally",
                kind: .computerUse,
                isAvailable: resolvedComputerEnabled
            ),
            ToolSourceDescriptor(
                id: ToolSourceID.webSearch,
                name: "Web Search",
                detail: webSearchSettings.enabled
                    ? "Search with \(webSearchSettings.defaultSearchProvider.name)"
                    : "Disabled globally",
                kind: .webSearch,
                isAvailable: webSearchSettings.enabled
            ),
        ]

        let serverNames = Set(configsByName.keys).union(statusByName.keys).sorted()
        sources.append(
            contentsOf: serverNames.map { name in
                let config = configsByName[name]
                let status = statusByName[name]
                let available = config?.enabled != false && status?.connected == true
                let detail: String
                if let status, status.connected {
                    detail = "\(status.toolCount) MCP tools"
                }
                else if config?.enabled == false {
                    detail = "Disabled globally"
                }
                else {
                    detail = status?.lastError ?? "Not connected"
                }
                return ToolSourceDescriptor(
                    id: ToolSourceID.mcpServer(name),
                    name: name,
                    detail: detail,
                    kind: .mcp,
                    isAvailable: available
                )
            }
        )
        return sources
    }
}

struct ToolSelectionState: Codable, Equatable {
    var defaultDisabledSourceIDs: Set<String> = []
    var chatOverrides: [String: Set<String>] = [:]
}

enum ToolSelectionStore {
    private static let storageKey = "chatmiceToolSelectionState"
    private static let lock = NSLock()

    static func disabledSourceIDs(for chatID: UUID?) -> Set<String> {
        lock.withLock {
            let state = load()
            guard let chatID, let override = state.chatOverrides[chatID.uuidString] else {
                return state.defaultDisabledSourceIDs
            }
            return override
        }
    }

    static func hasChatOverride(_ chatID: UUID) -> Bool {
        lock.withLock { load().chatOverrides[chatID.uuidString] != nil }
    }

    static func setSourceEnabled(_ enabled: Bool, sourceID: String, for chatID: UUID?) {
        setSourcesEnabled(enabled, sourceIDs: [sourceID], for: chatID)
    }

    static func setSourcesEnabled(_ enabled: Bool, sourceIDs: [String], for chatID: UUID?) {
        lock.withLock {
            var state = load()
            if let chatID {
                let key = chatID.uuidString
                var disabled = state.chatOverrides[key] ?? state.defaultDisabledSourceIDs
                for sourceID in sourceIDs {
                    update(&disabled, sourceID: sourceID, enabled: enabled)
                }
                state.chatOverrides[key] = disabled
            } else {
                for sourceID in sourceIDs {
                    update(&state.defaultDisabledSourceIDs, sourceID: sourceID, enabled: enabled)
                }
            }
            save(state)
        }
    }

    static func resetSourcesToDefaults(_ sourceIDs: [String], for chatID: UUID) {
        lock.withLock {
            var state = load()
            let key = chatID.uuidString
            var disabled = state.chatOverrides[key] ?? state.defaultDisabledSourceIDs
            for sourceID in sourceIDs {
                if state.defaultDisabledSourceIDs.contains(sourceID) {
                    disabled.insert(sourceID)
                } else {
                    disabled.remove(sourceID)
                }
            }
            state.chatOverrides[key] = disabled
            save(state)
        }
    }

    static func resetChatToDefaults(_ chatID: UUID) {
        lock.withLock {
            var state = load()
            state.chatOverrides[chatID.uuidString] = nil
            save(state)
        }
    }

    private static func update(_ disabled: inout Set<String>, sourceID: String, enabled: Bool) {
        if enabled {
            disabled.remove(sourceID)
        } else {
            disabled.insert(sourceID)
        }
    }

    private static func load() -> ToolSelectionState {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let state = try? JSONDecoder().decode(ToolSelectionState.self, from: data) else {
            return ToolSelectionState()
        }
        return state
    }

    private static func save(_ state: ToolSelectionState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

// MARK: - Tool Call

public struct ToolCall: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let arguments: String
    public let thoughtSignature: String?
    public var result: String?
    public var isError: Bool

    public init(
        id: String,
        name: String,
        arguments: String,
        thoughtSignature: String? = nil,
        result: String? = nil,
        isError: Bool = false
    ) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.thoughtSignature = thoughtSignature
        self.result = result
        self.isError = isError
    }

    public var argumentsJSON: [String: Any]? {
        guard let data = arguments.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return obj
    }
}

struct ToolActivityRecord: Codable, Hashable {
    static let openingTag = "<tool-activity>"
    static let closingTag = "</tool-activity>"

    let name: String
    let input: String
    let output: String
    let isError: Bool

    var marker: String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return Self.openingTag + data.base64EncodedString() + Self.closingTag
    }

    static func decode(markerLine: String) -> ToolActivityRecord? {
        let trimmed = markerLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(openingTag), trimmed.hasSuffix(closingTag) else { return nil }
        let payload =
            trimmed
            .dropFirst(openingTag.count)
            .dropLast(closingTag.count)
        guard let data = Data(base64Encoded: String(payload)) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    static func replacingMarkersForModel(in content: String) -> String {
        content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                guard let activity = decode(markerLine: String(line)) else { return String(line) }
                let status = activity.isError ? "failed" : "completed"
                let output = String(activity.output.prefix(2_000))
                return "[Tool \(activity.name) \(status): \(activity.input)]\n\(output)"
            }
            .joined(separator: "\n")
    }

    static func removingMarkers(in content: String) -> String {
        content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { decode(markerLine: String($0)) == nil }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - JSONSchema

public indirect enum JSONSchema: Codable, Hashable, Sendable {
    case object(properties: [String: JSONSchema], required: [String], additionalProperties: JSONSchema?)
    case array(items: JSONSchema?)
    case string
    case integer
    case number
    case boolean
    case raw(RawJSON)

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let props, let req, let addl):
            var obj: [String: AnyCodable] = ["type": .init("object")]
            if !props.isEmpty {
                obj["properties"] = AnyCodable(props.mapValues { $0.encodeable })
            }
            if !req.isEmpty { obj["required"] = AnyCodable(req) }
            if let addl { obj["additionalProperties"] = AnyCodable(addl.encodeable) }
            try c.encode(RawJSON(AnyCodable(obj)))
        case .array(let items):
            var obj: [String: AnyCodable] = ["type": .init("array")]
            if let items { obj["items"] = AnyCodable(items.encodeable) }
            try c.encode(RawJSON(AnyCodable(obj)))
        case .string: try c.encode(RawJSON(["type": "string"]))
        case .integer: try c.encode(RawJSON(["type": "integer"]))
        case .number: try c.encode(RawJSON(["type": "number"]))
        case .boolean: try c.encode(RawJSON(["type": "boolean"]))
        case .raw(let r): try c.encode(r)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let obj = try? c.decode([String: AnyCodable].self) {
            let type = obj["type"]?.value as? String
            switch type {
            case "object":
                let props = (obj["properties"]?.value as? [String: AnyCodable]) ?? [:]
                var parsed: [String: JSONSchema] = [:]
                var failed = false
                for (k, v) in props {
                    if let s = JSONSchema(anyCodable: v) {
                        parsed[k] = s
                    }
                    else {
                        failed = true
                    }
                }
                if !failed {
                    let req = (obj["required"]?.value as? [Any])?.compactMap { $0 as? String } ?? []
                    let addl: JSONSchema? = {
                        guard let a = obj["additionalProperties"] else { return nil }
                        if let b = a.value as? Bool { return b ? .raw(RawJSON(NSNull())) : .raw(RawJSON(false)) }
                        return JSONSchema(anyCodable: a)
                    }()
                    self = .object(properties: parsed, required: req, additionalProperties: addl)
                    return
                }
            case "array":
                self = .array(items: obj["items"].flatMap { JSONSchema(anyCodable: $0) })
                return
            case "string":
                self = .string
                return
            case "integer":
                self = .integer
                return
            case "number":
                self = .number
                return
            case "boolean":
                self = .boolean
                return
            default: break
            }
        }
        let any = try? AnyCodable(from: decoder)
        self = .raw(RawJSON(any ?? NSNull()))
    }

    init?(anyCodable: AnyCodable) {
        guard anyCodable.value is NSNull == false else { return nil }
        let v = anyCodable.value
        if let s = v as? String {
            switch s {
            case "object": self = .object(properties: [:], required: [], additionalProperties: nil)
            case "array": self = .array(items: nil)
            case "string": self = .string
            case "integer": self = .integer
            case "number": self = .number
            case "boolean": self = .boolean
            default: return nil
            }
            return
        }
        if let d = try? JSONSerialization.data(withJSONObject: v),
            let schema = try? JSONDecoder().decode(JSONSchema.self, from: d)
        {
            self = schema
            return
        }
        return nil
    }

    var encodeable: Any {
        switch self {
        case .raw(let r): return r.value
        default:
            let any = AnyCodable(self)
            return any.value
        }
    }

    private var wireValue: Any {
        switch self {
        case .object(let properties, let required, let additionalProperties):
            var value: [String: Any] = ["type": "object"]
            if !properties.isEmpty {
                value["properties"] = properties.mapValues { $0.wireValue }
            }
            if !required.isEmpty {
                value["required"] = required
            }
            if let additionalProperties {
                value["additionalProperties"] = additionalProperties.wireValue
            }
            return value
        case .array(let items):
            var value: [String: Any] = ["type": "array"]
            if let items {
                value["items"] = items.wireValue
            }
            return value
        case .string:
            return ["type": "string"]
        case .integer:
            return ["type": "integer"]
        case .number:
            return ["type": "number"]
        case .boolean:
            return ["type": "boolean"]
        case .raw(let raw):
            return raw.value.value
        }
    }

    public var openAIWireDict: [String: Any] {
        wireValue as? [String: Any] ?? ["type": "object"]
    }
}

// MARK: - RawJSON & AnyCodable

public struct RawJSON: Codable, Hashable, Sendable {
    public let value: AnyCodable
    public init(_ any: Any) { self.value = AnyCodable(any) }
    public init(_ anyCodable: AnyCodable) { self.value = anyCodable }
    public init(from decoder: Decoder) throws {
        self.value = try AnyCodable(from: decoder)
    }
    public func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
    }
}

public struct AnyCodable: Codable, Hashable, @unchecked Sendable {
    public let value: Any
    public init(_ value: Any) { self.value = value }
    public init<T: Codable>(_ value: T) { self.value = value }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self.value = NSNull()
        }
        else if let b = try? c.decode(Bool.self) {
            self.value = b
        }
        else if let i = try? c.decode(Int.self) {
            self.value = i
        }
        else if let d = try? c.decode(Double.self) {
            self.value = d
        }
        else if let s = try? c.decode(String.self) {
            self.value = s
        }
        else if let arr = try? c.decode([AnyCodable].self) {
            self.value = arr.map(\.value)
        }
        else if let dict = try? c.decode([String: AnyCodable].self) {
            self.value = dict.mapValues(\.value)
        }
        else {
            self.value = NSNull()
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case is NSNull: try c.encodeNil()
        case let b as Bool: try c.encode(b)
        case let i as Int: try c.encode(i)
        case let d as Double: try c.encode(d)
        case let s as String: try c.encode(s)
        case let arr as [Any]: try c.encode(arr.map { AnyCodable($0) })
        case let dict as [String: Any]: try c.encode(dict.mapValues { AnyCodable($0) })
        default: try c.encodeNil()
        }
    }

    public static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        String(describing: lhs.value) == String(describing: rhs.value)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(String(describing: value))
    }
}

// MARK: - Tool Definition & Context

public struct ToolDefinition: Codable, Hashable, Sendable {
    public let name: String
    public let description: String
    public let parameters: JSONSchema

    public init(
        name: String,
        description: String,
        parameters: JSONSchema = .object(properties: [:], required: [], additionalProperties: nil)
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

enum AgentActivitySignal: Equatable, Sendable {
    case waitingForModel
    case awaitingApproval(tool: String, detail: String)
    case runningTool(tool: String, detail: String)
    case processingToolResult(tool: String)
}

protocol AgentActivityReporting: AnyObject {
    func setActivityHandler(_ handler: (@Sendable (AgentActivitySignal) -> Void)?)
}

public typealias ConfirmationRequest = @Sendable (String) async -> Bool

public struct ToolContext: Sendable {
    public var depth: Int
    public var cwd: URL
    public var ask: ConfirmationRequest

    public init(
        depth: Int = 0,
        cwd: URL = FileManager.default.temporaryDirectory,
        ask: @escaping ConfirmationRequest = { _ in true }
    ) {
        self.depth = depth
        self.cwd = cwd
        self.ask = ask
    }
}

public protocol AgentTool: Sendable {
    var definition: ToolDefinition { get }
    func call(arguments: String, context: ToolContext) async throws -> String
}

public enum ToolError: Error, LocalizedError, Sendable {
    case unknownTool(String)
    case invalidArguments(String)
    case confirmationDenied(String)
    case executionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unknownTool(let s): return "Unknown tool: \(s)"
        case .invalidArguments(let s): return "Invalid arguments: \(s)"
        case .confirmationDenied(let s): return "Execution denied by user: \(s)"
        case .executionFailed(let s): return "Execution failed: \(s)"
        }
    }
}

// MARK: - ToolBox

public actor ToolBox {
    private var tools: [String: any AgentTool] = [:]

    public init() {}

    public func register(_ tool: any AgentTool) {
        tools[tool.definition.name] = tool
    }

    public func unregister(name: String) {
        tools[name] = nil
    }

    public func get(name: String) -> (any AgentTool)? {
        tools[name]
    }

    public func definitions() -> [ToolDefinition] {
        Array(tools.values.map(\.definition)).sorted { $0.name < $1.name }
    }

    public func execute(name: String, arguments: String, context: ToolContext) async throws -> String {
        guard let tool = tools[name] else {
            throw ToolError.unknownTool(name)
        }
        return try await tool.call(arguments: arguments, context: context)
    }
}
