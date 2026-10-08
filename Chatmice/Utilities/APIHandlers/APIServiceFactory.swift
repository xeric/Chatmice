//
//  APIServiceFactory.swift
//  Chatmice
//
//  Created by Renat on 28.07.2024.
//

import Foundation

class APIServiceFactory {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = AppConstants.requestTimeout
        configuration.timeoutIntervalForResource = AppConstants.requestTimeout
        return URLSession(configuration: configuration)
    }()

    static func createAPIService(
        config: APIServiceConfiguration,
        imageGenerationSupported: Bool? = nil,
        chatID: UUID? = nil
    ) -> APIService {
        let typeCandidate: String = {
            if let c = config as? APIServiceConfig, !c.type.isEmpty {
                return c.type.lowercased()
            }
            if let entity = config as? APIServiceEntity, let t = entity.type, !t.isEmpty {
                return t.lowercased()
            }
            return AppConstants.defaultApiConfigurations[config.name.lowercased()]?.inherits ?? config.name.lowercased()
        }()

        let configName = AppConstants.defaultApiConfigurations[typeCandidate]?.inherits ?? typeCandidate

        let base: APIService
        switch configName {
        case "openai-responses", "openai":
            let supportsImageGeneration = imageGenerationSupported ?? false
            base = OpenAIResponsesHandler(
                config: config,
                session: session,
                imageGenerationSupported: supportsImageGeneration
            )
        case "chatgpt":
            base = ChatGPTHandler(config: config, session: session)
        case "ollama":
            base = OllamaHandler(config: config, session: session)
        case "claude":
            base = ClaudeHandler(config: config, session: session)
        case "perplexity":
            base = PerplexityHandler(config: config, session: session)
        case "gemini":
            base = GeminiHandler(config: config, session: session)
        case "deepseek":
            base = DeepseekHandler(config: config, session: session)
        case "openrouter":
            base = OpenRouterHandler(config: config, session: session)
        default:
            base = ChatGPTHandler(config: config, session: session)
        }
        return ChatmiceEngine(baseService: base, config: config, chatID: chatID, session: session)
    }
}
