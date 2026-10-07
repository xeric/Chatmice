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

private enum BashApprovalDecision {
    case deny
    case allowOnce
    case allowSession
}

@MainActor
private final class BashApprovalResponder: NSObject {
    @objc func allowOnce() {
        NSApp.stopModal(withCode: .alertFirstButtonReturn)
    }

    @objc func allowSession() {
        NSApp.stopModal(withCode: .alertSecondButtonReturn)
    }

    @objc func deny() {
        NSApp.stopModal(withCode: .alertThirdButtonReturn)
    }
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
            }
            catch let err as APIError {
                DispatchQueue.main.async { completion(.failure(err)) }
            }
            catch {
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
                }
                catch {
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
    private static func requestBashApproval(prompt: String) -> BashApprovalDecision {
        let alert = NSAlert()
        alert.messageText = "Run Bash Command?"
        alert.informativeText = prompt
        alert.alertStyle = .warning

        alert.addButton(withTitle: "Allow Once")

        let sessionButton = alert.addButton(withTitle: "Allow in This Session")
        sessionButton.bezelColor = .systemPurple
        sessionButton.contentTintColor = .white

        let denyButton = alert.addButton(withTitle: "Deny")

        let responder = BashApprovalResponder()
        alert.buttons[0].target = responder
        alert.buttons[0].action = #selector(BashApprovalResponder.allowOnce)
        alert.buttons[1].target = responder
        alert.buttons[1].action = #selector(BashApprovalResponder.allowSession)
        alert.buttons[2].target = responder
        alert.buttons[2].action = #selector(BashApprovalResponder.deny)

        let parentWindow =
            NSApp.keyWindow ?? NSApp.mainWindow
            ?? NSApp.windows.first(where: { $0 !== alert.window && $0.isVisible })
        let alertWindow = alert.window
        alertWindow.contentView?.layoutSubtreeIfNeeded()
        denyButton.keyEquivalent = "\u{1b}"
        alertWindow.makeKeyAndOrderFront(nil)
        if let parentWindow {
            let parentFrame = parentWindow.frame
            let alertFrame = alertWindow.frame
            alertWindow.setFrameOrigin(
                NSPoint(
                    x: parentFrame.midX - alertFrame.width / 2,
                    y: parentFrame.midY - alertFrame.height / 2
                )
            )
        }

        let response = NSApp.runModal(for: alertWindow)
        alertWindow.orderOut(nil)
        switch response {
        case .alertFirstButtonReturn:
            return .allowOnce
        case .alertSecondButtonReturn:
            return .allowSession
        default:
            return .deny
        }
    }

    // MARK: - Agent Tool Loop Engine
    private func runToolLoop(
        requestMessages: [[String: String]],
        temperature: Float,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        // Perplexity Sonar models provide search natively but reject OpenAI function tools.
        // Send the normal chat request directly instead of entering Chatmice's tool loop.
        if isSonarModel {
            let stream = try await baseService.sendMessageStream(requestMessages, temperature: temperature)
            for try await chunk in stream {
                continuation.yield(chunk)
            }
            return
        }
        let box = ToolBox()
        let defaults = UserDefaults.standard
        let disabledSources = ToolSelectionStore.disabledSourceIDs(for: chatID)
        let fileToolsEnabled =
            (defaults.object(forKey: "chatmiceFileToolsEnabled") as? Bool ?? true)
            && !disabledSources.contains(ToolSourceID.fileTool)
        let codeExecutionEnabled =
            (defaults.object(forKey: Self.bashEnabledKey) as? Bool ?? true)
            && !disabledSources.contains(ToolSourceID.codeExecution)
        let skillsEnabled =
            (defaults.object(forKey: Self.skillsEnabledKey) as? Bool ?? true)
            && !disabledSources.contains(ToolSourceID.skills)
        let computerEnabled =
            (defaults.object(forKey: Self.computerEnabledKey) as? Bool ?? false)
            && !disabledSources.contains(ToolSourceID.computerUse)
        let webSearchSettings = WebSearchSettings.load()
        let searchMode =
            chatID.map {
                SearchModeStore.mode(for: $0)
            } ?? .off
        let webSearchEnabled =
            webSearchSettings.enabled && searchMode == .web
            && !disabledSources.contains(ToolSourceID.webSearch)
        let disabledMCPServers = Set(disabledSources.compactMap(ToolSourceID.mcpServerName(from:)))
        let approvalMode =
            BashApprovalMode(rawValue: defaults.string(forKey: Self.bashApprovalModeKey) ?? "")
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
        let disabledSkillIdentifiers = Set(disabledSources.compactMap(ToolSourceID.skillIdentifier(from:)))
        let skillStore: SkillStore
        if skillsEnabled {
            let globallyEnabledIdentifiers = Set(
                await SkillStore().allSkills().compactMap { skill in
                    let identifier = skill.directory.lastPathComponent
                    return SkillEnablementStore.isEnabled(identifier) ? identifier : nil
                }
            )
            skillStore = SkillStore(
                allowedIdentifiers: globallyEnabledIdentifiers.subtracting(disabledSkillIdentifiers)
            )
            if !globallyEnabledIdentifiers.subtracting(disabledSkillIdentifiers).isEmpty {
                await box.register(SkillTool(catalog: skillStore))
            }
        }
        else {
            skillStore = SkillStore(allowedIdentifiers: [])
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
            }
            else {
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
                case .currentSession, .alwaysAsk:
                    if await approvalSession.isApproved() {
                        return true
                    }
                    self.reportActivity(.awaitingApproval(tool: "bash", detail: prompt))
                    switch await Self.requestBashApproval(prompt: prompt) {
                    case .deny:
                        return false
                    case .allowOnce:
                        return true
                    case .allowSession:
                        await approvalSession.approve()
                        return true
                    }
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
                temperature: temperature,
                onText: { continuation.yield($0) }
            )

            if rawResult.toolCalls.isEmpty {
                if !rawResult.text.isEmpty && !rawResult.textWasStreamed {
                    continuation.yield(rawResult.text)
                }
                break
            }

            if !rawResult.text.isEmpty {
                if rawResult.textWasStreamed {
                    continuation.yield("\n")
                }
                else {
                    continuation.yield(rawResult.text + "\n")
                }
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
                    let output = try await box.execute(
                        name: registeredName,
                        arguments: call.arguments,
                        context: context
                    )
                    result = ToolExecutionResult(call: call, output: output, isError: false)
                }
                catch {
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
                ).compactedForPersistence()
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
        var normalized = String(
            original.unicodeScalars.map { scalar in
                allowed.contains(scalar) ? Character(String(scalar)) : "_"
            }
        )

        if normalized.isEmpty {
            normalized = "_tool"
        }
        else if let first = normalized.unicodeScalars.first, !validInitial.contains(first) {
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
        var textWasStreamed = false
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

    private var isSonarModel: Bool {
        config.model.lowercased().contains("sonar")
    }

    private var effectiveKey: String {
        if !config.apiKey.isEmpty { return config.apiKey }
        if let entity = config as? APIServiceEntity,
            let id = entity.tokenIdentifier ?? entity.id?.uuidString,
            let token = try? TokenManager.getToken(for: id), !token.isEmpty
        {
            return token
        }
        return ProcessInfo.processInfo.environment["LOCAL_SAP_AI_CORE_PROXY_KEY"] ?? ""
    }

    private func executeTurn(
        messages: [AgentMessage],
        tools: [ToolDefinition],
        temperature: Float,
        onText: @escaping (String) -> Void
    ) async throws -> TurnResult {
        let type = serviceType
        if type == "gemini" {
            return try await executeTurnGemini(
                messages: messages,
                tools: tools,
                temperature: temperature,
                onText: onText
            )
        }
        else if type == "claude" {
            return try await executeTurnClaude(
                messages: messages,
                tools: tools,
                temperature: temperature,
                onText: onText
            )
        }
        else {
            return try await executeTurnOpenAI(
                messages: messages,
                tools: tools,
                temperature: temperature,
                onText: onText
            )
        }
    }

    // MARK: - OpenAI / ChatGPT Execution
    private func executeTurnOpenAI(
        messages: [AgentMessage],
        tools: [ToolDefinition],
        temperature: Float,
        onText: @escaping (String) -> Void
    ) async throws -> TurnResult {
        var targetURL = baseURL
        if !targetURL.absoluteString.hasSuffix("/chat/completions") {
            targetURL = targetURL.appendingPathComponent("chat/completions")
        }
        var req = URLRequest(url: targetURL)
        req.httpMethod = "POST"
        let key = effectiveKey
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let toolsPayload = tools.map { tool -> [String: Any] in
            [
                "type": "function",
                "function": [
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": tool.parameters.openAIWireDict,
                ],
            ]
        }
        let wireMessages = messages.flatMap { message -> [[String: Any]] in
            switch message {
            case .text(let role, let content):
                return [["role": role, "content": content]]
            case .assistant(let text, let calls):
                return [
                    [
                        "role": "assistant",
                        "content": text.isEmpty ? NSNull() : text,
                        "tool_calls": calls.map { call in
                            [
                                "id": call.id, "type": "function",
                                "function": ["name": call.name, "arguments": call.arguments],
                            ] as [String: Any]
                        },
                    ]
                ]
            case .toolResults(let results):
                return results.map { result in
                    ["role": "tool", "tool_call_id": result.call.id, "content": result.output]
                }
            }
        }

        var body: [String: Any] = [
            "model": config.model,
            "messages": wireMessages,
            "temperature": temperature,
            "stream": true,
        ]
        if !toolsPayload.isEmpty { body["tools"] = toolsPayload }
        if nativeSearchEnabled {
            if serviceType == "openrouter" {
                body["plugins"] = [["id": "web", "engine": "native"]]
            }
            else if ["openai", "openai-responses"].contains(serviceType) {
                body["web_search_options"] = [String: Any]()
            }
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            throw APIError.serverError(String(data: data, encoding: .utf8) ?? "HTTP Error")
        }

        var text = ""
        var streamedText = false
        var callIDs: [Int: String] = [:]
        var callNames: [Int: String] = [:]
        var callArguments: [Int: String] = [:]

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let choice = (object["choices"] as? [[String: Any]])?.first,
                let delta = choice["delta"] as? [String: Any]
            else { continue }

            if let chunk = delta["content"] as? String, !chunk.isEmpty {
                text += chunk
                streamedText = true
                onText(chunk)
            }
            if let toolDeltas = delta["tool_calls"] as? [[String: Any]] {
                for toolDelta in toolDeltas {
                    let index = toolDelta["index"] as? Int ?? 0
                    if let id = toolDelta["id"] as? String { callIDs[index] = id }
                    if let function = toolDelta["function"] as? [String: Any] {
                        if let name = function["name"] as? String { callNames[index] = name }
                        if let arguments = function["arguments"] as? String {
                            callArguments[index, default: ""] += arguments
                        }
                    }
                }
            }
        }

        let indices = Set(callIDs.keys).union(callNames.keys).union(callArguments.keys).sorted()
        let calls = indices.compactMap { index -> ToolCall? in
            guard let name = callNames[index], !name.isEmpty else { return nil }
            return ToolCall(
                id: callIDs[index] ?? UUID().uuidString,
                name: name,
                arguments: callArguments[index] ?? "{}"
            )
        }
        return TurnResult(text: text, toolCalls: calls, textWasStreamed: streamedText)
    }

    // MARK: - Gemini Execution
    private func executeTurnGemini(
        messages: [AgentMessage],
        tools: [ToolDefinition],
        temperature: Float,
        onText: @escaping (String) -> Void
    ) async throws -> TurnResult {
        var targetURL = baseURL
        var urlString = targetURL.absoluteString
        urlString = urlString.replacingOccurrences(of: ":generateContent", with: ":streamGenerateContent")
        if !urlString.contains(":streamGenerateContent") {
            if !urlString.contains("/models/") {
                targetURL = targetURL.appendingPathComponent("models/\(config.model):streamGenerateContent")
            }
            else {
                targetURL = targetURL.appendingPathComponent(":streamGenerateContent")
            }
        }
        else if let streamingURL = URL(string: urlString) {
            targetURL = streamingURL
        }
        var components = URLComponents(url: targetURL, resolvingAgainstBaseURL: false)
        var queryItems = components?.queryItems ?? []
        if !queryItems.contains(where: { $0.name == "alt" }) {
            queryItems.append(URLQueryItem(name: "alt", value: "sse"))
        }
        components?.queryItems = queryItems
        if let url = components?.url { targetURL = url }
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
                    "parts": [["text": content]],
                ]
            case .assistant(let text, let calls):
                var parts: [[String: Any]] = []
                if !text.isEmpty {
                    parts.append(["text": text])
                }
                parts.append(
                    contentsOf: calls.map { call -> [String: Any] in
                        var part: [String: Any] = [
                            "functionCall": [
                                "name": call.name,
                                "args": call.argumentsJSON ?? [:],
                            ]
                        ]
                        if let signature = call.thoughtSignature {
                            part["thoughtSignature"] = signature
                        }
                        return part
                    }
                )
                return parts.isEmpty ? nil : ["role": "model", "parts": parts]
            case .toolResults(let results):
                let parts = results.map { result -> [String: Any] in
                    let response: [String: Any] =
                        result.isError
                        ? ["error": result.output]
                        : ["result": result.output]
                    return [
                        "functionResponse": [
                            "name": result.call.name,
                            "response": response,
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
                        "parameters": t.parameters.openAIWireDict,
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
            ],
        ]
        if !systemText.isEmpty {
            body["systemInstruction"] = [
                "role": "user",
                "parts": [["text": systemText]],
            ]
        }

        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await URLSession.shared.bytes(for: req)

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            throw APIError.serverError(String(data: data, encoding: .utf8) ?? "HTTP Error")
        }

        var text = ""
        var streamedText = false
        var calls: [ToolCall] = []

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let candidate = (object["candidates"] as? [[String: Any]])?.first,
                let content = candidate["content"] as? [String: Any],
                let parts = content["parts"] as? [[String: Any]]
            else { continue }

            for part in parts {
                if let chunk = part["text"] as? String, !chunk.isEmpty {
                    text += chunk
                    streamedText = true
                    onText(chunk)
                }
                if let functionCall = part["functionCall"] as? [String: Any],
                    let name = functionCall["name"] as? String
                {
                    let argumentsObject = functionCall["args"] as? [String: Any] ?? [:]
                    let argumentsData = try JSONSerialization.data(withJSONObject: argumentsObject)
                    calls.append(
                        ToolCall(
                            id: UUID().uuidString,
                            name: name,
                            arguments: String(data: argumentsData, encoding: .utf8) ?? "{}",
                            thoughtSignature: part["thoughtSignature"] as? String
                        )
                    )
                }
            }
        }

        return TurnResult(text: text, toolCalls: calls, textWasStreamed: streamedText)
    }

    // MARK: - Claude Execution
    private func executeTurnClaude(
        messages: [AgentMessage],
        tools: [ToolDefinition],
        temperature: Float,
        onText: @escaping (String) -> Void
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
                    "content": content,
                ]
            case .assistant(let text, let calls):
                var blocks: [[String: Any]] = []
                if !text.isEmpty {
                    blocks.append(["type": "text", "text": text])
                }
                blocks.append(
                    contentsOf: calls.map { call in
                        [
                            "type": "tool_use",
                            "id": call.id,
                            "name": call.name,
                            "input": call.argumentsJSON ?? [:],
                        ]
                    }
                )
                return blocks.isEmpty ? nil : ["role": "assistant", "content": blocks]
            case .toolResults(let results):
                let blocks = results.map { result in
                    [
                        "type": "tool_result",
                        "tool_use_id": result.call.id,
                        "content": result.output,
                        "is_error": result.isError,
                    ] as [String: Any]
                }
                return blocks.isEmpty ? nil : ["role": "user", "content": blocks]
            }
        }

        var claudeTools = tools.map { t -> [String: Any] in
            [
                "name": t.name,
                "description": t.description,
                "input_schema": t.parameters.openAIWireDict,
            ]
        }
        if nativeSearchEnabled {
            claudeTools.append([
                "type": "web_search_20250305",
                "name": "web_search",
            ])
        }

        var body: [String: Any] = [
            "model": resolvedModel,
            "max_tokens": 4096,
            "messages": claudeMsgs,
            "stream": true,
        ]
        if !claudeTools.isEmpty {
            body["tools"] = claudeTools
        }
        ClaudeRequestCompatibility.addTemperature(temperature, model: config.model, to: &body)
        if !systemText.isEmpty {
            body["system"] = systemText
        }

        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await URLSession.shared.bytes(for: req)

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw APIError.serverError(
                ClaudeRequestCompatibility.errorMessage(statusCode: statusCode, data: data)
            )
        }

        var text = ""
        var streamedText = false
        var callIDs: [Int: String] = [:]
        var callNames: [Int: String] = [:]
        var callArguments: [Int: String] = [:]

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let eventType = object["type"] as? String
            else { continue }

            if eventType == "content_block_start",
                let index = object["index"] as? Int,
                let block = object["content_block"] as? [String: Any],
                block["type"] as? String == "tool_use"
            {
                callIDs[index] = block["id"] as? String ?? UUID().uuidString
                callNames[index] = block["name"] as? String ?? ""
            }
            else if eventType == "content_block_delta",
                let index = object["index"] as? Int,
                let delta = object["delta"] as? [String: Any]
            {
                switch delta["type"] as? String {
                case "text_delta":
                    if let chunk = delta["text"] as? String, !chunk.isEmpty {
                        text += chunk
                        streamedText = true
                        onText(chunk)
                    }
                case "input_json_delta":
                    if let partialJSON = delta["partial_json"] as? String {
                        callArguments[index, default: ""] += partialJSON
                    }
                default:
                    break
                }
            }
        }

        let indices = Set(callIDs.keys).union(callNames.keys).union(callArguments.keys).sorted()
        let calls = indices.compactMap { index -> ToolCall? in
            guard let name = callNames[index], !name.isEmpty else { return nil }
            return ToolCall(
                id: callIDs[index] ?? UUID().uuidString,
                name: name,
                arguments: callArguments[index].flatMap { $0.isEmpty ? nil : $0 } ?? "{}"
            )
        }
        return TurnResult(text: text, toolCalls: calls, textWasStreamed: streamedText)
    }
}
