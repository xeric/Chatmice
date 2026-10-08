//
//  APIProtocol.swift
//  Chatmice
//
//  Created by Renat on 17.07.2024.
//

import Foundation

enum APIError: Error {
    case requestFailed(Error)
    case invalidResponse
    case decodingFailed(String)
    case unauthorized
    case rateLimited
    case serverError(String)
    case unknown(String)
    case noApiService(String)
    case attachmentNotReady(String)
}

extension APIError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .requestFailed(let error): return "Request failed: \(error.localizedDescription)"
        case .invalidResponse: return "The endpoint returned no usable response."
        case .decodingFailed(let message): return "Response decoding failed: \(message)"
        case .unauthorized: return "Unauthorized. Check the API key."
        case .rateLimited: return "Rate limited by the endpoint."
        case .serverError(let message): return "Server error: \(message)"
        case .unknown(let message): return "Unknown API error: \(message)"
        case .noApiService(let message): return message
        case .attachmentNotReady(let message): return message
        }
    }
}

enum ReasoningEffort: String, Codable, CaseIterable, Identifiable {
    case `default`
    case none
    case auto
    case low
    case medium
    case high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .default: return "Default"
        case .none: return "Off"
        case .auto: return "Auto"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }
}

enum ReasoningDialect: Equatable {
    case unsupported
    case openAIEffort
    case openAIResponses
    case anthropicAdaptive
    case anthropicBudget(min: Int, max: Int)
    case geminiLevel
    case geminiBudget(min: Int, max: Int)
}

struct ModelReasoningProfile: Equatable {
    let dialect: ReasoningDialect
    let supportedEfforts: [ReasoningEffort]

    var supportsReasoning: Bool { dialect != .unsupported }
}

enum ModelReasoningRegistry {
    static func resolve(modelID rawModelID: String, serviceType rawServiceType: String) -> ModelReasoningProfile {
        let modelID = rawModelID.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let serviceType = rawServiceType.lowercased()

        switch serviceType {
        case "claude":
            guard modelID.contains("claude") else { return unsupported }
            if isAdaptiveClaude(modelID) {
                return ModelReasoningProfile(
                    dialect: .anthropicAdaptive,
                    supportedEfforts: [.default, .none, .auto, .low, .medium, .high]
                )
            }
            return ModelReasoningProfile(
                dialect: .anthropicBudget(min: 1_024, max: claudeBudgetMaximum(modelID)),
                supportedEfforts: [.default, .none, .auto, .low, .medium, .high]
            )

        case "gemini":
            guard modelID.contains("gemini") else { return unsupported }
            if modelID.range(of: #"gemini[-_. ]?3(?:\D|$)"#, options: .regularExpression) != nil {
                return ModelReasoningProfile(
                    dialect: .geminiLevel,
                    supportedEfforts: [.default, .none, .auto, .low, .medium, .high]
                )
            }
            if modelID.range(of: #"gemini[-_. ]?2(?:\D|$)"#, options: .regularExpression) != nil {
                return ModelReasoningProfile(
                    dialect: .geminiBudget(min: 0, max: 24_576),
                    supportedEfforts: [.default, .none, .auto, .low, .medium, .high]
                )
            }
            return unsupported

        case "openai", "openai-responses":
            guard looksLikeReasoningModel(modelID) else { return unsupported }
            return ModelReasoningProfile(
                dialect: .openAIResponses,
                supportedEfforts: [.default, .none, .auto, .low, .medium, .high]
            )

        case "chatgpt", "openrouter", "deepseek", "perplexity":
            guard looksLikeReasoningModel(modelID) else { return unsupported }
            return ModelReasoningProfile(
                dialect: .openAIEffort,
                supportedEfforts: [.default, .none, .auto, .low, .medium, .high]
            )

        default:
            return unsupported
        }
    }

    private static let unsupported = ModelReasoningProfile(
        dialect: .unsupported,
        supportedEfforts: [.default]
    )

