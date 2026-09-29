//
//  ChatmiceEngine.swift
//  Chatmice
//
//  APIService Proxy that orchestrates multi-turn Agent tool calling (MCP, Bash, Skills).
//  Seamlessly integrates into macai without modifying MessageManager or ChatView.
//

import AppKit
import Foundation
private actor BashApprovalSession {
    static let shared = BashApprovalSession()
    private var approved = false

    func isApproved() -> Bool { approved }
    func approve() { approved = true }
}


class ChatmiceEngine: APIService, AgentActivityReporting {
    let name: String
    let baseURL: URL
    private let baseService: APIService
    private let config: APIServiceConfiguration
    private let chatID: UUID?
    private var activeTask: Task<Void, Never>?
    private let activityHandlerLock = NSLock()
    private var activityHandler: (@Sendable (AgentActivitySignal) -> Void)?

    static let toolsEnabledKey = "chatmiceToolsEnabled"
    static let bashEnabledKey = "chatmiceBashEnabled"
    static let skillsEnabledKey = "chatmiceSkillsEnabled"
    static let computerEnabledKey = "chatmiceComputerEnabled"
    static let bashApprovalModeKey = "chatmiceBashApprovalMode"
    static let legacyBashAutoConfirmKey = "chatmiceBashAutoConfirm"

    init(baseService: APIService, config: APIServiceConfiguration, chatID: UUID? = nil) {
        self.baseService = baseService
        self.config = config
        self.chatID = chatID
        self.name = config.name
        self.baseURL = config.apiUrl
    }

    func setActivityHandler(_ handler: (@Sendable (AgentActivitySignal) -> Void)?) {
        activityHandlerLock.lock()
        activityHandler = handler
        activityHandlerLock.unlock()
    }

    private func reportActivity(_ signal: AgentActivitySignal) {
        activityHandlerLock.lock()
        let handler = activityHandler
        activityHandlerLock.unlock()
        handler?(signal)
    }

    func sendMessage(
        _ requestMessages: [[String: String]],
        temperature: Float,
        completion: @escaping (Result<String, APIError>) -> Void
    ) {
        Task {
            do {
                let stream = try await sendMessageStream(requestMessages, temperature: temperature)
                var accumulated = ""
                for try await chunk in stream {
                    accumulated += chunk
                }
                DispatchQueue.main.async {
                    completion(.success(accumulated))
                }
            } catch let err as APIError {
                DispatchQueue.main.async { completion(.failure(err)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(.requestFailed(error))) }
            }
        }
    }

