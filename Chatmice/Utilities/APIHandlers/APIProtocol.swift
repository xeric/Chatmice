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
