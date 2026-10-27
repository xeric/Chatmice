//
//  ContextManagement.swift
//  Chatmice
//

import Foundation

struct ModelTokenUsage: Codable, Equatable, Sendable {
    let inputTokens: Int
    let outputTokens: Int
    let totalTokens: Int
    let isEstimated: Bool

    init(inputTokens: Int, outputTokens: Int, totalTokens: Int? = nil, isEstimated: Bool = false) {
        self.inputTokens = max(0, inputTokens)
        self.outputTokens = max(0, outputTokens)
        self.totalTokens = max(totalTokens ?? (inputTokens + outputTokens), inputTokens + outputTokens)
        self.isEstimated = isEstimated
    }

    func merging(_ other: ModelTokenUsage) -> ModelTokenUsage {
        ModelTokenUsage(
            inputTokens: max(inputTokens, other.inputTokens),
            outputTokens: max(outputTokens, other.outputTokens),
            totalTokens: max(totalTokens, other.totalTokens),
            isEstimated: isEstimated || other.isEstimated
        )
    }
}

final class ModelTokenUsageTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ModelTokenUsage?

    func record(_ usage: ModelTokenUsage) {
        lock.withLock {
            value = value?.merging(usage) ?? usage
        }
    }

    func record(data: Data) {
        guard let usage = ModelTokenUsageParser.parse(data: data) else { return }
        record(usage)
    }

    func record(sseLine: String) {
        let trimmed = sseLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = trimmed.hasPrefix("data:")
            ? String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            : trimmed
        guard payload != "[DONE]", let data = payload.data(using: .utf8) else { return }
        record(data: data)
    }

    func consume() -> ModelTokenUsage? {
        lock.withLock {
            defer { value = nil }
            return value
        }
    }
}

enum ModelTokenUsageParser {
    static func parse(data: Data) -> ModelTokenUsage? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var best: ModelTokenUsage?
        visit(object, best: &best)
        return best
    }

    private static func visit(_ value: Any, best: inout ModelTokenUsage?) {
        if let dictionary = value as? [String: Any] {
            if let usage = usage(from: dictionary) {
                best = best?.merging(usage) ?? usage
            }
            for child in dictionary.values {
                visit(child, best: &best)
            }
        }
        else if let array = value as? [Any] {
            for child in array {
                visit(child, best: &best)
            }
        }
    }

    private static func usage(from dictionary: [String: Any]) -> ModelTokenUsage? {
        let input = integer(
            in: dictionary,
            keys: ["input_tokens", "prompt_tokens", "promptTokenCount", "prompt_eval_count"]
        )
        let output = integer(
            in: dictionary,
            keys: ["output_tokens", "completion_tokens", "candidatesTokenCount", "eval_count"]
        )
        let total = integer(in: dictionary, keys: ["total_tokens", "totalTokenCount"])
        guard input != nil || output != nil || total != nil else { return nil }
        return ModelTokenUsage(
            inputTokens: input ?? max(0, (total ?? 0) - (output ?? 0)),
            outputTokens: output ?? max(0, (total ?? 0) - (input ?? 0)),
            totalTokens: total
        )
    }

    private static func integer(in dictionary: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = dictionary[key] as? Int { return value }
            if let value = dictionary[key] as? NSNumber { return value.intValue }
        }
        return nil
    }
}

enum ContextWindowSource: String, Codable, Sendable {
    case userOverride
    case providerMetadata
    case builtInRegistry
    case remoteMetadata
    case modelMetadataDefault
}

struct ContextWindowResolution: Equatable, Sendable {
    let tokens: Int
    let source: ContextWindowSource
}

enum ModelContextMetadataStore {
    private static let storageKey = "modelContextMetadata.v1"

    static func save(_ models: [AIModel], serviceType: String) {
        var values = load()
        for model in models {
            guard let tokens = model.contextWindowTokens, tokens > 0 else { continue }
            values[key(serviceType: serviceType, modelID: model.id)] = tokens
        }
        UserDefaults.standard.set(values, forKey: storageKey)
    }

    static func tokens(serviceType: String, modelID: String) -> Int? {
        let value = load()[key(serviceType: serviceType, modelID: modelID)] ?? 0
        return value > 0 ? value : nil
    }

    private static func load() -> [String: Int] {
        UserDefaults.standard.dictionary(forKey: storageKey)?.compactMapValues { value in
            if let number = value as? NSNumber { return number.intValue }
            return nil
        } ?? [:]
    }

    private static func key(serviceType: String, modelID: String) -> String {
        serviceType.lowercased() + "::" + modelID.lowercased()
    }
}