    func sendMessageStream(
        _ requestMessages: [[String: String]],
        temperature: Float
    ) async throws -> AsyncThrowingStream<String, Error> {
        let toolsEnabled = (UserDefaults.standard.object(forKey: Self.toolsEnabledKey) as? Bool) ?? true

        // If tools disabled, route directly to base service
        guard toolsEnabled else {
            return try await baseService.sendMessageStream(requestMessages, temperature: temperature)
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.runToolLoop(
                        requestMessages: requestMessages,
                        temperature: temperature,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            self.activeTask = task
            continuation.onTermination = { _ in
                task.cancel()
                self.baseService.cancelCurrentRequest()
            }
        }
    }

    func fetchModels() async throws -> [AIModel] {
        return try await baseService.fetchModels()
    }

    func cancelCurrentRequest() {
        activeTask?.cancel()
        activeTask = nil
        baseService.cancelCurrentRequest()
    }
    @MainActor
    private static func requestBashApproval(prompt: String, allowTitle: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Run Bash Command?"
        alert.informativeText = prompt
        alert.addButton(withTitle: allowTitle)
        alert.addButton(withTitle: "Deny")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Agent Tool Loop Engine
    private func runToolLoop(
        requestMessages: [[String: String]],
        temperature: Float,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        let box = ToolBox()
        let defaults = UserDefaults.standard
        let disabledSources = ToolSelectionStore.disabledSourceIDs(for: chatID)
        let fileToolsEnabled = (defaults.object(forKey: "chatmiceFileToolsEnabled") as? Bool ?? true)
            && !disabledSources.contains(ToolSourceID.fileTool)
        let codeExecutionEnabled = (defaults.object(forKey: Self.bashEnabledKey) as? Bool ?? true)
            && !disabledSources.contains(ToolSourceID.codeExecution)
        let skillsEnabled = (defaults.object(forKey: Self.skillsEnabledKey) as? Bool ?? true)
            && !disabledSources.contains(ToolSourceID.skills)
        let computerEnabled = (defaults.object(forKey: Self.computerEnabledKey) as? Bool ?? false)
            && !disabledSources.contains(ToolSourceID.computerUse)
        let webSearchSettings = WebSearchSettings.load()
        let searchMode = chatID.map {
            SearchModeStore.mode(for: $0)
        } ?? .off
        let webSearchEnabled = webSearchSettings.enabled && searchMode == .web
            && !disabledSources.contains(ToolSourceID.webSearch)
        let disabledMCPServers = Set(disabledSources.compactMap(ToolSourceID.mcpServerName(from:)))
        let approvalMode = BashApprovalMode(rawValue: defaults.string(forKey: Self.bashApprovalModeKey) ?? "")
            ?? (defaults.bool(forKey: Self.legacyBashAutoConfirmKey) ? .alwaysAllow : .alwaysAsk)
        let approvalSession = BashApprovalSession.shared

        if fileToolsEnabled {
            await box.register(ReadFileTool())
            await box.register(WriteFileTool())
            await box.register(EditFileTool())
            await box.register(ListDirectoryTool())
            await box.register(SQLQueryTool())
        }
        if codeExecutionEnabled {
            await box.register(BashTool())
            await box.register(PythonInterpreterTool())
        }
        let skillStore = SkillStore()
        if skillsEnabled {
            await box.register(SkillTool(catalog: skillStore))
        }
        if computerEnabled {
            await box.register(ScreenshotTool())
            await box.register(MouseClickTool())
            await box.register(TypeTextTool())
            await box.register(PressKeyTool())
        }
        if webSearchEnabled {
            await box.register(WebSearchTool())
            await box.register(WebFetchTool())
        }
        for tool in await MCPService.shared.allTools(excludingServers: disabledMCPServers) {
            await box.register(tool)
        }

        let registeredDefs = await box.definitions()
        guard !registeredDefs.isEmpty else {
            let stream = try await baseService.sendMessageStream(requestMessages, temperature: temperature)
            for try await chunk in stream {
                continuation.yield(chunk)
            }
            return
        }
        var usedWireNames = Set<String>()
        var registeredNameByWireName: [String: String] = [:]
        let defs = registeredDefs.map { definition in
            let wireName = makeWireToolName(definition.name, used: &usedWireNames)
            registeredNameByWireName[wireName] = definition.name
            return ToolDefinition(
                name: wireName,
                description: definition.description,
                parameters: definition.parameters
            )
        }

        var conversationHistory = requestMessages.map {
            AgentMessage.text(role: $0["role"] ?? "user", content: $0["content"] ?? "")
        }

        var agentInstructions = [
            "When using tools, briefly tell the user what you are about to verify before each tool-call round. "
                + "Keep it to one concise sentence and report only user-facing progress, never hidden chain-of-thought."
        ]

        if codeExecutionEnabled {
            agentInstructions.append(
                "You can use Code Execution for shell commands and sandboxed Python computation. "
                    + "Prefer File Tool for direct file operations and Python for data processing or calculations."
            )
        }
        if skillsEnabled {
            let section = await skillStore.systemPromptSection()
            if !section.isEmpty {
                agentInstructions.append(section)
            }
        }

        if !agentInstructions.isEmpty {
            let combined = agentInstructions.joined(separator: "\n\n")
            if let idx = conversationHistory.firstIndex(where: { $0.isSystemText }) {
                conversationHistory[idx].appendText("\n\n" + combined)
            } else {
                conversationHistory.insert(.text(role: "system", content: combined), at: 0)
            }
        }
        let context = ToolContext(
            depth: 0,
            cwd: FileManager.default.homeDirectoryForCurrentUser,
            ask: { prompt in
                switch approvalMode {
                case .alwaysAllow:
                    return true
                case .currentSession:
                    if await approvalSession.isApproved() {
                        return true
                    }
                    self.reportActivity(.awaitingApproval(tool: "bash", detail: prompt))
                    let approved = await Self.requestBashApproval(
                        prompt: prompt,
                        allowTitle: "Allow for This Session"
                    )
                    if approved {
                        await approvalSession.approve()
                    }
                    return approved
                case .alwaysAsk:
                    self.reportActivity(.awaitingApproval(tool: "bash", detail: prompt))
                    return await Self.requestBashApproval(
                        prompt: prompt,
                        allowTitle: "Allow Once"
                    )
                }
            }
        )

        var rounds = 0
        let maxRounds = 10

        while rounds < maxRounds {
            rounds += 1
            if Task.isCancelled { break }
            if rounds == 1 {
                reportActivity(.waitingForModel)
            }

            let rawResult = try await executeTurn(
                messages: conversationHistory,
                tools: defs,
                temperature: temperature
            )

            if rawResult.toolCalls.isEmpty {
                if !rawResult.text.isEmpty {
                    continuation.yield(rawResult.text)
                }
                break
            }

            if !rawResult.text.isEmpty {
                continuation.yield(rawResult.text + "\n")
            }

            conversationHistory.append(.assistant(text: rawResult.text, toolCalls: rawResult.toolCalls))
            var results: [ToolExecutionResult] = []

            for call in rawResult.toolCalls {
                if Task.isCancelled { break }
                let registeredName = registeredNameByWireName[call.name] ?? call.name
                let input = call.argumentsJSON?["command"] as? String ?? call.arguments
                reportActivity(.runningTool(tool: registeredName, detail: input))

                let result: ToolExecutionResult
                do {
                    let output = try await box.execute(name: registeredName, arguments: call.arguments, context: context)
                    result = ToolExecutionResult(call: call, output: output, isError: false)
                } catch {
                    result = ToolExecutionResult(
                        call: call,
                        output: "Error: \(error.localizedDescription)",
                        isError: true
                    )
                }

                results.append(result)
                let activity = ToolActivityRecord(
                    name: registeredName,
                    input: input,
                    output: result.output,
                    isError: result.isError
                )
                continuation.yield("\n\(activity.marker)\n")
                reportActivity(.processingToolResult(tool: registeredName))
            }

            if !results.isEmpty {
                conversationHistory.append(.toolResults(results))
            }
        }
    }

    private struct ToolExecutionResult {
        let call: ToolCall
        let output: String
        let isError: Bool
    }

    private enum AgentMessage {
        case text(role: String, content: String)
        case assistant(text: String, toolCalls: [ToolCall])
        case toolResults([ToolExecutionResult])

        var isSystemText: Bool {
            if case .text(let role, _) = self {
                return role == "system"
            }
            return false
        }

        mutating func appendText(_ suffix: String) {
            guard case .text(let role, let content) = self else { return }
            self = .text(role: role, content: content + suffix)
        }
    }
    private func makeWireToolName(_ original: String, used: inout Set<String>) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        let validInitial = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_")
        var normalized = String(original.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(String(scalar)) : "_"
        })

        if normalized.isEmpty {
            normalized = "_tool"
        } else if let first = normalized.unicodeScalars.first, !validInitial.contains(first) {
            normalized = "_" + normalized
        }

        var hash: UInt32 = 2_166_136_261
        for byte in original.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }

