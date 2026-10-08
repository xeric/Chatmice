//
// WebSearch.swift
// Chatmice
//
// Configurable web search and URL retrieval tools inspired by Cherry Studio's
// provider roster. Provider secrets are stored in Keychain via TokenManager.
//

import Foundation

enum SearchMode: String, Codable, CaseIterable, Sendable {
    case off
    case native
    case web
}

enum SearchModeStore {
    private static let storageKey = "chatmiceSearchModes"
    private static let lock = NSLock()

    static func mode(for chatID: UUID) -> SearchMode {
        lock.withLock {
            let modes = load()
            guard let rawValue = modes[chatID.uuidString] else { return .off }
            return SearchMode(rawValue: rawValue) ?? .off
        }
    }

    static func setMode(_ mode: SearchMode, for chatID: UUID) {
        lock.withLock {
            var modes = load()
            modes[chatID.uuidString] = mode.rawValue
            guard let data = try? JSONEncoder().encode(modes) else { return }
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private static func load() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
            let modes = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return modes
    }
}

enum WebSearchProviderID: String, CaseIterable, Codable, Identifiable, Sendable {
    case zhipu, tavily, searxng, exa
    case exaMCP = "exa-mcp"
    case bocha, querit, fetch, jina, firecrawl, parallel, serply

    var id: String { rawValue }
    var name: String {
        switch self {
        case .zhipu: return "Zhipu"
        case .tavily: return "Tavily"
        case .searxng: return "SearXNG"
        case .exa: return "Exa"
        case .exaMCP: return "Exa MCP"
        case .bocha: return "Bocha"
        case .querit: return "Querit"
        case .fetch: return "Fetch"
        case .jina: return "Jina"
        case .firecrawl: return "Firecrawl"
        case .parallel: return "Parallel"
        case .serply: return "Serply"
        }
    }
    var supportsSearch: Bool { self != .fetch && self != .exaMCP }
    var supportsFetch: Bool { [.fetch, .jina, .firecrawl].contains(self) }
    var requiresAPIKey: Bool { ![.searxng, .fetch, .exaMCP].contains(self) }
    var defaultHost: String {
        switch self {
        case .zhipu: return "https://open.bigmodel.cn/api/paas/v4/web_search"
        case .tavily: return "https://api.tavily.com/search"
        case .searxng: return "http://localhost:8080"
        case .exa: return "https://api.exa.ai"
        case .exaMCP: return "https://mcp.exa.ai/mcp"
        case .bocha: return "https://api.bochaai.com/v1/web-search"
        case .querit: return "https://api.querit.ai"
        case .fetch: return ""
        case .jina: return "https://s.jina.ai"
        case .firecrawl: return "https://api.firecrawl.dev/v1"
        case .parallel: return "https://api.parallel.ai/v1beta/search"
        case .serply: return "https://api.serply.io/v1/search"
        }
    }
    var detail: String {
        switch self {
        case .zhipu: return "Zhipu web search API"
        case .tavily: return "Search optimized for AI agents"
        case .searxng: return "Self-hosted metasearch; optional basic auth"
        case .exa: return "Neural and keyword search"
        case .exaMCP: return "Exa remote MCP endpoint (configure under MCP Servers)"
        case .bocha: return "Bocha AI web search"
        case .querit: return "Querit search API"
        case .fetch: return "Fetch public web pages directly"
        case .jina: return "Jina Search and Reader APIs"
        case .firecrawl: return "Search and scrape web content"
        case .parallel: return "Parallel web research API"
        case .serply: return "Google search results through Serply"
        }
    }
}

struct WebSearchProviderConfig: Codable, Equatable, Sendable, Identifiable {
    var id: WebSearchProviderID
    var enabled: Bool
    var apiHost: String
    var username: String

    init(id: WebSearchProviderID, enabled: Bool = true, apiHost: String? = nil, username: String = "") {
        self.id = id
        self.enabled = enabled
        self.apiHost = apiHost ?? id.defaultHost
        self.username = username
    }
}

struct WebSearchSettings: Codable, Equatable, Sendable {
    var enabled = false
    var defaultSearchProvider: WebSearchProviderID? = .tavily
    var defaultFetchProvider: WebSearchProviderID = .fetch
    var maxResults = 5
    var providers = WebSearchProviderID.allCases.map { WebSearchProviderConfig(id: $0) }

