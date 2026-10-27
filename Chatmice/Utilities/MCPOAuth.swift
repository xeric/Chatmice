import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import Security

public struct MCPOAuthConfiguration: Codable, Hashable, Sendable {
    enum Grant: String, Codable, CaseIterable { case authorizationCode, clientCredentials }
    var grant: Grant = .authorizationCode
    var authorizationURL: String = ""
    var tokenURL: String = ""
    var clientID: String = ""
    var scope: String = ""
    var resource: String = ""
    var redirectURI: String = "chatmice://oauth/callback"
    var credentialID: String
    var metadataURL: String?

    init() { credentialID = UUID().uuidString }

    private enum CodingKeys: String, CodingKey {
        case grant, authorizationURL, tokenURL, clientID, scope, resource, redirectURI, credentialID, metadataURL
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        grant = try values.decodeIfPresent(Grant.self, forKey: .grant) ?? .authorizationCode
        authorizationURL = try values.decodeIfPresent(String.self, forKey: .authorizationURL) ?? ""
        tokenURL = try values.decodeIfPresent(String.self, forKey: .tokenURL) ?? ""
        clientID = try values.decodeIfPresent(String.self, forKey: .clientID) ?? ""
        scope = try values.decodeIfPresent(String.self, forKey: .scope) ?? ""
        resource = try values.decodeIfPresent(String.self, forKey: .resource) ?? ""
        redirectURI = try values.decodeIfPresent(String.self, forKey: .redirectURI) ?? "chatmice://oauth/callback"
        metadataURL = try values.decodeIfPresent(String.self, forKey: .metadataURL)
        if let savedID = try values.decodeIfPresent(String.self, forKey: .credentialID) {
            credentialID = savedID
        } else {
            // Encode a tuple rather than concatenating ambiguous field boundaries.
            let identity = try JSONEncoder().encode([clientID, redirectURI, metadataURL ?? tokenURL])
            credentialID = "legacy-" + SHA256.hash(data: identity).description
        }
    }

    func validate() throws {
        if let metadataURL { _ = try Self.endpoint(metadataURL) }
        else { _ = try Self.endpoint(tokenURL) }
        if clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           metadataURL == nil || grant == .clientCredentials {
            throw MCPOAuthError.message("OAuth Client ID is required")
        }
        if grant == .authorizationCode {
            if metadataURL == nil { _ = try Self.endpoint(authorizationURL) }
            _ = try Self.callbackURL(redirectURI)
        }
    }

    static func callbackURL(_ value: String) throws -> URL {
        guard let redirect = URL(string: value), redirect.user == nil, redirect.password == nil,
              redirect.query == nil, redirect.fragment == nil else {
            throw MCPOAuthError.message("Invalid OAuth redirect URI")
        }
        if redirect.scheme == "chatmice", redirect.host == "oauth", redirect.path == "/callback",
           redirect.port == nil { return redirect }
        guard redirect.scheme == "http", let host = redirect.host,
              ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host),
              let port = redirect.port, (1024...65535).contains(port),
              !redirect.path.isEmpty else {
            throw MCPOAuthError.message("Use chatmice://oauth/callback or a loopback HTTP URL with an explicit port (1024–65535) and callback path")
        }
        return redirect
    }

    static func endpoint(_ value: String) throws -> URL {
        guard let url = URL(string: value), let host = url.host, url.user == nil, url.password == nil,
              url.fragment == nil,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)) else {
            throw MCPOAuthError.message("OAuth endpoints require HTTPS (HTTP is allowed only on loopback)")
        }
        return url
    }
}

struct MCPOAuthMetadata: Decodable, Sendable {
    let issuer: String
    let authorization_endpoint: String?
    let token_endpoint: String
    let registration_endpoint: String?
    let token_endpoint_auth_methods_supported: [String]?
    let code_challenge_methods_supported: [String]?
    let grant_types_supported: [String]?