        let needsSuffix = normalized != original || normalized.count > 64 || used.contains(normalized)
        var candidate = normalized
        if needsSuffix {
            let suffix = String(format: "_%08x", hash)
            candidate = String(normalized.prefix(64 - suffix.count)) + suffix
        }

        var collisionIndex = 2
        while used.contains(candidate) {
            let suffix = "_\(collisionIndex)"
            candidate = String(normalized.prefix(64 - suffix.count)) + suffix
            collisionIndex += 1
        }

        used.insert(candidate)
        return candidate
    }

    private struct TurnResult {
        var text: String
        var toolCalls: [ToolCall]
    }

    private var serviceType: String {
        if let c = config as? APIServiceConfig { return c.type.lowercased() }
        if let e = config as? APIServiceEntity { return (e.type ?? "").lowercased() }
        return "chatgpt"
    }

    private var nativeSearchEnabled: Bool {
        guard let chatID else { return false }
        return SearchModeStore.mode(for: chatID) == .native
    }

    private var effectiveKey: String {
        if !config.apiKey.isEmpty { return config.apiKey }
        if let entity = config as? APIServiceEntity,
           let id = entity.tokenIdentifier ?? entity.id?.uuidString,
           let token = try? TokenManager.getToken(for: id), !token.isEmpty {
            return token
        }
        return ProcessInfo.processInfo.environment["LOCAL_SAP_AI_CORE_PROXY_KEY"] ?? ""
    }

    private func executeTurn(
        messages: [AgentMessage],
        tools: [ToolDefinition],
        temperature: Float
    ) async throws -> TurnResult {
        let type = serviceType
        if type == "gemini" {
            return try await executeTurnGemini(messages: messages, tools: tools, temperature: temperature)
        } else if type == "claude" {
            return try await executeTurnClaude(messages: messages, tools: tools, temperature: temperature)
        } else {
            return try await executeTurnOpenAI(messages: messages, tools: tools, temperature: temperature)
        }
    }

    // MARK: - OpenAI / ChatGPT Execution
    private func executeTurnOpenAI(
        messages: [AgentMessage],
        tools: [ToolDefinition],
        temperature: Float
    ) async throws -> TurnResult {
        var targetURL = baseURL
        if !targetURL.absoluteString.hasSuffix("/chat/completions") {
            targetURL = targetURL.appendingPathComponent("chat/completions")
        }
        var req = URLRequest(url: targetURL)
        req.httpMethod = "POST"
        let key = effectiveKey
        if !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let toolsPayload = tools.map { t -> [String: Any] in
            [
                "type": "function",
                "function": [
                    "name": t.name,
                    "description": t.description,
                    "parameters": t.parameters.openAIWireDict
                ]
            ]
        }

        let wireMessages = messages.flatMap { message -> [[String: Any]] in
            switch message {
            case .text(let role, let content):
                return [["role": role, "content": content]]
            case .assistant(let text, let calls):
                return [[
                    "role": "assistant",
                    "content": text.isEmpty ? NSNull() : text,
                    "tool_calls": calls.map { call in
                        [
                            "id": call.id,
                            "type": "function",
                            "function": ["name": call.name, "arguments": call.arguments]
                        ] as [String: Any]
                    }
                ]]
            case .toolResults(let results):
                return results.map { result in
                    [
                        "role": "tool",
                        "tool_call_id": result.call.id,
                        "content": result.output
                    ]
                }
            }
        }

        var body: [String: Any] = [
            "model": config.model,
            "messages": wireMessages,
            "temperature": temperature
        ]
        if !toolsPayload.isEmpty {
            body["tools"] = toolsPayload
        }
        if nativeSearchEnabled {
            if serviceType == "openrouter" {
                body["plugins"] = [["id": "web", "engine": "native"]]
            } else if ["openai", "openai-responses"].contains(serviceType) {
                body["web_search_options"] = [String: Any]()
            }
        }

        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let errStr = String(data: data, encoding: .utf8) ?? "HTTP Error"
            throw APIError.serverError(errStr)
        }

        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let msg = first["message"] as? [String: Any] else {
            throw APIError.decodingFailed("Failed to parse response")
        }

        var text = msg["content"] as? String ?? ""
        var calls: [ToolCall] = []

        if let rawCalls = msg["tool_calls"] as? [[String: Any]] {
            for rc in rawCalls {
                guard let id = rc["id"] as? String,
                      let fn = rc["function"] as? [String: Any],
                      let fName = fn["name"] as? String else { continue }
                let args = fn["arguments"] as? String ?? "{}"
                calls.append(ToolCall(id: id, name: fName, arguments: args))
            }
        }

        return TurnResult(text: text, toolCalls: calls)
    }

    // MARK: - Gemini Execution
    private func executeTurnGemini(
        messages: [AgentMessage],
        tools: [ToolDefinition],
        temperature: Float
    ) async throws -> TurnResult {
        var targetURL = baseURL
        let urlStr = targetURL.absoluteString
        if !urlStr.contains(":generateContent") {
            if !urlStr.contains("/models/") {
                targetURL = targetURL.appendingPathComponent("models/\(config.model):generateContent")
            } else {
                targetURL = targetURL.appendingPathComponent(":generateContent")
            }
        }
        var req = URLRequest(url: targetURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = effectiveKey
        if !key.isEmpty {
            req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        let systemText = messages.compactMap { message -> String? in
            guard case .text(let role, let content) = message, role == "system" else { return nil }
            return content
        }.joined(separator: "\n\n")
        let contents = messages.compactMap { message -> [String: Any]? in
            switch message {
            case .text(let role, let content):
                guard role != "system", !content.isEmpty else { return nil }
                return [
                    "role": role == "assistant" ? "model" : "user",
                    "parts": [["text": content]]
                ]
            case .assistant(let text, let calls):
                var parts: [[String: Any]] = []
                if !text.isEmpty {
                    parts.append(["text": text])
                }
                parts.append(contentsOf: calls.map { call -> [String: Any] in
                    var part: [String: Any] = [
                        "functionCall": [
                            "name": call.name,
                            "args": call.argumentsJSON ?? [:]
                        ]
                    ]
                    if let signature = call.thoughtSignature {
                        part["thoughtSignature"] = signature
                    }
                    return part
                })
                return parts.isEmpty ? nil : ["role": "model", "parts": parts]
            case .toolResults(let results):
                let parts = results.map { result -> [String: Any] in
                    let response: [String: Any] = result.isError
                        ? ["error": result.output]
                        : ["result": result.output]
                    return [
                        "functionResponse": [
                            "name": result.call.name,
                            "response": response
                        ]
                    ]
                }
                return parts.isEmpty ? nil : ["role": "user", "parts": parts]
            }
        }

        var geminiTools: [[String: Any]] = []
        if !tools.isEmpty {
            geminiTools.append([
                "functionDeclarations": tools.map { t -> [String: Any] in
                    [
                        "name": t.name,
                        "description": t.description,
                        "parameters": t.parameters.openAIWireDict
                    ]
                }
            ])
        }
        if nativeSearchEnabled {
            geminiTools.append(["googleSearch": [String: Any]()])
        }

        var body: [String: Any] = [
            "contents": contents,
            "tools": geminiTools,
            "generationConfig": [
                "temperature": temperature
            ]
        ]
        if !systemText.isEmpty {
            body["systemInstruction"] = [
                "role": "user",
                "parts": [["text": systemText]]
            ]
        }

        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let errStr = String(data: data, encoding: .utf8) ?? "HTTP Error"
            throw APIError.serverError(errStr)
        }

        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.decodingFailed("Failed to parse Gemini response")
        }

        var text = ""
        var calls: [ToolCall] = []

        if let candidates = obj["candidates"] as? [[String: Any]],
           let first = candidates.first,
           let content = first["content"] as? [String: Any],
           let parts = content["parts"] as? [[String: Any]] {
            for part in parts {
                if let t = part["text"] as? String {
                    text += t
                }
                if let fnCall = part["functionCall"] as? [String: Any],
                   let fName = fnCall["name"] as? String {
                    let argsObj = fnCall["args"] as? [String: Any] ?? [:]
                    let argsData = (try? JSONSerialization.data(withJSONObject: argsObj)) ?? Data()
                    let argsStr = String(data: argsData, encoding: .utf8) ?? "{}"
                    calls.append(ToolCall(
                        id: UUID().uuidString,
                        name: fName,
                        arguments: argsStr,
                        thoughtSignature: part["thoughtSignature"] as? String
                    ))
                }
            }
        }

        return TurnResult(text: text, toolCalls: calls)
    }

    // MARK: - Claude Execution
    private func executeTurnClaude(
        messages: [AgentMessage],
        tools: [ToolDefinition],
        temperature: Float
    ) async throws -> TurnResult {
        var targetURL = baseURL
        if !targetURL.absoluteString.hasSuffix("/messages") {
            targetURL = targetURL.appendingPathComponent("messages")
        }
        var req = URLRequest(url: targetURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let key = effectiveKey
        if !key.isEmpty {
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let resolvedModel = await ClaudeModelResolver.shared.resolve(
            config.model,
            baseURL: baseURL,
            apiKey: key,
            session: URLSession.shared
        )

        let systemText = messages.compactMap { message -> String? in
            guard case .text(let role, let content) = message, role == "system" else { return nil }
            return content
        }.joined(separator: "\n\n")
        let claudeMsgs = messages.compactMap { message -> [String: Any]? in
            switch message {
            case .text(let role, let content):
                guard role != "system", !content.isEmpty else { return nil }
                return [
                    "role": role == "assistant" ? "assistant" : "user",
                    "content": content
                ]
            case .assistant(let text, let calls):
                var blocks: [[String: Any]] = []
                if !text.isEmpty {
                    blocks.append(["type": "text", "text": text])
                }
                blocks.append(contentsOf: calls.map { call in
                    [
                        "type": "tool_use",
                        "id": call.id,
                        "name": call.name,
                        "input": call.argumentsJSON ?? [:]
                    ]
                })
                return blocks.isEmpty ? nil : ["role": "assistant", "content": blocks]
            case .toolResults(let results):
                let blocks = results.map { result in
                    [
                        "type": "tool_result",
                        "tool_use_id": result.call.id,
                        "content": result.output,
                        "is_error": result.isError
                    ] as [String: Any]
                }
                return blocks.isEmpty ? nil : ["role": "user", "content": blocks]
            }
        }

        var claudeTools = tools.map { t -> [String: Any] in
            [
                "name": t.name,
                "description": t.description,
                "input_schema": t.parameters.openAIWireDict
            ]
        }
        if nativeSearchEnabled {
            claudeTools.append([
                "type": "web_search_20250305",
                "name": "web_search"
            ])
        }

        var body: [String: Any] = [
            "model": resolvedModel,
            "max_tokens": 4096,
            "messages": claudeMsgs
        ]
        if !claudeTools.isEmpty {
            body["tools"] = claudeTools
        }
        ClaudeRequestCompatibility.addTemperature(temperature, model: config.model, to: &body)
        if !systemText.isEmpty {
            body["system"] = systemText
        }

        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw APIError.serverError(
                ClaudeRequestCompatibility.errorMessage(statusCode: statusCode, data: data)
            )
        }

        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.decodingFailed("Failed to parse Claude response")
        }

        var text = ""
        var calls: [ToolCall] = []

        if let contentList = obj["content"] as? [[String: Any]] {
            for item in contentList {
                if let type = item["type"] as? String {
                    if type == "text", let t = item["text"] as? String {
                        text += t
                    } else if type == "tool_use", let fName = item["name"] as? String {
                        let id = item["id"] as? String ?? UUID().uuidString
                        let inputObj = item["input"] as? [String: Any] ?? [:]
                        let inputData = (try? JSONSerialization.data(withJSONObject: inputObj)) ?? Data()
                        let inputStr = String(data: inputData, encoding: .utf8) ?? "{}"
                        calls.append(ToolCall(id: id, name: fName, arguments: inputStr))
                    }
                }
            }
        }

        return TurnResult(text: text, toolCalls: calls)
    }
}
