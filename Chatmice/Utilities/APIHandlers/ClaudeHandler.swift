//
//  ClaudeHandler.swift
//  Chatmice
//
//  Created by Renat Notfullin on 20.09.2024.
//

import Foundation

private struct ClaudeModelsResponse: Codable {
    let data: [ClaudeModel]
}

private struct ClaudeModel: Codable {
    let id: String
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }
}

actor ClaudeModelResolver {
    static let shared = ClaudeModelResolver()

    private var mappingsByEndpoint: [String: [String: String]] = [:]

    func resolve(
        _ configuredModel: String,
        baseURL: URL,
        apiKey: String,
        session: URLSession
    ) async -> String {
        let modelsURL = Self.modelsURL(for: baseURL)
        let cacheKey = modelsURL.absoluteString
        if let resolved = mappingsByEndpoint[cacheKey]?[configuredModel] {
            return resolved
        }

        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        if !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let catalog = try? JSONDecoder().decode(ClaudeModelsResponse.self, from: data) else {
            return configuredModel
        }

        var mappings: [String: String] = [:]
        for model in catalog.data {
            mappings[model.id] = model.id
            if let displayName = model.displayName, mappings[displayName] == nil {
                mappings[displayName] = model.id
            }
        }
        mappingsByEndpoint[cacheKey] = mappings
        return mappings[configuredModel] ?? configuredModel
    }

    private static func modelsURL(for baseURL: URL) -> URL {
        let base = baseURL.lastPathComponent == "messages"
            ? baseURL.deletingLastPathComponent()
            : baseURL
        return base.appendingPathComponent("models")
    }
}

enum ClaudeRequestCompatibility {
    static func addTemperature(_ temperature: Float, model: String, to body: inout [String: Any]) {
        let normalized = model.lowercased()
        let rejectsTemperature = normalized.contains("claude-4")
            || normalized.contains("opus")
            || normalized.contains("thinking")
        if !rejectsTemperature {
            body["temperature"] = temperature
        }
    }

    static func errorMessage(statusCode: Int, data: Data?) -> String {
        let fallback = "HTTP \(statusCode)"
        guard let data, !data.isEmpty else { return fallback }

        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? [String: Any],
           let message = error["message"] as? String,
           !message.isEmpty {
            return "\(fallback): \(message)"
        }

        let raw = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? fallback : "\(fallback): \(raw)"
    }
}

final class ClaudeHandler: APIService, @unchecked Sendable {
    let name: String
    let baseURL: URL
    private let apiKey: String
    let model: String
    private let session: URLSession
    private var activeDataTask: URLSessionDataTask?
    private var activeStreamTask: Task<Void, Never>?
    private var activeResolutionTask: Task<Void, Never>?

    init(config: APIServiceConfiguration, session: URLSession) {
        self.name = config.name
        self.baseURL = config.apiUrl
        self.apiKey = config.apiKey
        self.model = config.model
        self.session = session
    }

    func fetchModels() async throws -> [AIModel] {
        var base = baseURL
        if base.lastPathComponent == "messages" {
            base = base.deletingLastPathComponent()
        }
        let modelsURL = base.appendingPathComponent("models")
        
        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        let effectiveKey = apiKey.isEmpty ? (ProcessInfo.processInfo.environment["LOCAL_SAP_AI_CORE_PROXY_KEY"] ?? "") : apiKey
        if !effectiveKey.isEmpty {
            request.setValue(effectiveKey, forHTTPHeaderField: "X-API-Key")
        }
        request.setValue("2023-06-01", forHTTPHeaderField: "Anthropic-Version")
        
        do {
            let (data, response) = try await session.data(for: request)
            let result = handleAPIResponse(response, data: data, error: nil)
            switch result {
            case .success(let responseData):
                guard let responseData = responseData else {
                    throw APIError.invalidResponse
                }
                if let claudeResponse = try? JSONDecoder().decode(ClaudeModelsResponse.self, from: responseData) {
                    return claudeResponse.data.map { AIModel(id: $0.id) }
                }
                if let obj = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                   let dataArr = obj["data"] as? [[String: Any]] {
                    let ids = dataArr.compactMap { $0["id"] as? String }
                    if !ids.isEmpty { return ids.map { AIModel(id: $0) } }
                }
                throw APIError.decodingFailed("Failed to parse Claude models list")
            case .failure(let error):
                throw error
            }
        } catch {
            throw APIError.requestFailed(error)
        }
    }