    private static func isAdaptiveClaude(_ modelID: String) -> Bool {
        if modelID.range(of: #"claude[-_. ]?(?:opus|sonnet|haiku)[-_. ]?latest"#, options: .regularExpression) != nil {
            return true
        }

        // Accept official IDs (claude-opus-4-6) and gateway aliases
        // (anthropic--claude-4.8-opus) without treating arbitrary digits as versions.
        let patterns = [
            #"claude[-_. ]?(?:opus|sonnet|haiku)[-_. ]?(?:4[.-][6-9]|[5-9](?:[.-]\d+)?)"#,
            #"claude[-_. ]?(?:4[.-][6-9]|[5-9](?:[.-]\d+)?)[-_. ]?(?:opus|sonnet|haiku)"#,
        ]
        return patterns.contains { modelID.range(of: $0, options: .regularExpression) != nil }
    }

    private static func claudeBudgetMaximum(_ modelID: String) -> Int {
        if modelID.contains("opus-4-1") || modelID.contains("opus-4.1") { return 32_000 }
        if modelID.range(of: #"opus[-_. ]?4(?:\D|$)"#, options: .regularExpression) != nil { return 32_000 }
        return 64_000
    }

    private static func looksLikeReasoningModel(_ modelID: String) -> Bool {
        let markers = ["o1", "o3", "o4", "gpt-5", "reason", "thinking", "deepseek-r1", "qwen"]
        return markers.contains(where: modelID.contains)
    }
}

enum ReasoningPreferenceStore {
    private static let prefix = "reasoningEffort."

    static func selection(for modelID: String) -> ReasoningEffort {
        guard let raw = UserDefaults.standard.string(forKey: key(for: modelID)) else { return .default }
        return ReasoningEffort(rawValue: raw) ?? .default
    }

    static func set(_ effort: ReasoningEffort, for modelID: String) {
        UserDefaults.standard.set(effort.rawValue, forKey: key(for: modelID))
    }