    static let storageKey = "chatmiceWebSearchSettings"

    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
            let value = try? JSONDecoder().decode(Self.self, from: data)
        else { return Self() }
        return value
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    func provider(_ id: WebSearchProviderID) -> WebSearchProviderConfig {
        providers.first(where: { $0.id == id }) ?? WebSearchProviderConfig(id: id)
    }

    var searchAvailable: Bool {
        guard enabled, let id = defaultSearchProvider else { return false }
        let config = provider(id)
        return config.enabled && id.supportsSearch
    }

    var fetchAvailable: Bool {
        let config = provider(defaultFetchProvider)
        return enabled && config.enabled && defaultFetchProvider.supportsFetch
    }

    static func apiKey(for id: WebSearchProviderID) -> String {
        (try? TokenManager.getToken(for: "web-search", identifier: id.rawValue)) ?? ""
    }

    static func setAPIKey(_ key: String, for id: WebSearchProviderID) throws {
        if key.isEmpty {
            try TokenManager.deleteToken(for: "web-search", identifier: id.rawValue)
        }
        else {
            try TokenManager.setToken(key, for: "web-search", identifier: id.rawValue)
        }
    }

    static func password(for id: WebSearchProviderID) -> String {
        (try? TokenManager.getToken(for: "web-search-password", identifier: id.rawValue)) ?? ""
    }

    static func setPassword(_ password: String, for id: WebSearchProviderID) throws {
        if password.isEmpty {
            try TokenManager.deleteToken(for: "web-search-password", identifier: id.rawValue)
        }
        else {
            try TokenManager.setToken(password, for: "web-search-password", identifier: id.rawValue)
        }
    }
}

struct WebSearchTool: AgentTool {
    let definition = ToolDefinition(
        name: "web_search",
        description: "Search the current web for up-to-date information. Returns titles, URLs, and relevant excerpts.",
        parameters: .object(properties: ["query": .string], required: ["query"], additionalProperties: nil)
    )

    func call(arguments: String, context: ToolContext) async throws -> String {
        guard let query = ToolArguments.string("query", in: arguments), !query.isEmpty else {
            throw ToolError.invalidArguments("web_search requires query: string")
        }
        return try await WebSearchClient().search(query: query, settings: .load())
    }
}

struct WebFetchTool: AgentTool {
    let definition = ToolDefinition(
        name: "web_fetch",
        description: "Retrieve readable content from a public HTTP or HTTPS URL.",
        parameters: .object(properties: ["url": .string], required: ["url"], additionalProperties: nil)
    )

    func call(arguments: String, context: ToolContext) async throws -> String {
        guard let value = ToolArguments.string("url", in: arguments), let url = URL(string: value),
            ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        else {
            throw ToolError.invalidArguments("web_fetch requires a public http(s) url")
        }
        return try await WebSearchClient().fetch(url: url, settings: .load())
    }
}

private enum ToolArguments {
    static func string(_ key: String, in arguments: String) -> String? {
        guard let data = arguments.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object[key] as? String
    }
}

struct WebSearchClient: Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func search(query: String, settings: WebSearchSettings) async throws -> String {
        guard settings.searchAvailable, let provider = settings.defaultSearchProvider else {
            throw ToolError.executionFailed("Web search is disabled in Settings > Web Search")
        }
        let config = settings.provider(provider)
        if provider.requiresAPIKey && WebSearchSettings.apiKey(for: provider).isEmpty {
            throw ToolError.executionFailed("Add an API key for \(provider.name) in Settings > Web Search")
        }
        let request = try makeSearchRequest(
            provider: provider,
            config: config,
            query: query,
            limit: settings.maxResults
        )
        let data = try await perform(request)
        return try formatSearchResponse(data, provider: provider, limit: settings.maxResults)
    }

