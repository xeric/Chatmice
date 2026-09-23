//
//  ChatmiceEngine.swift
//  Chatmice / macai
//
//  APIService Proxy that orchestrates multi-turn Agent tool calling (MCP, Bash, Skills).
//  Seamlessly integrates into macai without modifying MessageManager or ChatView.
//

import AppKit
import Foundation

class ChatmiceEngine: APIService {
    let name: String
    let baseURL: URL
    private let baseService: APIService
    private let config: APIServiceConfiguration
    private var activeTask: Task<Void, Never>?

    static let toolsEnabledKey = "chatmiceToolsEnabled"
    static let bashEnabledKey = "chatmiceBashEnabled"
    static let skillsEnabledKey = "chatmiceSkillsEnabled"
    static let computerEnabledKey = "chatmiceComputerEnabled"
    static let bashAutoConfirmKey = "chatmiceBashAutoConfirm"

    init(baseService: APIService, config: APIServiceConfiguration) {
        self.baseService = baseService
        self.config = config
        self.name = config.name
        self.baseURL = config.apiUrl
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
        
        // Check if service uses OpenAI-compatible protocol (chatgpt / openai / deepseek / openrouter / ollama)
        let serviceType: String = {
            if let c = config as? APIServiceConfig { return c.type.lowercased() }
            if let e = config as? APIServiceEntity { return (e.type ?? "").lowercased() }
            return ""
        }()
        let isOpenAICompatible = serviceType == "chatgpt" || serviceType == "openai" || serviceType == "openai-responses" || serviceType == "deepseek" || serviceType == "openrouter" || serviceType == "ollama" || serviceType.isEmpty

        // If tools disabled or service uses native protocol (e.g. Google Gemini, Anthropic), route directly
        guard toolsEnabled && isOpenAICompatible else {
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

    // MARK: - Agent Tool Loop Engine
    private func runToolLoop(
        requestMessages: [[String: String]],
        temperature: Float,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        let box = ToolBox()
        let bashEnabled = UserDefaults.standard.object(forKey: Self.bashEnabledKey) as? Bool ?? true
        let skillsEnabled = UserDefaults.standard.object(forKey: Self.skillsEnabledKey) as? Bool ?? true
        let computerEnabled = UserDefaults.standard.object(forKey: Self.computerEnabledKey) as? Bool ?? false
        let autoConfirm = UserDefaults.standard.bool(forKey: Self.bashAutoConfirmKey)

        if bashEnabled {
            await box.register(BashTool())
        }
        let skillStore = SkillStore()
        if skillsEnabled {
            await box.register(SkillTool(catalog: skillStore))
        }
        if computerEnabled {
            await box.register(ScreenshotTool())
        }
        for tool in await MCPService.shared.allTools() {
            await box.register(tool)
        }

        let defs = await box.definitions()
        guard !defs.isEmpty else {
            // No tools available, fallback to direct stream
            let stream = try await baseService.sendMessageStream(requestMessages, temperature: temperature)
            for try await chunk in stream {
                continuation.yield(chunk)
            }
            return
        }

        // Construct request with tool definitions
        var conversationHistory = requestMessages

        // Append Agent instructions
        var agentInstructions: [String] = []
        if bashEnabled {
            agentInstructions.append("You have access to a local bash execution tool named `bash`. You CAN and SHOULD use it to run terminal commands, inspect the file system, list directories, read files, and execute shell scripts on the user's macOS computer whenever requested by the user. Never say you cannot access the local system.")
        }
        if skillsEnabled {
            let section = await skillStore.systemPromptSection()
            if !section.isEmpty {
                agentInstructions.append(section)
            }
        }

        if !agentInstructions.isEmpty {
            let combined = agentInstructions.joined(separator: "\n\n")
            if let idx = conversationHistory.firstIndex(where: { $0["role"] == "system" }) {
                var sys = conversationHistory[idx]
                sys["content"] = (sys["content"] ?? "") + "\n\n" + combined
                conversationHistory[idx] = sys
            } else {
                conversationHistory.insert(["role": "system", "content": combined], at: 0)
            }
        }
        let context = ToolContext(
            depth: 0,
            cwd: FileManager.default.temporaryDirectory,
            ask: { prompt in
                if autoConfirm { return true }
                return await withCheckedContinuation { cont in
                    DispatchQueue.main.async {
                        let alert = NSAlert()
                        alert.messageText = "Chatmice Tool Execution Confirmation"
                        alert.informativeText = prompt
                        alert.addButton(withTitle: "Allow")
                        alert.addButton(withTitle: "Deny")
                        alert.alertStyle = .warning
                        let res = alert.runModal()
                        cont.resume(returning: res == .alertFirstButtonReturn)
                    }
                }
            }
        )

        var rounds = 0
        let maxRounds = 10

        while rounds < maxRounds {
            rounds += 1
            if Task.isCancelled { break }

            // Execute turn
            let rawResult = try await self.executeTurn(
                messages: conversationHistory,
                tools: defs,
                temperature: temperature
            )

            if rawResult.toolCalls.isEmpty {
                // No tool calls, model gave final answer
                if !rawResult.text.isEmpty {
                    continuation.yield(rawResult.text)
                }
                break
            }

            // Execute tool calls
            var assistantMsg: [String: String] = ["role": "assistant", "content": rawResult.text]
            conversationHistory.append(assistantMsg)

            for call in rawResult.toolCalls {
                if Task.isCancelled { break }
                continuation.yield("\n\n> ⚙️ *Running `\(call.name)`...*\n")

                var outputText = ""
                do {
                    outputText = try await box.execute(name: call.name, arguments: call.arguments, context: context)
                    let preview = outputText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(180)
                    continuation.yield("> 💡 *Result: `\(preview)\(outputText.count > 180 ? "..." : "")`*\n\n")
                } catch {
                    outputText = "Error: \(error.localizedDescription)"
                    continuation.yield("> ⚠️ *Error: \(error.localizedDescription)*\n\n")
                }

                // Append tool result into conversation history for next round
                let toolMsg: [String: String] = [
                    "role": "user",
                    "content": "[Tool Result of \(call.name)]:\n\(outputText)"
                ]
                conversationHistory.append(toolMsg)
            }
        }
    }

    private struct TurnResult {
        var text: String
        var toolCalls: [ToolCall]
    }

    private func executeTurn(
        messages: [[String: String]],
        tools: [ToolDefinition],
        temperature: Float
    ) async throws -> TurnResult {
        // Ensure URL has /chat/completions endpoint
        var targetURL = baseURL
        if !targetURL.absoluteString.hasSuffix("/chat/completions") {
            targetURL = targetURL.appendingPathComponent("chat/completions")
        }
        var req = URLRequest(url: targetURL)
        req.httpMethod = "POST"
        let effectiveKey: String = {
            if !config.apiKey.isEmpty { return config.apiKey }
            if let entity = config as? APIServiceEntity,
               let id = entity.tokenIdentifier ?? entity.id?.uuidString,
               let token = try? TokenManager.getToken(for: id), !token.isEmpty {
                return token
            }
            return ProcessInfo.processInfo.environment["LOCAL_SAP_AI_CORE_PROXY_KEY"] ?? ""
        }()
        if !effectiveKey.isEmpty {
            req.setValue("Bearer \(effectiveKey)", forHTTPHeaderField: "Authorization")
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

        let body: [String: Any] = [
            "model": config.model,
            "messages": messages,
            "tools": toolsPayload,
            "temperature": temperature
        ]

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
}