enum ModelContextRegistry {
    static func resolve(service: APIServiceEntity?, modelID: String) -> ContextWindowResolution? {
        let overrides = ModelConfigurationStore.overrides(serviceID: service?.id, modelID: modelID)
        if let tokens = overrides.contextWindowTokens, tokens > 0 {
            return ContextWindowResolution(tokens: tokens, source: .userOverride)
        }

        let serviceType = service?.type ?? ""
        if let tokens = ModelContextMetadataStore.tokens(serviceType: serviceType, modelID: modelID) {
            return ContextWindowResolution(tokens: tokens, source: .providerMetadata)
        }

        let defaults = ModelConfigurationStore.metadataDefaults(serviceID: service?.id, modelID: modelID)
        if let tokens = defaults.contextWindowTokens, tokens > 0 {
            return ContextWindowResolution(tokens: tokens, source: .modelMetadataDefault)
        }

        if let resolution = ModelMetadataCatalog.shared.metadata(modelID: modelID, serviceType: serviceType) {
            let source: ContextWindowSource = resolution.source == .builtIn ? .builtInRegistry : .remoteMetadata
            return ContextWindowResolution(tokens: resolution.metadata.limit.context, source: source)
        }

        guard let tokens = legacyBuiltInTokens(modelID: modelID, serviceType: serviceType) else { return nil }
        return ContextWindowResolution(tokens: tokens, source: .builtInRegistry)
    }

    static func builtInTokens(modelID: String, serviceType: String) -> Int? {
        if let metadata = ModelMetadataCatalog.builtInMetadata(modelID: modelID) {
            return metadata.limit.context
        }
        return legacyBuiltInTokens(modelID: modelID, serviceType: serviceType)
    }

    private static func legacyBuiltInTokens(modelID rawModelID: String, serviceType rawServiceType: String) -> Int? {
        let modelID = rawModelID.lowercased()
        let serviceType = rawServiceType.lowercased()

        if modelID.contains("gemini-1.5-pro") { return 2_097_152 }
        if modelID.contains("gemini") { return 1_048_576 }
        if modelID.contains("gpt-4.1") { return 1_047_576 }
        if modelID.contains("gpt-4o") || modelID.contains("gpt-4-turbo") { return 128_000 }
        if modelID.range(of: #"(?:^|[/_-])o[134](?:$|[/_.-])"#, options: .regularExpression) != nil {
            return 200_000
        }
        if modelID.contains("claude") || serviceType == "claude" { return 200_000 }
        if modelID.contains("deepseek") || serviceType == "deepseek" { return 128_000 }
        if modelID.contains("sonar") || serviceType == "perplexity" { return 127_000 }
        return nil
    }
}

struct ContextCompactionResult: Sendable {
    let summary: String
    let usage: ModelTokenUsage?
}


enum ContextManagement {
    static let autoCompactionRatio = 0.85

    static func shouldCompact(inputTokens: Int, contextWindowTokens: Int) -> Bool {
        guard inputTokens > 0, contextWindowTokens > 0 else { return false }
        return Double(inputTokens) >= Double(contextWindowTokens) * autoCompactionRatio
    }

    static func estimatedTokens(in text: String) -> Int {
        // Pi uses JavaScript string length (UTF-16 code units), not UTF-8 bytes.
        let characters = text.utf16.count
        return characters / 4 + (characters % 4 == 0 ? 0 : 1)
    }

    static func resolvedUsage(
        reported: ModelTokenUsage?,
        requestMessages: [[String: String]],
        response: String
    ) -> ModelTokenUsage {
        if let reported, reported.totalTokens > 0 { return reported }
        return ModelTokenUsage(
            inputTokens: requestMessages.reduce(0) { $0 + estimatedTokens(in: $1["content"] ?? "") },
            outputTokens: estimatedTokens(in: response),
            isEstimated: true
        )
    }

    static func latestValidCheckpoint(in messages: [MessageEntity]) -> MessageEntity? {
        messages.last {
            $0.messageKind == .contextCheckpoint && $0.checkpointValid
                && $0.checkpointCoversThroughSequence > 0
        }
    }

    static func invalidateCheckpoints(in chat: ChatEntity, covering sequence: Int64) {
        for message in chat.messagesArray where message.messageKind == .contextCheckpoint {
            if message.checkpointValid, message.checkpointCoversThroughSequence >= sequence {
                message.checkpointValid = false
            }
        }
    }

    static func compactionCandidateCount(
        messages: [MessageEntity],
        inputTokens: Int,
        contextWindowTokens: Int,
        recentMessageLimit: Int
    ) -> Int {
        guard !messages.isEmpty else { return 0 }
        let desiredInputTokens = Int(Double(contextWindowTokens) * 0.65)
        let tokensToRemove = max(1, inputTokens - desiredInputTokens)
        var estimatedRemovedTokens = 0
        var pressureCount = 0
        for message in messages {
            estimatedRemovedTokens += estimatedTokens(in: message.body)
            pressureCount += 1
            if estimatedRemovedTokens >= tokensToRemove { break }
        }
        let countForConfiguredLimit = max(0, messages.count - max(2, recentMessageLimit))
        return min(messages.count, max(pressureCount, countForConfiguredLimit))
    }
}

struct ContextProjection {
    let checkpoint: MessageEntity?
    let messages: [MessageEntity]
}

extension ContextManagement {
    static func projection(in messages: [MessageEntity]) -> ContextProjection {
        let checkpoint = latestValidCheckpoint(in: messages)
        let coveredSequence = checkpoint?.checkpointCoversThroughSequence ?? 0
        return ContextProjection(
            checkpoint: checkpoint,
            messages: messages.filter {
                $0.messageKind == .message && $0.sequence > coveredSequence
            }
        )
    }
}