    func fetch(url: URL, settings: WebSearchSettings) async throws -> String {
        let provider = settings.defaultFetchProvider
        let config = settings.provider(provider)
        guard settings.enabled, config.enabled, provider.supportsFetch else {
            throw ToolError.executionFailed("The selected URL retrieval provider is disabled or unavailable")
        }
        var request: URLRequest
        switch provider {
        case .jina:
            guard
                let endpoint = URL(
                    string: normalizedHost(config, fallback: provider.defaultHost) + "/" + url.absoluteString
                )
            else {
                throw ToolError.executionFailed("Invalid Jina API host")
            }
            request = URLRequest(url: endpoint)
            addBearer(&request, provider: provider)
            request.setValue("text/plain", forHTTPHeaderField: "Accept")
        case .firecrawl:
            request = try postRequest(
                url: endpoint(config, suffix: "/scrape"),
                provider: provider,
                body: ["url": url.absoluteString, "formats": ["markdown"]]
            )
        case .fetch:
            request = URLRequest(url: url)
            request.setValue("text/html, text/plain, application/json", forHTTPHeaderField: "Accept")
        case .exaMCP:
            throw ToolError.executionFailed(
                "Exa MCP is exposed through MCP Servers; select Jina, Firecrawl, or Fetch for web_fetch"
            )
        default:
            throw ToolError.executionFailed("\(provider.name) does not retrieve URLs")
        }
        let data = try await perform(request)
        if provider == .firecrawl, let object = jsonObject(data),
            let body = (object["data"] as? [String: Any])?["markdown"] as? String
        {
            return capped(body)
        }
        return capped(String(decoding: data, as: UTF8.self))
    }

    func check(provider: WebSearchProviderID, config: WebSearchProviderConfig) async throws {
        if provider == .fetch {
            guard let url = URL(string: "https://example.com") else { return }
            _ = try await perform(URLRequest(url: url))
        }
        else if provider == .exaMCP {
            guard let url = URL(string: config.apiHost) else { throw ToolError.executionFailed("Invalid endpoint URL") }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            _ = try await perform(request, accept: 200...499)
        }
        else if provider.supportsSearch {
            var settings = WebSearchSettings()
            settings.enabled = true
            settings.defaultSearchProvider = provider
            settings.maxResults = 1
            settings.providers = [config]
            _ = try await search(query: "Chatmice", settings: settings)
        }
    }

    private func makeSearchRequest(
        provider: WebSearchProviderID,
        config: WebSearchProviderConfig,
        query: String,
        limit: Int
    ) throws -> URLRequest {
        switch provider {
        case .tavily:
            return try postRequest(
                url: endpoint(config),
                provider: provider,
                body: [
                    "api_key": WebSearchSettings.apiKey(for: provider), "query": query, "max_results": limit,
                    "include_answer": false,
                ]
            )
        case .exa:
            return try postRequest(
                url: endpoint(config, suffix: "/search"),
                provider: provider,
                body: ["query": query, "numResults": limit, "contents": ["text": ["maxCharacters": 2000]]],
                apiKeyHeader: "x-api-key"
            )
        case .searxng:
            var components = URLComponents(url: try endpoint(config, suffix: "/search"), resolvingAgainstBaseURL: false)
            components?.queryItems = [
                URLQueryItem(name: "q", value: query), URLQueryItem(name: "format", value: "json"),
                URLQueryItem(name: "pageno", value: "1"),
            ]
            guard let url = components?.url else { throw ToolError.executionFailed("Invalid SearXNG URL") }
            var request = URLRequest(url: url)
            let username = config.username
            if !username.isEmpty {
                let token = Data("\(username):\(WebSearchSettings.password(for: provider))".utf8).base64EncodedString()
                request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
            }
            return request
        case .jina:
            return try postRequest(url: endpoint(config), provider: provider, body: ["q": query, "count": limit])
        case .firecrawl:
            return try postRequest(
                url: endpoint(config, suffix: "/search"),
                provider: provider,
                body: ["query": query, "limit": limit]
            )
        case .zhipu:
            return try postRequest(
                url: endpoint(config),
                provider: provider,
                body: ["search_query": query, "search_engine": "search_std", "count": limit]
            )
        case .bocha:
            return try postRequest(
                url: endpoint(config),
                provider: provider,
                body: ["query": query, "count": limit, "summary": true]
            )
        case .parallel:
            return try postRequest(
                url: endpoint(config),
                provider: provider,
                body: ["objective": query, "search_queries": [query], "max_results": limit],
                apiKeyHeader: "x-api-key"
            )
        case .serply:
            return try postRequest(
                url: endpoint(config),
                provider: provider,
                body: ["q": query, "num": limit],
                apiKeyHeader: "X-Api-Key"
            )
        case .querit:
            return try postRequest(
                url: endpoint(config, suffix: "/search"),
                provider: provider,
                body: ["query": query, "limit": limit]
            )
        case .fetch, .exaMCP:
            throw ToolError.executionFailed("\(provider.name) is not a direct search provider")
        }
    }

