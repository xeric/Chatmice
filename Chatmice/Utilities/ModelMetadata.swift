//
//  ModelMetadata.swift
//  Chatmice
//

import Foundation

struct ModelMetadata: Codable, Equatable, Sendable {
    struct Limits: Codable, Equatable, Sendable {
        let context: Int
        let output: Int?
    }

    struct Modalities: Codable, Equatable, Sendable {
        let input: [String]
        let output: [String]
    }

    let id: String
    let canonicalModelID: String?
    let limit: Limits
    let modalities: Modalities
    let attachment: Bool
    let reasoning: Bool
    let toolCall: Bool
    let structuredOutput: Bool
    let temperature: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case canonicalModelID = "canonical_model_id"
        case limit
        case modalities
        case attachment
        case reasoning
        case toolCall = "tool_call"
        case structuredOutput = "structured_output"
        case temperature
    }

    var supportsVision: Bool { modalities.input.contains("image") }
    var supportsFiles: Bool { modalities.input.contains("pdf") }
    var supportsAudio: Bool { modalities.input.contains("audio") }
}

extension ModelMetadata {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        canonicalModelID = try container.decodeIfPresent(String.self, forKey: .canonicalModelID)
        limit = try container.decode(Limits.self, forKey: .limit)
        modalities = try container.decodeIfPresent(Modalities.self, forKey: .modalities)
            ?? Modalities(input: ["text"], output: ["text"])
        attachment = try container.decodeIfPresent(Bool.self, forKey: .attachment) ?? false
        reasoning = try container.decodeIfPresent(Bool.self, forKey: .reasoning) ?? false
        toolCall = try container.decodeIfPresent(Bool.self, forKey: .toolCall) ?? false
        structuredOutput = try container.decodeIfPresent(Bool.self, forKey: .structuredOutput) ?? false
        temperature = try container.decodeIfPresent(Bool.self, forKey: .temperature) ?? true
    }
}

enum ModelMetadataSource: Equatable, Sendable {
    case builtIn
    case remoteCache
}

struct ModelMetadataResolution: Sendable {
    let metadata: ModelMetadata
    let source: ModelMetadataSource
}

final class ModelMetadataCatalog: @unchecked Sendable {
    static let shared = ModelMetadataCatalog()
    static let didChangeNotification = Notification.Name("ModelMetadataCatalog.didChange")

    private struct CacheEntry: Codable {
        var metadata: ModelMetadata?
        var etag: String?
        var checkedAt: Date
        var notFound: Bool
    }

    private struct RemoteTarget {
        let provider: String
        let modelID: String

        var key: String { "\(provider)/\(modelID)".lowercased() }
    }

    private static let cacheLifetime: TimeInterval = 7 * 24 * 60 * 60
    private static let negativeCacheLifetime: TimeInterval = 24 * 60 * 60
    private static let endpointRoot = "https://basellm.github.io/llm-metadata/api/models/"

    private let lock = NSLock()
    private let session: URLSession
    private let cacheURL: URL
    private var cache: [String: CacheEntry]
    private var inFlight = Set<String>()
    private var retryAfter: [String: Date] = [:]

    init(session: URLSession = .shared, cacheURL: URL? = nil) {
        self.session = session
        self.cacheURL = cacheURL ?? Self.defaultCacheURL
        self.cache = Self.loadCache(from: self.cacheURL)
    }

    func metadata(modelID rawModelID: String, serviceType: String = "") -> ModelMetadataResolution? {
        if let metadata = Self.builtInMetadata(modelID: rawModelID) {
            return ModelMetadataResolution(metadata: metadata, source: .builtIn)
        }
        guard let target = Self.remoteTarget(modelID: rawModelID, serviceType: serviceType) else { return nil }

        let now = Date()
        var shouldFetch = false
        let cached: ModelMetadata? = lock.withLock {
            let canRetry = retryAfter[target.key].map { $0 <= now } ?? true
            if let entry = cache[target.key] {
                let lifetime = entry.notFound ? Self.negativeCacheLifetime : Self.cacheLifetime
                if now.timeIntervalSince(entry.checkedAt) >= lifetime,
                    canRetry,
                    inFlight.insert(target.key).inserted
                {
                    shouldFetch = true
                }
                return entry.metadata
            }
            if canRetry, inFlight.insert(target.key).inserted { shouldFetch = true }
            return nil
        }

        if shouldFetch { fetch(target) }
        return cached.map { ModelMetadataResolution(metadata: $0, source: .remoteCache) }
    }