    func sendMessage(
        _ requestMessages: [[String: String]],
        temperature: Float,
        completion: @escaping (Result<String, APIError>) -> Void
    ) {
        activeDataTask?.cancel()
        activeResolutionTask?.cancel()
        activeResolutionTask = Task { [weak self] in
            guard let self else { return }
            let resolvedModel = await ClaudeModelResolver.shared.resolve(
                model,
                baseURL: baseURL,
                apiKey: effectiveAPIKey,
                session: session
            )
            guard !Task.isCancelled else { return }

            let request = prepareRequest(
                requestMessages: requestMessages,
                model: resolvedModel,
                temperature: temperature,
                stream: false
            )
            let task = session.dataTask(with: request) { data, response, error in
                DispatchQueue.main.async {
                    self.activeDataTask = nil
                    let result = self.handleAPIResponse(response, data: data, error: error)
                    switch result {
                    case .success(let responseData):
                        guard let responseData,
                              let (messageContent, _) = self.parseJSONResponse(data: responseData) else {
                            completion(.failure(.decodingFailed("Failed to parse Claude response")))
                            return
                        }
                        completion(.success(messageContent))
                    case .failure(let error):
                        completion(.failure(error))
                    }
                }
            }
            activeDataTask = task
            task.resume()
        }
    }

    func sendMessageStream(_ requestMessages: [[String: String]], temperature: Float) async throws
        -> AsyncThrowingStream<String, Error>
    {
        return AsyncThrowingStream { continuation in
            let streamTask = Task {
                defer { self.activeStreamTask = nil }
                do {
                    let resolvedModel = await ClaudeModelResolver.shared.resolve(
                        model,
                        baseURL: baseURL,
                        apiKey: effectiveAPIKey,
                        session: session
                    )
                    try Task.checkCancellation()
                    let request = self.prepareRequest(
                        requestMessages: requestMessages,
                        model: resolvedModel,
                        temperature: temperature,
                        stream: true
                    )
                    print("[ClaudeHandler] Streaming request to: \(request.url?.absoluteString ?? "")")
                    let (stream, response) = try await session.bytes(for: request)
                    let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
                    print("[ClaudeHandler] Response status: \(httpStatus)")

                    if !(200...299).contains(httpStatus) {
                        var data = Data()
                        for try await byte in stream {
                            data.append(byte)
                        }
                        let errorMsg = String(data: data, encoding: .utf8) ?? "HTTP \(httpStatus)"
                        print("[ClaudeHandler] Error response: \(errorMsg)")
                        continuation.finish(throwing: APIError.serverError(errorMsg))
                        return
                    }

                    for try await line in stream.lines {
                        let (finished, error, content, _) = self.parseSSEEvent(line)

                        if let error = error {
                            continuation.finish(throwing: APIError.decodingFailed(error.localizedDescription))
                            break
                        }

                        if let content = content, !content.isEmpty {
                            continuation.yield(content)
                        }

                        if finished {
                            continuation.finish()
                            break
                        }
                    }
                }
                catch {
                    continuation.finish(throwing: APIError.requestFailed(error))
                }
            }
            activeStreamTask?.cancel()
            activeStreamTask = streamTask
            continuation.onTermination = { _ in
                streamTask.cancel()
            }
        }
    }

    private var effectiveAPIKey: String {
        apiKey.isEmpty ? (ProcessInfo.processInfo.environment["LOCAL_SAP_AI_CORE_PROXY_KEY"] ?? "") : apiKey
    }