    private static func key(for modelID: String) -> String {
        prefix + modelID.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ReasoningRequestEncoder {
    static func apply(
        selection: ReasoningEffort,
        profile: ModelReasoningProfile,
        maxTokens: Int,
        to body: inout [String: Any]
    ) {
        guard selection != .default else { return }

        switch profile.dialect {
        case .unsupported:
            return
        case .openAIEffort:
            body["reasoning_effort"] = openAIEffort(selection)
        case .openAIResponses:
            body["reasoning"] = ["effort": openAIEffort(selection)]
        case .anthropicAdaptive:
            if selection == .none {
                body["thinking"] = ["type": "disabled"]
            } else {
                body["thinking"] = ["type": "adaptive", "display": "summarized"]
                if let effort = concreteEffort(selection) { body["effort"] = effort }
            }
        case .anthropicBudget(let min, let max):
            if selection == .none {
                body["thinking"] = ["type": "disabled"]
            } else {
                let upperBound = Swift.max(min, Swift.min(max, maxTokens - 1))
                let budget = budgetTokens(for: selection, min: min, max: upperBound)
                body["thinking"] = ["type": "enabled", "budget_tokens": budget]
            }
        case .geminiLevel:
            if selection == .none {
                body["thinkingConfig"] = ["includeThoughts": false, "thinkingLevel": "minimal"]
            } else {
                var config: [String: Any] = ["includeThoughts": true]
                if let effort = concreteEffort(selection) { config["thinkingLevel"] = effort }
                body["thinkingConfig"] = config
            }
        case .geminiBudget(let min, let max):
            let budget: Int
            if selection == .none {
                budget = 0
            } else if selection == .auto {
                budget = -1
            } else {
                budget = budgetTokens(for: selection, min: min, max: max)
            }
            body["thinkingConfig"] = ["includeThoughts": selection != .none, "thinkingBudget": budget]
        }
    }

    private static func openAIEffort(_ selection: ReasoningEffort) -> String {
        switch selection {
        case .none: return "none"
        case .auto: return "medium"
        case .low, .medium, .high: return selection.rawValue
        case .default: return "medium"
        }
    }

    private static func concreteEffort(_ selection: ReasoningEffort) -> String? {
        switch selection {
        case .low, .medium, .high: return selection.rawValue
        case .default, .none, .auto: return nil
        }
    }

    private static func budgetTokens(for selection: ReasoningEffort, min: Int, max: Int) -> Int {
        let ratio: Double
        switch selection {
        case .low: ratio = 0.05
        case .medium, .auto: ratio = 0.5
        case .high: ratio = 0.8
        case .default, .none: ratio = 0
        }
        return Swift.max(min, Swift.min(max, Int((Double(max) * ratio).rounded())))
    }
}

protocol APIService {
    var name: String { get }
    var baseURL: URL { get }

    func sendMessage(
        _ requestMessages: [[String: String]],
        temperature: Float,
        completion: @escaping (Result<String, APIError>) -> Void
    )

    func sendMessageStream(_ requestMessages: [[String: String]], temperature: Float) async throws
        -> AsyncThrowingStream<String, Error>

    func fetchModels() async throws -> [AIModel]
    func cancelCurrentRequest()
}

protocol APIServiceConfiguration {
    var name: String { get set }
    var apiUrl: URL { get set }
    var apiKey: String { get set }
    var model: String { get set }
}

struct AIModel: Codable, Identifiable {
    let id: String

    init(id: String) {
        self.id = id
    }
}

extension APIService {
    func fetchModels() async throws -> [AIModel] { [] }
    func cancelCurrentRequest() {}
}

struct ModelCapabilityTestResult: Codable, Equatable, Sendable {
    let connectionSucceeded: Bool
    let visionSupported: Bool?
    let reasoningSupported: Bool?
    let testedAt: Date
    let errorMessage: String?
}

enum ModelCapabilityTestStore {
    private static let prefix = "modelCapabilityTests."

    static func results(for serviceID: UUID) -> [String: ModelCapabilityTestResult] {
        guard let data = UserDefaults.standard.data(forKey: prefix + serviceID.uuidString),
              let results = try? JSONDecoder().decode([String: ModelCapabilityTestResult].self, from: data)
        else { return [:] }
        return results
    }

    static func save(_ results: [String: ModelCapabilityTestResult], for serviceID: UUID) {
        guard let data = try? JSONEncoder().encode(results) else { return }
        UserDefaults.standard.set(data, forKey: prefix + serviceID.uuidString)
    }
}

enum ModelCapabilityProbe {
    private enum ProbeKind {
        case connection
        case vision
        case reasoning
    }

    private static let pixelPNGBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"

    static func test(config: APIServiceConfig, modelID: String) async -> ModelCapabilityTestResult {
        do {
            try await perform(config: config, modelID: modelID, kind: .connection)
        } catch {
            return ModelCapabilityTestResult(
                connectionSucceeded: false,
                visionSupported: nil,
                reasoningSupported: nil,
                testedAt: Date(),
                errorMessage: error.localizedDescription
            )
        }

        let visionSupported: Bool
        do {
            try await perform(config: config, modelID: modelID, kind: .vision)
            visionSupported = true
        } catch {
            visionSupported = false
        }

        let reasoningSupported: Bool
        do {
            try await perform(config: config, modelID: modelID, kind: .reasoning)
            reasoningSupported = true
        } catch {
            reasoningSupported = false
        }

        return ModelCapabilityTestResult(
            connectionSucceeded: true,
            visionSupported: visionSupported,
            reasoningSupported: reasoningSupported,
            testedAt: Date(),
            errorMessage: nil
        )
    }

    private static func perform(config: APIServiceConfig, modelID: String, kind: ProbeKind) async throws {
        let request = try makeRequest(config: config, modelID: modelID, kind: kind)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw APIError.serverError("HTTP \(httpResponse.statusCode): \(detail)")
        }
    }

    private static func makeRequest(config: APIServiceConfig, modelID: String, kind: ProbeKind) throws -> URLRequest {
        let type = config.type.lowercased()
        let endpoint: URL
        let body: [String: Any]

        switch type {
        case "claude":
            endpoint = appending("messages", to: config.apiUrl)
            body = claudeBody(modelID: modelID, kind: kind)
        case "gemini":
            endpoint = try geminiEndpoint(baseURL: config.apiUrl, modelID: modelID)
            body = geminiBody(modelID: modelID, kind: kind)
        case "openai-responses":
            endpoint = appending("responses", to: config.apiUrl)
            body = responsesBody(modelID: modelID, kind: kind)
        case "ollama":
            endpoint = appending("api/chat", to: config.apiUrl)
            body = ollamaBody(modelID: modelID, kind: kind)
        default:
            endpoint = appending("chat/completions", to: config.apiUrl)
            body = chatCompletionsBody(modelID: modelID, kind: kind)
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
            if type == "claude" {
                request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
            }
            if type == "gemini" {
                request.setValue(config.apiKey, forHTTPHeaderField: "x-goog-api-key")
            }
        }
        if type == "claude" {
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func appending(_ suffix: String, to baseURL: URL) -> URL {
        let normalizedSuffix = suffix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).hasSuffix(normalizedSuffix) {
            return baseURL
        }
        return baseURL.appendingPathComponent(normalizedSuffix)
    }

    private static func geminiEndpoint(baseURL: URL, modelID: String) throws -> URL {
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        if !base.hasSuffix("/models") { base += "/models" }
        guard let url = URL(string: "\(base)/\(modelID):generateContent") else {
            throw APIError.unknown("Invalid Gemini endpoint")
        }
        return url
    }

    private static func chatCompletionsBody(modelID: String, kind: ProbeKind) -> [String: Any] {
        var message: [String: Any] = ["role": "user", "content": "Reply with OK."]
        if kind == .vision {
            message["content"] = [
                ["type": "text", "text": "Identify this one-pixel image, then reply with one word."],
                ["type": "image_url", "image_url": ["url": "data:image/png;base64,\(pixelPNGBase64)"]]
            ]
        }
        var body: [String: Any] = [
            "model": modelID,
            "messages": [message],
            "max_tokens": 32
        ]
        if kind == .reasoning { body["reasoning_effort"] = "low" }
        return body
    }

    private static func responsesBody(modelID: String, kind: ProbeKind) -> [String: Any] {
        var content: [[String: Any]] = [["type": "input_text", "text": "Reply with OK."]]
        if kind == .vision {
            content.append(["type": "input_image", "image_url": "data:image/png;base64,\(pixelPNGBase64)"])
        }
        var body: [String: Any] = [
            "model": modelID,
            "input": [["role": "user", "content": content]],
            "max_output_tokens": 32
        ]
        if kind == .reasoning { body["reasoning"] = ["effort": "low"] }
        return body
    }

    private static func claudeBody(modelID: String, kind: ProbeKind) -> [String: Any] {
        var content: Any = "Reply with OK."
        if kind == .vision {
            content = [
                ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": pixelPNGBase64]],
                ["type": "text", "text": "Identify this one-pixel image, then reply with one word."]
            ]
        }
        var body: [String: Any] = [
            "model": modelID,
            "messages": [["role": "user", "content": content]],
            "max_tokens": kind == .reasoning ? 1100 : 32
        ]
        if kind == .reasoning {
            let profile = ModelReasoningRegistry.resolve(modelID: modelID, serviceType: "claude")
            if profile.dialect == .anthropicAdaptive {
                body["thinking"] = ["type": "adaptive"]
                body["effort"] = "low"
            } else {
                body["thinking"] = ["type": "enabled", "budget_tokens": 1024]
            }
        }
        return body
    }

    private static func geminiBody(modelID: String, kind: ProbeKind) -> [String: Any] {
        var parts: [[String: Any]] = [["text": "Reply with OK."]]
        if kind == .vision {
            parts.insert(["inline_data": ["mime_type": "image/png", "data": pixelPNGBase64]], at: 0)
        }
        var body: [String: Any] = ["contents": [["role": "user", "parts": parts]]]
        if kind == .reasoning {
            let profile = ModelReasoningRegistry.resolve(modelID: modelID, serviceType: "gemini")
            switch profile.dialect {
            case .geminiLevel:
                body["generationConfig"] = ["thinkingConfig": ["includeThoughts": true, "thinkingLevel": "low"]]
            default:
                body["generationConfig"] = ["thinkingConfig": ["includeThoughts": true, "thinkingBudget": 512]]
            }
        }
        return body
    }

    private static func ollamaBody(modelID: String, kind: ProbeKind) -> [String: Any] {
        var message: [String: Any] = ["role": "user", "content": "Reply with OK."]
        if kind == .vision { message["images"] = [pixelPNGBase64] }
        var body: [String: Any] = ["model": modelID, "messages": [message], "stream": false]
        if kind == .reasoning { body["think"] = true }
        return body
    }
}
