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

    init() { credentialID = UUID().uuidString }

    private enum CodingKeys: String, CodingKey {
        case grant, authorizationURL, tokenURL, clientID, scope, resource, redirectURI, credentialID
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        grant = try values.decodeIfPresent(Grant.self, forKey: .grant) ?? .authorizationCode
        authorizationURL = try values.decodeIfPresent(String.self, forKey: .authorizationURL) ?? ""
        tokenURL = try values.decode(String.self, forKey: .tokenURL)
        clientID = try values.decode(String.self, forKey: .clientID)
        scope = try values.decodeIfPresent(String.self, forKey: .scope) ?? ""
        resource = try values.decodeIfPresent(String.self, forKey: .resource) ?? ""
        redirectURI = try values.decodeIfPresent(String.self, forKey: .redirectURI) ?? "chatmice://oauth/callback"
        if let savedID = try values.decodeIfPresent(String.self, forKey: .credentialID) {
            credentialID = savedID
        } else {
            // Encode a tuple rather than concatenating ambiguous field boundaries.
            let identity = try JSONEncoder().encode([clientID, redirectURI, tokenURL])
            credentialID = "legacy-" + SHA256.hash(data: identity).description
        }
    }

    func validate() throws {
        _ = try Self.endpoint(tokenURL)
        guard !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPOAuthError.message("OAuth Client ID is required")
        }
        if grant == .authorizationCode {
            _ = try Self.endpoint(authorizationURL)
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
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else {
            throw MCPOAuthError.message("OAuth endpoints require HTTPS (HTTP is allowed only on loopback)")
        }
        return url
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
    private let session = URLSession(configuration: .ephemeral, delegate: AuthOriginRedirectDelegate(), delegateQueue: nil)

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
        if includingSecret { try TokenManager.deleteToken(for: secretKey(config)) }
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

    private func obtain(_ config: MCPOAuthConfiguration, interactive: Bool) async throws -> String {
        let stored = try TokenManager.getToken(for: Self.tokenKey(config))
        let cached = try stored.map { try JSONDecoder().decode(Token.self, from: Data($0.utf8)) }
        if let cached, cached.expiresAt.map({ $0 > Date().addingTimeInterval(30) }) ?? true {
            return cached.accessToken
        }
        var fields: [String: String] = ["client_id": config.clientID]
        let secret = try Self.secret(for: config)
        if !secret.isEmpty { fields["client_secret"] = secret }
        if !config.resource.isEmpty { fields["resource"] = config.resource }
        if let refresh = cached?.refreshToken {
            fields["grant_type"] = "refresh_token"
            fields["refresh_token"] = refresh
            do { return try await exchange(config, fields: fields, previousRefresh: refresh) }
            catch {
                // Do not loop/replay a failed refresh or hide the server error.
                try Self.clear(config)
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
        return try await exchange(config, fields: fields, previousRefresh: nil)
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

    private func exchange(_ config: MCPOAuthConfiguration, fields: [String: String], previousRefresh: String?) async throws -> String {
        var request = URLRequest(url: try MCPOAuthConfiguration.endpoint(config.tokenURL))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
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
        try TokenManager.setToken(encoded, for: Self.tokenKey(config))
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