    private func prepareRequest(requestMessages: [[String: String]], model: String, temperature: Float, stream: Bool)
        -> URLRequest
    {
        var targetURL = baseURL
        if targetURL.lastPathComponent != "messages" {
            targetURL = targetURL.appendingPathComponent("messages")
        }
        var request = URLRequest(url: targetURL)
        request.httpMethod = "POST"

        let effectiveKey = apiKey.isEmpty ? (ProcessInfo.processInfo.environment["LOCAL_SAP_AI_CORE_PROXY_KEY"] ?? "") : apiKey
        if !effectiveKey.isEmpty {
            request.setValue(effectiveKey, forHTTPHeaderField: "X-API-Key")
            request.setValue(effectiveKey, forHTTPHeaderField: "x-api-key")
            request.setValue("Bearer \(effectiveKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "Anthropic-Version")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        var systemMessage = ""
        var updatedRequestMessages: [[String: Any]] = []

        for msg in requestMessages {
            let role = msg["role"] ?? "user"
            let content = msg["content"] ?? ""
            if role == "system" {
                if systemMessage.isEmpty {
                    systemMessage = content
                } else {
                    systemMessage += "\n\n" + content
                }
            } else {
                let claudeRole = (role == "assistant" || role == "model") ? "assistant" : "user"
                updatedRequestMessages.append([
                    "role": claudeRole,
                    "content": content
                ])
            }
        }

        // Cherry Studio ensureValidHistory: merge consecutive messages with same role & ensure first is user
        var sanitizedMessages: [[String: Any]] = []
        for msg in updatedRequestMessages {
            let currentRole = msg["role"] as? String ?? "user"
            let currentContent = msg["content"] as? String ?? ""
            if let last = sanitizedMessages.last, (last["role"] as? String) == currentRole {
                let lastContent = last["content"] as? String ?? ""
                sanitizedMessages[sanitizedMessages.count - 1]["content"] = lastContent + "\n\n" + currentContent
            } else {
                sanitizedMessages.append(msg)
            }
        }

        if let first = sanitizedMessages.first, (first["role"] as? String) != "user" {
            sanitizedMessages.insert(["role": "user", "content": "Hello"], at: 0)
        }

        let maxTokens = model.contains("3-5-sonnet") || model.contains("4-") || model.contains("4.") ? 8192 : (AppConstants.defaultApiConfigurations["claude"]?.maxTokens ?? 4096)

        var jsonDict: [String: Any] = [
            "model": model,
            "messages": sanitizedMessages,
            "stream": stream,
            "max_tokens": maxTokens,
        ]

        if !systemMessage.isEmpty {
            jsonDict["system"] = systemMessage
        }

        ClaudeRequestCompatibility.addTemperature(temperature, model: model, to: &jsonDict)
        let reasoningSelection = ReasoningPreferenceStore.selection(for: model)
        let reasoningProfile = ModelReasoningRegistry.resolve(modelID: model, serviceType: "claude")
        ReasoningRequestEncoder.apply(
            selection: reasoningSelection,
            profile: reasoningProfile,
            maxTokens: maxTokens,
            to: &jsonDict
        )
        if reasoningSelection != .default {
            jsonDict.removeValue(forKey: "temperature")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: jsonDict, options: [])
        return request
    }

    private func handleAPIResponse(_ response: URLResponse?, data: Data?, error: Error?) -> Result<Data?, APIError> {
        if let error = error {
            return .failure(.requestFailed(error))
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            return .failure(.invalidResponse)
        }

        if !(200...299).contains(httpResponse.statusCode) {
            let message = ClaudeRequestCompatibility.errorMessage(
                statusCode: httpResponse.statusCode,
                data: data
            )
            switch httpResponse.statusCode {
            case 401:
                return .failure(.unauthorized)
            case 429:
                return .failure(.rateLimited)
            case 400:
                return .failure(.serverError("Bad Request: \(message)"))
            case 404:
                return .failure(.serverError("Model not found: \(message)"))
            case 500...599:
                return .failure(.serverError("Claude API Error: \(message)"))
            default:
                return .failure(.unknown(message))
            }
        }

        return .success(data)
    }

    private func parseJSONResponse(data: Data) -> (String, String)? {
        do {
            if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                let role = json["role"] as? String,
                let contentArray = json["content"] as? [[String: Any]]
            {

                let textContent = contentArray.compactMap { item -> String? in
                    if let type = item["type"] as? String, type == "text",
                        let text = item["text"] as? String
                    {
                        return text
                    }
                    return nil
                }.joined(separator: "\n")

                if !textContent.isEmpty {
                    return (textContent, role)
                }
            }
        }
        catch {
            print("Error parsing JSON: \(error.localizedDescription)")
        }
        return nil
    }

    private func parseSSEEvent(_ event: String) -> (Bool, Error?, String?, String?) {
        var isFinished = false
        var textContent = ""
        let parseError: Error? = nil
        var jsonString: String?

        if event.hasPrefix("data: ") {
            jsonString = event.replacingOccurrences(of: "data: ", with: "")
        }

        guard let jsonString = jsonString else {
            return (isFinished, parseError, nil, nil)
        }

        if jsonString.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" {
            return (true, nil, nil, nil)
        }

        guard let jsonData = jsonString.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any]
        else {
            return (isFinished, nil, nil, nil)
        }

        if let eventType = json["type"] as? String {
            switch eventType {
            case "content_block_start":
                if let contentBlock = json["content_block"] as? [String: Any],
                    let text = contentBlock["text"] as? String
                {
                    textContent = text
                }
            case "content_block_delta":
                if let delta = json["delta"] as? [String: Any] {
                    if let text = delta["text"] as? String {
                        textContent = text
                    } else if let thinking = delta["thinking"] as? String {
                        textContent = thinking
                    }
                }
            case "message_delta":
                if let delta = json["delta"] as? [String: Any],
                    let stopReason = delta["stop_reason"] as? String
                {
                    isFinished = stopReason == "end_turn"
                }
            case "message_stop":
                isFinished = true
            case "ping":
                // Ignore ping events
                break
            default:
                print("Unhandled event type: \(eventType)")
            }
        }
        return (isFinished, parseError, textContent.isEmpty ? nil : textContent, nil)
    }

    func cancelCurrentRequest() {
        activeResolutionTask?.cancel()
        activeDataTask?.cancel()
        activeStreamTask?.cancel()
    }
}