    static func builtInMetadata(modelID rawModelID: String) -> ModelMetadata? {
        let modelID = normalizedModelID(rawModelID)
        if let exact = BuiltInModelMetadata.values[modelID] { return exact }

        for suffix in ["-dev-preview", "-preview"] where modelID.hasSuffix(suffix) {
            let candidate = String(modelID.dropLast(suffix.count))
            if let base = BuiltInModelMetadata.values[candidate] { return base }
        }
        if let range = modelID.range(of: #"-(?:19|20)\d{6}$"#, options: .regularExpression),
            let base = BuiltInModelMetadata.values[String(modelID[..<range.lowerBound])]
        {
            return base
        }
        return nil
    }

    static func remoteProvider(modelID rawModelID: String, serviceType: String = "") -> String? {
        remoteTarget(modelID: rawModelID, serviceType: serviceType)?.provider
    }

    private func fetch(_ target: RemoteTarget) {
        guard let url = Self.remoteURL(target) else {
            finish(target.key)
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let etag = lock.withLock({ cache[target.key]?.etag }) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        session.dataTask(with: request) { [weak self] data, response, _ in
            guard let self else { return }
            guard let http = response as? HTTPURLResponse else {
                self.finish(target.key)
                return
            }

            switch http.statusCode {
            case 200:
                guard let data,
                      let metadata = try? JSONDecoder().decode(ModelMetadata.self, from: data),
                      Self.isValid(metadata)
                else {
                    self.finish(target.key)
                    return
                }
                self.update(
                    target.key,
                    entry: CacheEntry(
                        metadata: metadata,
                        etag: http.value(forHTTPHeaderField: "ETag"),
                        checkedAt: Date(),
                        notFound: false
                    )
                )
            case 304:
                self.refresh(target.key)
            case 404:
                self.update(
                    target.key,
                    entry: CacheEntry(metadata: nil, etag: nil, checkedAt: Date(), notFound: true)
                )
            default:
                self.finish(target.key)
            }
        }.resume()
    }

    private func refresh(_ key: String) {
        let changed = lock.withLock { () -> Bool in
            guard var entry = cache[key] else {
                inFlight.remove(key)
                return false
            }
            entry.checkedAt = Date()
            cache[key] = entry
            inFlight.remove(key)
            retryAfter.removeValue(forKey: key)
            return entry.metadata != nil
        }
        persistCache()
        if changed { notifyChange(key) }
    }

    private func update(_ key: String, entry: CacheEntry) {
        lock.withLock {
            cache[key] = entry
            inFlight.remove(key)
            retryAfter.removeValue(forKey: key)
        }
        persistCache()
        if entry.metadata != nil { notifyChange(key) }
    }

    private func finish(_ key: String) {
        lock.withLock {
            inFlight.remove(key)
            retryAfter[key] = Date().addingTimeInterval(15 * 60)
        }
    }

    private func persistCache() {
        let snapshot = lock.withLock { cache }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        let directory = cacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }

    private func notifyChange(_ key: String) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: key)
        }
    }

    private static func remoteTarget(modelID rawModelID: String, serviceType: String) -> RemoteTarget? {
        var modelID = rawModelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if modelID.hasSuffix(":latest") { modelID.removeLast(7) }
        guard !modelID.isEmpty else { return nil }

        let components = modelID.split(separator: "/", maxSplits: 1).map(String.init)
        if components.count == 2, let provider = providerAlias(components[0]) {
            return RemoteTarget(provider: provider, modelID: components[1])
        }

        let candidates: [(String, [String])] = [
            ("openai", ["gpt", "chatgpt", "o1", "o3", "o4"]),
            ("anthropic", ["claude"]),
            ("google", ["gemini", "gemma"]),
            ("xai", ["grok"]),
            ("alibaba", ["qwen", "qwq", "qvq"]),
            ("zai", ["glm"]),
            ("deepseek", ["deepseek"]),
            ("moonshotai", ["kimi", "moonshot"]),
            ("minimax", ["minimax"]),
            ("mistral", ["mistral", "mixtral", "codestral", "ministral", "pixtral"]),
            ("meta", ["llama"]),
            ("cohere", ["command"]),
            ("nova", ["nova"]),
            ("perplexity", ["perplexity", "sonar"]),
            ("stepfun", ["step-"]),
            ("volcengine", ["doubao"]),
            ("xiaomi", ["mimo", "xiaomi-mimo"])
        ]
        if let provider = candidates.first(where: { candidate in
            candidate.1.contains { keyword in
                modelID == keyword || modelID.hasPrefix(keyword + "-")
                    || (keyword == "qwen" && modelID.hasPrefix(keyword))
            }
        })?.0 {
            return RemoteTarget(provider: provider, modelID: modelID)
        }

        let genericServiceTypes = ["openai", "chatgpt", "openai-responses"]
        if !genericServiceTypes.contains(serviceType.lowercased()),
            let provider = providerAlias(serviceType)
        {
            return RemoteTarget(provider: provider, modelID: modelID)
        }

        return nil
    }

    private static let providerAliases: [String: String] = [
        "openai": "openai", "chatgpt": "openai", "openai-responses": "openai",
        "anthropic": "anthropic", "claude": "anthropic",
        "google": "google", "gemini": "google",
        "xai": "xai", "grok": "xai",
        "alibaba": "alibaba", "qwen": "alibaba", "dashscope": "alibaba",
        "zai": "zai", "zhipuai": "zai", "glm": "zai",
        "deepseek": "deepseek",
        "moonshotai": "moonshotai", "moonshot": "moonshotai", "kimi": "moonshotai",
        "minimax": "minimax", "mistral": "mistral",
        "meta": "meta", "meta-llama": "meta", "llama": "meta", "cohere": "cohere",
        "nova": "nova", "amazon": "nova", "perplexity": "perplexity",
        "stepfun": "stepfun", "volcengine": "volcengine", "doubao": "volcengine",
        "xiaomi": "xiaomi", "mimo": "xiaomi"
    ]

    private static func providerAlias(_ rawValue: String) -> String? {
        providerAliases[rawValue.lowercased()]
    }

    private static func remoteURL(_ target: RemoteTarget) -> URL? {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        guard let provider = target.provider.addingPercentEncoding(withAllowedCharacters: allowed),
            let model = target.modelID.addingPercentEncoding(withAllowedCharacters: allowed)
        else { return nil }
        return URL(string: endpointRoot + provider + "/" + model + ".json")
    }

    private static func isValid(_ metadata: ModelMetadata) -> Bool {
        !metadata.id.isEmpty
            && metadata.limit.context > 0
            && metadata.limit.context <= 16_000_000
            && (metadata.limit.output ?? 0) >= 0
            && (metadata.limit.output ?? 0) <= 4_000_000
    }

    private static var defaultCacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Chatmice", isDirectory: true)
            .appendingPathComponent("model-metadata-v1.json")
    }

    private static func loadCache(from url: URL) -> [String: CacheEntry] {
        guard let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([String: CacheEntry].self, from: data)
        else { return [:] }
        return values
    }

    private static func normalizedModelID(_ rawValue: String) -> String {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let separator = value.lastIndex(of: "/") { value = String(value[value.index(after: separator)...]) }
        if value.hasSuffix(":latest") { value.removeLast(7) }
        return value
    }

}