    func validate(for config: MCPOAuthConfiguration, hasClientSecret: Bool, hasRegisteredClient: Bool = false) throws {
        _ = try MCPOAuthConfiguration.endpoint(token_endpoint)
        let grant = config.grant == .authorizationCode ? "authorization_code" : "client_credentials"
        if let grants = grant_types_supported, !grants.contains(grant) {
            throw MCPOAuthError.message("Server configuration does not support the selected grant. Use Manual Configuration.")
        }
        let methods = token_endpoint_auth_methods_supported ?? ["client_secret_basic"]
        if config.grant == .authorizationCode {
            guard let authorization_endpoint, !authorization_endpoint.isEmpty else {
                throw MCPOAuthError.message("Server configuration is missing authorization_endpoint. Use Manual Configuration.")
            }
            _ = try MCPOAuthConfiguration.endpoint(authorization_endpoint)
            guard code_challenge_methods_supported?.contains("S256") == true else {
                throw MCPOAuthError.message("Server configuration does not advertise PKCE S256. Use Manual Configuration.")
            }
            if config.clientID.isEmpty && !hasRegisteredClient {
                guard let registration_endpoint, methods.contains("none") else {
                    throw MCPOAuthError.message("No registered client or automatic public-client registration is available. Use Manual Configuration.")
                }
                _ = try MCPOAuthConfiguration.endpoint(registration_endpoint)
            } else if !config.clientID.isEmpty && !hasClientSecret && !methods.contains("none") {
                throw MCPOAuthError.message("This server requires client credentials. Use Manual Configuration.")
            }
        } else if config.clientID.isEmpty || !hasClientSecret {
            throw MCPOAuthError.message("Client credentials are missing. Use Manual Configuration.")
        }
        if hasClientSecret && !methods.contains("client_secret_post") && !methods.contains("client_secret_basic") {
            throw MCPOAuthError.message("Server configuration has no supported client authentication method. Use Manual Configuration.")
        }
    }
}

struct MCPOAuthDiscovery: Sendable {
    struct Result: Sendable {
        let url: URL
        let metadata: MCPOAuthMetadata
        var resource: String?
    }
    private struct ResourceMetadata: Decodable {
        let resource: String
        let authorization_servers: [String]
    }
    let session: URLSession
    static let shared = MCPOAuthDiscovery(session: URLSession(
        configuration: .ephemeral, delegate: AuthOriginRedirectDelegate(), delegateQueue: nil
    ))

    static func metadataURLs(issuer: URL) -> [URL] {
        var base = URLComponents(url: issuer, resolvingAgainstBaseURL: false)!
        let path = base.percentEncodedPath == "/" ? "" : base.percentEncodedPath
        base.query = nil
        base.fragment = nil
        let paths = ["/.well-known/oauth-authorization-server" + path,
                     "/.well-known/openid-configuration" + path,
                     path + "/.well-known/openid-configuration"]
        var seen = Set<URL>()
        return paths.compactMap { path in
            base.percentEncodedPath = path
            guard let url = base.url, seen.insert(url).inserted else { return nil }
            return url
        }
    }

    func load(_ url: URL, expectedIssuer: String? = nil) async throws -> MCPOAuthMetadata {
        let data = try await document(url)
        let metadata = try JSONDecoder().decode(MCPOAuthMetadata.self, from: data)
        let issuer = try MCPOAuthConfiguration.endpoint(metadata.issuer)
        let matchesLocation = url.path.contains("/.well-known/")
            ? Self.metadataURLs(issuer: issuer).contains(url)
            : AuthOriginRedirectDelegate.sameOrigin(url, issuer)
        guard issuer.query == nil,
              expectedIssuer.map({ $0 == metadata.issuer }) ?? matchesLocation else {
            throw MCPOAuthError.message("OAuth metadata issuer does not match the requested authorization server")
        }
        _ = try MCPOAuthConfiguration.endpoint(metadata.token_endpoint)
        if let value = metadata.authorization_endpoint { _ = try MCPOAuthConfiguration.endpoint(value) }
        if let value = metadata.registration_endpoint { _ = try MCPOAuthConfiguration.endpoint(value) }
        return metadata
    }