    private func postRequest(url: URL, provider: WebSearchProviderID, body: [String: Any], apiKeyHeader: String? = nil)
        throws -> URLRequest
    {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKeyHeader {
            request.setValue(WebSearchSettings.apiKey(for: provider), forHTTPHeaderField: apiKeyHeader)
        }
        else if provider != .tavily {
            addBearer(&request, provider: provider)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func addBearer(_ request: inout URLRequest, provider: WebSearchProviderID) {
        let key = WebSearchSettings.apiKey(for: provider)
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
    }

    private func endpoint(_ config: WebSearchProviderConfig, suffix: String = "") throws -> URL {
        let base = normalizedHost(config, fallback: config.id.defaultHost)
        guard let url = URL(string: base + suffix) else {
            throw ToolError.executionFailed("Invalid \(config.id.name) API host")
        }
        return url
    }

    private func normalizedHost(_ config: WebSearchProviderConfig, fallback: String) -> String {
        let host = config.apiHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : config.apiHost
        return host.hasSuffix("/") ? String(host.dropLast()) : host
    }

    private func perform(_ request: URLRequest, accept: ClosedRange<Int> = 200...299) async throws -> Data {
        var request = request
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, accept.contains(http.statusCode) else {
            let message = String(decoding: data.prefix(1000), as: UTF8.self)
            throw ToolError.executionFailed("Web provider request failed: \(message)")
        }
        return data
    }

    private func formatSearchResponse(_ data: Data, provider: WebSearchProviderID, limit: Int) throws -> String {
        guard let object = jsonObject(data) else {
            let text = String(decoding: data, as: UTF8.self)
            guard !text.isEmpty else { throw ToolError.executionFailed("Web provider returned an empty response") }
            return capped(text)
        }
        let arrays: [[String: Any]] = {
            if let values = object["results"] as? [[String: Any]] { return values }
            if let values = object["data"] as? [[String: Any]] { return values }
            if let data = object["data"] as? [String: Any] {
                if let values = data["results"] as? [[String: Any]] { return values }
                if let values = (data["webPages"] as? [String: Any])?["value"] as? [[String: Any]] { return values }
            }
            if let values = object["organic"] as? [[String: Any]] { return values }
            if let values = object["webPages"] as? [[String: Any]] { return values }
            return []
        }()
        let lines = arrays.prefix(max(1, limit)).enumerated().map { index, item in
            let title = string(item, keys: ["title", "name"]) ?? "Result \(index + 1)"
            let url = string(item, keys: ["url", "link", "href"]) ?? ""
            let content = string(item, keys: ["content", "text", "snippet", "description", "summary"]) ?? ""
            return "\(index + 1). \(title)\n\(url)\n\(content)"
        }
        if !lines.isEmpty { return capped(lines.joined(separator: "\n\n")) }
        return capped(
            String(
                decoding: try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
                as: UTF8.self
            )
        )
    }

    private func jsonObject(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
    private func string(_ object: [String: Any], keys: [String]) -> String? {
        for key in keys { if let value = object[key] as? String, !value.isEmpty { return value } }
        return nil
    }
    private func capped(_ value: String) -> String { String(value.prefix(30_000)) }
}