    private func document(_ url: URL) async throws -> Data {
        var request = URLRequest(url: try MCPOAuthConfiguration.endpoint(url.absoluteString))
        request.timeoutInterval = 5
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), data.count <= 1_048_576 else {
            throw MCPOAuthError.message("OAuth metadata request failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))")
        }
        return data
    }

    func discover(serverURL: String, authorizationHint: String = "") async throws -> Result? {
        let server = try MCPOAuthConfiguration.endpoint(serverURL)
        var base = URLComponents(url: server, resolvingAgainstBaseURL: false)!
        let resourcePath = base.percentEncodedPath == "/" ? "" : base.percentEncodedPath
        base.query = nil
        base.fragment = nil
        var resourceURLs: [URL] = []
        // Probe without credentials. A short deadline also bounds public SSE endpoints.
        var probe = URLRequest(url: server)
        probe.timeoutInterval = 3
        probe.httpShouldHandleCookies = false
        probe.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let (_, response) = try? await session.data(for: probe),
           let http = response as? HTTPURLResponse, http.statusCode == 401,
           let challenge = http.value(forHTTPHeaderField: "WWW-Authenticate"),
           let regex = try? NSRegularExpression(pattern: #"(?i)\bresource_metadata\s*=\s*"([^"]+)""#),
           let match = regex.firstMatch(in: challenge, range: NSRange(location: 0, length: challenge.utf16.count)),
           let range = Range(match.range(at: 1), in: challenge) {
            resourceURLs.append(try MCPOAuthConfiguration.endpoint(String(challenge[range])))
        }
        for path in ["/.well-known/oauth-protected-resource" + resourcePath, "/.well-known/oauth-protected-resource"] {
            base.percentEncodedPath = path
            if let url = base.url, !resourceURLs.contains(url) { resourceURLs.append(url) }
        }
        for url in resourceURLs {
            try Task.checkCancellation()
            guard let data = try? await document(url),
                  let resource = try? JSONDecoder().decode(ResourceMetadata.self, from: data) else { continue }
            guard resource.resource == server.absoluteString, let issuerString = resource.authorization_servers.first else {
                throw MCPOAuthError.message("OAuth resource metadata does not describe this MCP server")
            }
            let issuer = try MCPOAuthConfiguration.endpoint(issuerString)
            for candidate in Self.metadataURLs(issuer: issuer) {
                try Task.checkCancellation()
                if let metadata = try? await load(candidate, expectedIssuer: issuerString) {
                    return Result(url: candidate, metadata: metadata, resource: resource.resource)
                }
            }
            throw MCPOAuthError.message("The advertised authorization server has no valid OAuth configuration")
        }
        // Older MCP deployments may publish AS metadata directly, or use a preconfigured issuer.
        base.percentEncodedPath = ""
        var issuers = [base.url!]
        if let hint = try? MCPOAuthConfiguration.endpoint(authorizationHint),
           var hintBase = URLComponents(url: hint, resolvingAgainstBaseURL: false) {
            hintBase.path = ""; hintBase.query = nil
            if let root = hintBase.url, !issuers.contains(root) { issuers.insert(root, at: 0) }
        }
        for issuer in issuers {
            for candidate in Self.metadataURLs(issuer: issuer) {
                try Task.checkCancellation()
                if let metadata = try? await load(candidate, expectedIssuer: issuer.absoluteString) {
                    return Result(url: candidate, metadata: metadata, resource: nil)
                }
            }
        }
        try Task.checkCancellation()
        return nil
    }
}


enum MCPOAuthError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// Refuse cross-origin redirects rather than forwarding credentials to another host.
final class AuthOriginRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static func sameOrigin(_ first: URL, _ second: URL) -> Bool {
        func port(_ url: URL) -> Int? { url.port ?? (url.scheme == "https" ? 443 : 80) }
        return first.scheme?.lowercased() == second.scheme?.lowercased()
            && first.host?.lowercased() == second.host?.lowercased() && port(first) == port(second)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let original = task.originalRequest?.url, let next = request.url,
              Self.sameOrigin(original, next) else { completionHandler(nil); return }
        completionHandler(request)
    }
}

@MainActor
final class MCPOAuthBrowser: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
    func authorize(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let authentication = ASWebAuthenticationSession(url: url, callbackURLScheme: "chatmice") { callback, error in
                if let error { continuation.resume(throwing: error) }
                else if let callback { continuation.resume(returning: callback) }
                else { continuation.resume(throwing: MCPOAuthError.message("OAuth callback missing")) }
            }
            authentication.presentationContextProvider = self
            session = authentication
            if !authentication.start() {
                continuation.resume(throwing: MCPOAuthError.message("Cannot start OAuth sign-in"))
            }
        }
    }
}

actor MCPOAuthManager {
    static let shared = MCPOAuthManager()
    private struct Token: Codable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
    }
    private var inFlight: [String: Task<String, Error>] = [:]
    private let session: URLSession

    init(session: URLSession = URLSession(configuration: .ephemeral, delegate: AuthOriginRedirectDelegate(), delegateQueue: nil)) {
        self.session = session
    }

    private struct Registration: Codable {
        let client_id: String
        let client_secret: String?
    }

    private static func registrationKey(_ config: MCPOAuthConfiguration) -> String {
        let identity = try! JSONEncoder().encode([config.metadataURL ?? "", config.redirectURI])
        return "mcp_oauth_registration_" + config.credentialID + "_" + SHA256.hash(data: identity).description
    }

    static func hasRegisteredClient(_ config: MCPOAuthConfiguration) -> Bool {
        guard let stored = try? TokenManager.getToken(for: registrationKey(config)),
              let registration = try? JSONDecoder().decode(Registration.self, from: Data(stored.utf8)) else { return false }
        return !registration.client_id.isEmpty
    }

    private func register(_ config: MCPOAuthConfiguration, metadata: MCPOAuthMetadata) async throws -> Registration {
        let key = Self.registrationKey(config)
        if let stored = try TokenManager.getToken(for: key) {
            return try JSONDecoder().decode(Registration.self, from: Data(stored.utf8))
        }
        guard let endpoint = metadata.registration_endpoint else {
            throw MCPOAuthError.message("This authorization server does not support automatic client registration. Enter its Client ID in Client Settings.")
        }
        var request = URLRequest(url: try MCPOAuthConfiguration.endpoint(endpoint))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_name": "Chatmice", "redirect_uris": [config.redirectURI],
            "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"],
            "token_endpoint_auth_method": "none"
        ])
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw MCPOAuthError.message("Automatic OAuth client registration failed. Enter a registered Client ID in Client Settings.")
        }
        let registration = try JSONDecoder().decode(Registration.self, from: data)
        guard !registration.client_id.isEmpty else { throw MCPOAuthError.message("Client registration returned no Client ID") }
        try TokenManager.setToken(String(decoding: try JSONEncoder().encode(registration), as: UTF8.self), for: key)
        return registration
    }

    static func secretKey(_ config: MCPOAuthConfiguration) -> String { "mcp_oauth_secret_" + config.credentialID }
    private static func tokenKey(_ config: MCPOAuthConfiguration) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(config)) ?? Data()
        return "mcp_oauth_token_" + config.credentialID + "_" + SHA256.hash(data: data).description
    }
    static func setSecret(_ secret: String, for config: MCPOAuthConfiguration) throws {
        if try Self.secret(for: config) != secret { try Self.clear(config) }
        try TokenManager.setToken(secret, for: secretKey(config))
    }
    static func secret(for config: MCPOAuthConfiguration) throws -> String {
        try TokenManager.getToken(for: secretKey(config)) ?? ""
    }
    static func clear(_ config: MCPOAuthConfiguration, includingSecret: Bool = false) throws {
        try TokenManager.deleteToken(for: tokenKey(config))
        if includingSecret {
            try TokenManager.deleteToken(for: secretKey(config))
            try TokenManager.deleteToken(for: registrationKey(config))
        }
    }

    static func hasAuthorization(_ config: MCPOAuthConfiguration) throws -> Bool {
        guard let stored = try TokenManager.getToken(for: tokenKey(config)) else { return false }
        let token = try JSONDecoder().decode(Token.self, from: Data(stored.utf8))
        return !token.accessToken.isEmpty
            && ((token.expiresAt.map { $0 > Date() } ?? true) || !(token.refreshToken ?? "").isEmpty)
    }

    func signOut(_ config: MCPOAuthConfiguration) throws {
        inFlight[Self.tokenKey(config)]?.cancel()
        try Self.clear(config)
    }

    func accessToken(for config: MCPOAuthConfiguration, interactive: Bool = false) async throws -> String {
        try config.validate()
        let key = Self.tokenKey(config)
        if let pending = inFlight[key] { return try await pending.value }
        let pending = Task { try await self.obtain(config, interactive: interactive) }
        inFlight[key] = pending
        defer { inFlight[key] = nil }
        return try await pending.value
    }

    private func obtain(_ original: MCPOAuthConfiguration, interactive: Bool) async throws -> String {
        let storageKey = Self.tokenKey(original)
        let stored = try TokenManager.getToken(for: storageKey)
        let cached = try stored.map { try JSONDecoder().decode(Token.self, from: Data($0.utf8)) }
        if let cached, cached.expiresAt.map({ $0 > Date().addingTimeInterval(30) }) ?? true {
            return cached.accessToken
        }
        var config = original
        var secret = try Self.secret(for: original)
        var authenticationMethod = "client_secret_post"
        if let metadataURL = original.metadataURL {
            let metadata = try await MCPOAuthDiscovery(session: session).load(try MCPOAuthConfiguration.endpoint(metadataURL))
            try metadata.validate(for: config, hasClientSecret: !secret.isEmpty, hasRegisteredClient: Self.hasRegisteredClient(config))
            config.authorizationURL = metadata.authorization_endpoint ?? ""
            config.tokenURL = metadata.token_endpoint
            if config.clientID.isEmpty {
                guard interactive || cached?.refreshToken != nil else {
                    throw MCPOAuthError.message("OAuth sign-in required. Use Sign In in MCP Settings.")
                }
                let registration = try await register(config, metadata: metadata)
                config.clientID = registration.client_id
                secret = registration.client_secret ?? ""
            }
            let methods = metadata.token_endpoint_auth_methods_supported ?? ["client_secret_basic"]
            if !secret.isEmpty {
                if methods.contains("client_secret_post") { authenticationMethod = "client_secret_post" }
                else if methods.contains("client_secret_basic") { authenticationMethod = "client_secret_basic" }
                else { throw MCPOAuthError.message("The OAuth server does not support this client's authentication method") }
            }
        }
        try Task.checkCancellation()
        var fields: [String: String] = ["client_id": config.clientID]
        if !secret.isEmpty { fields["client_secret"] = secret }
        if !config.resource.isEmpty { fields["resource"] = config.resource }
        if let refresh = cached?.refreshToken {
            fields["grant_type"] = "refresh_token"
            fields["refresh_token"] = refresh
            do { return try await exchange(config, fields: fields, previousRefresh: refresh, storageKey: storageKey, authenticationMethod: authenticationMethod) }
            catch {
                // Do not loop/replay a failed refresh or hide the server error.
                try Self.clear(original)
                throw error
            }
        }
        if !config.scope.isEmpty { fields["scope"] = config.scope }
        switch config.grant {
        case .clientCredentials:
            guard !secret.isEmpty else { throw MCPOAuthError.message("OAuth client secret is required") }
            fields["grant_type"] = "client_credentials"
        case .authorizationCode:
            guard interactive else {
                throw MCPOAuthError.message("OAuth sign-in required. Use Sign In in MCP Settings.")
            }
            let verifier = try Self.randomURLSafe()
            let state = try Self.randomURLSafe()
            let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
            var components = URLComponents(url: try MCPOAuthConfiguration.endpoint(config.authorizationURL), resolvingAgainstBaseURL: false)!
            let authorizationFields = ["response_type": "code", "client_id": config.clientID,
                                       "redirect_uri": config.redirectURI, "state": state,
                                       "code_challenge": challenge, "code_challenge_method": "S256",
                                       "scope": config.scope, "resource": config.resource]
            let reserved = Set(authorizationFields.keys)
            components.queryItems = (components.queryItems ?? []).filter { !reserved.contains($0.name) }
                + authorizationFields.filter { !$0.value.isEmpty }.map { URLQueryItem(name: $0.key, value: $0.value) }
            guard let authorizationURL = components.url else { throw MCPOAuthError.message("Invalid authorization URL") }
            let browser = await MCPOAuthBrowser()
            let callback: URL
            if try Self.isLoopbackCallback(config.redirectURI) {
                let receiver = await MCPOAuthLoopbackReceiver()
                callback = try await receiver.authorize(authorizationURL, redirectURI: config.redirectURI, state: state)
            } else {
                callback = try await browser.authorize(authorizationURL)
            }
            let code = try Self.authorizationCode(callback: callback, redirectURI: config.redirectURI, state: state)
            fields["grant_type"] = "authorization_code"
            fields["code"] = code
            fields["code_verifier"] = verifier
            fields["redirect_uri"] = config.redirectURI
        }
        return try await exchange(config, fields: fields, previousRefresh: nil, storageKey: storageKey, authenticationMethod: authenticationMethod)
    }

    private static func isLoopbackCallback(_ redirectURI: String) throws -> Bool {
        try MCPOAuthConfiguration.callbackURL(redirectURI).scheme == "http"
    }

    static func authorizationCode(callback: URL, redirectURI: String, state: String) throws -> String {
        guard let expected = URL(string: redirectURI), AuthOriginRedirectDelegate.sameOrigin(expected, callback),
              callback.path == expected.path, callback.fragment == nil,
              let components = URLComponents(url: callback, resolvingAgainstBaseURL: false) else {
            throw MCPOAuthError.message("Unexpected OAuth callback")
        }
        let items = components.queryItems ?? []
        guard items.filter({ $0.name == "state" }).count == 1,
              items.first(where: { $0.name == "state" })?.value == state else {
            throw MCPOAuthError.message("OAuth state verification failed")
        }
        if items.contains(where: { $0.name == "error" }) { throw MCPOAuthError.message("OAuth authorization was denied") }
        guard items.filter({ $0.name == "code" }).count == 1,
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw MCPOAuthError.message("OAuth authorization code missing")
        }
        return code
    }

    private func exchange(_ config: MCPOAuthConfiguration, fields: [String: String], previousRefresh: String?,
                          storageKey: String, authenticationMethod: String) async throws -> String {
        var request = URLRequest(url: try MCPOAuthConfiguration.endpoint(config.tokenURL))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var fields = fields
        if authenticationMethod == "client_secret_basic", let secret = fields.removeValue(forKey: "client_secret") {
            let client = fields.removeValue(forKey: "client_id") ?? config.clientID
            let encodedClient = String(Self.formEncode(["": client]).dropFirst())
            let encodedSecret = String(Self.formEncode(["": secret]).dropFirst())
            let credential = Data("\(encodedClient):\(encodedSecret)".utf8).base64EncodedString()
            request.setValue("Basic " + credential, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = Data(Self.formEncode(fields).utf8)
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw MCPOAuthError.message("OAuth token request failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)). Check credentials and grant configuration.")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String, !access.isEmpty,
              (json["token_type"] as? String)?.lowercased() == "bearer",
              !access.contains("\r"), !access.contains("\n") else {
            throw MCPOAuthError.message("OAuth endpoint did not return a valid Bearer token")
        }
        let expires = (json["expires_in"] as? NSNumber)?.doubleValue
            ?? (json["expires_in"] as? String).flatMap(Double.init)
        let token = Token(accessToken: access, refreshToken: json["refresh_token"] as? String ?? previousRefresh,
                          expiresAt: expires.map { Date().addingTimeInterval($0) })
        let encoded = String(decoding: try JSONEncoder().encode(token), as: UTF8.self)
        try TokenManager.setToken(encoded, for: storageKey)
        return access
    }

    static func formEncode(_ fields: [String: String]) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return fields.sorted { $0.key < $1.key }.map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&")
    }
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private static func randomURLSafe() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw MCPOAuthError.message("Cannot generate OAuth security parameters")
        }
        return base64URL(Data(bytes))
    }
}
