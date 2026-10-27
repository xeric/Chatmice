import AppKit
import SwiftUI
import XCTest
@testable import Chatmice

final class MCPOAuthDiscoveryTests: XCTestCase {
    func testMetadataModeRequiresCompleteServerCapabilitiesAndClientSetup() throws {
        var config = MCPOAuthConfiguration()
        config.clientID = "registered-public-client"
        let complete: [String: Any] = [
            "issuer": "https://auth.invalid", "authorization_endpoint": "https://auth.invalid/authorize",
            "token_endpoint": "https://auth.invalid/token", "code_challenge_methods_supported": ["S256"],
            "token_endpoint_auth_methods_supported": ["none"]
        ]
        func metadata(_ values: [String: Any]) throws -> MCPOAuthMetadata {
            try JSONDecoder().decode(MCPOAuthMetadata.self, from: JSONSerialization.data(withJSONObject: values))
        }
        try metadata(complete).validate(for: config, hasClientSecret: false)
        for missing in ["authorization_endpoint", "code_challenge_methods_supported"] {
            var values = complete
            values.removeValue(forKey: missing)
            XCTAssertThrowsError(try metadata(values).validate(for: config, hasClientSecret: false))
        }
        config.clientID = ""
        XCTAssertThrowsError(try metadata(complete).validate(for: config, hasClientSecret: false))
        var dynamic = complete
        dynamic["registration_endpoint"] = "https://auth.invalid/register"
        try metadata(dynamic).validate(for: config, hasClientSecret: false)
        try metadata(complete).validate(for: config, hasClientSecret: false, hasRegisteredClient: true)
        config.grant = .clientCredentials
        config.clientID = "registered-confidential-client"
        XCTAssertThrowsError(try metadata(complete).validate(for: config, hasClientSecret: false))
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OAuthMetadataURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override func tearDown() {
        OAuthMetadataURLProtocol.handler = nil
        super.tearDown()
    }

    func testDiscoveryFollowsResourceChallengeAndPathIssuer() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        var visited: [String] = []
        OAuthMetadataURLProtocol.handler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            let url = try XCTUnwrap(request.url)
            visited.append(url.absoluteString)
            var status = 200
            var headers = ["Content-Type": "application/json"]
            let body: String
            switch url.absoluteString {
            case "https://resource.invalid/mcp":
                status = 401
                headers["WWW-Authenticate"] = "Bearer resource_metadata=\"https://resource.invalid/custom-resource\""
                body = "{}"
            case "https://resource.invalid/custom-resource":
                body = #"{"resource":"https://resource.invalid/mcp","authorization_servers":["https://auth.invalid/tenant"]}"#
            case "https://auth.invalid/.well-known/openid-configuration/tenant":
                body = #"{"issuer":"https://auth.invalid/tenant","authorization_endpoint":"https://auth.invalid/authorize","token_endpoint":"https://auth.invalid/token"}"#
            default: status = 404; body = "{}"
            }
            return (HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!, Data(body.utf8))
        }
        let result = try await MCPOAuthDiscovery(session: session).discover(serverURL: "https://resource.invalid/mcp")
        XCTAssertEqual(result?.url.absoluteString, "https://auth.invalid/.well-known/openid-configuration/tenant")
        XCTAssertEqual(result?.metadata.token_endpoint, "https://auth.invalid/token")
        XCTAssertEqual(result?.resource, "https://resource.invalid/mcp")
        XCTAssertFalse(visited.contains("https://resource.invalid/.well-known/oauth-protected-resource"), "Advertised resource metadata takes precedence")
    }

    func testMetadataRejectsIssuerMismatchAndInsecureEndpoints() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://auth.invalid/.well-known/oauth-authorization-server/tenant")!
        for body in [
            #"{"issuer":"https://auth.invalid/other","token_endpoint":"https://auth.invalid/token"}"#,
            #"{"issuer":"https://auth.invalid/tenant","token_endpoint":"http://remote.invalid/token"}"#
        ] {
            OAuthMetadataURLProtocol.handler = { request in
                (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
            }
            do {
                _ = try await MCPOAuthDiscovery(session: session).load(url)
                XCTFail("Untrusted metadata must not supply token endpoints")
            } catch { XCTAssertTrue(error is MCPOAuthError) }
        }
    }

    func testMetadataControlsTokenEndpointAndPreservesStoredAuthorizationIdentity() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let manager = MCPOAuthManager(session: session)
        var config = MCPOAuthConfiguration()
        config.grant = .clientCredentials
        config.clientID = "isolated-client"
        config.metadataURL = "https://auth.invalid/.well-known/openid-configuration"
        config.tokenURL = "https://obsolete.invalid/never-use"
        try MCPOAuthManager.setSecret("isolated-secret", for: config)
        defer { try? MCPOAuthManager.clear(config, includingSecret: true) }
        var generation = 1
        var tokenRequests: [String] = []
        OAuthMetadataURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let body: String
            if url.path == "/.well-known/openid-configuration" {
                body = "{\"issuer\":\"https://auth.invalid\",\"token_endpoint\":\"https://auth.invalid/token-\(generation)\",\"token_endpoint_auth_methods_supported\":[\"client_secret_basic\"]}"
            } else {
                tokenRequests.append(url.absoluteString)
                XCTAssertEqual(url.host, "auth.invalid")
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic " + Data("isolated-client:isolated-secret".utf8).base64EncodedString())
                body = "{\"access_token\":\"fixture-\(generation)\",\"token_type\":\"Bearer\",\"expires_in\":3600}"
            }
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, Data(body.utf8))
        }
        let first = try await manager.accessToken(for: config)
        XCTAssertEqual(first, "fixture-1")
        XCTAssertTrue(try MCPOAuthManager.hasAuthorization(config))
        let cached = try await manager.accessToken(for: config)
        XCTAssertEqual(cached, first)
        XCTAssertEqual(tokenRequests, ["https://auth.invalid/token-1"])
        try await manager.signOut(config)
        XCTAssertFalse(try MCPOAuthManager.hasAuthorization(config))
        XCTAssertEqual(try MCPOAuthManager.secret(for: config), "isolated-secret")
        generation = 2
        let second = try await manager.accessToken(for: config)
        XCTAssertEqual(second, "fixture-2")
        XCTAssertEqual(tokenRequests.last, "https://auth.invalid/token-2", "Fetch current metadata instead of persisting a stale endpoint snapshot")
    }

    @MainActor
    func testEditingOAuthServerLoadsRemoteFieldsOnEveryPresentation() async throws {
        let suite = "mcp-editor-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var oauth = MCPOAuthConfiguration()
        oauth.authorizationURL = "https://auth.invalid/authorize"
        oauth.tokenURL = "https://auth.invalid/token"
        oauth.clientID = "editor-client"
        let server = MCPServerConfig(name: "OAuth fixture", kind: .http, url: "http://127.0.0.1:1/mcp", enabled: false, oauth: oauth)
        let local = MCPServerConfig(name: "Local fixture", command: "fixture", enabled: false)
        defaults.set(String(decoding: try JSONEncoder().encode([server, local]), as: UTF8.self), forKey: "mcpServersJSON")
        let host = NSHostingView(rootView: TabMCPServersView().defaultAppStorage(defaults).frame(width: 760).padding())
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 800, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func find(_ root: AnyObject, matching predicate: (any NSAccessibilityProtocol) -> Bool) -> (any NSAccessibilityProtocol)? {
            var visited = Set<ObjectIdentifier>()
            func visit(_ object: AnyObject) -> (any NSAccessibilityProtocol)? {
                guard visited.insert(ObjectIdentifier(object)).inserted else { return nil }
                if let node = object as? any NSAccessibilityProtocol {
                    if predicate(node) { return node }
                    for child in node.accessibilityChildren() ?? [] {
                        if let found = visit(child as AnyObject) { return found }
                    }
                }
                for child in (object as? NSView)?.subviews ?? [] {
                    if let found = visit(child) { return found }
                }
                return nil
            }
            return visit(root)
        }
        func click(_ location: NSPoint, in window: NSWindow) async throws {
            let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
            NSApp.postEvent(up, atStart: true)
            window.sendEvent(down)
            try await Task.sleep(for: .milliseconds(250))
        }
        try await Task.sleep(for: .milliseconds(150))
        for name in ["OAuth fixture", "Local fixture", "OAuth fixture"] {
            // Plain SwiftUI icon buttons have no in-process AX node on some macOS releases.
            // Hit-test the trailing edit control in this fixed-width, two-row fixture instead.
            let row = name == "OAuth fixture" ? 0 : 1
            try await click(NSPoint(x: host.bounds.width - 134, y: host.bounds.height - 88 - CGFloat(row) * 64), in: window)
            let sheet = try XCTUnwrap(window.sheets.first)
            let root = try XCTUnwrap(sheet.contentView)
            if name == "OAuth fixture" {
                for (id, value) in [("mcp.editor.name", server.name), ("mcp.editor.url", server.url!),
                                    ("oauth.token.url", oauth.tokenURL), ("oauth.client.id", oauth.clientID)] {
                    let field = try XCTUnwrap(find(root) { $0.accessibilityIdentifier() == id })
                    XCTAssertEqual(field.accessibilityValue() as? String, value)
                }
            } else {
                XCTAssertNil(find(root) { $0.accessibilityIdentifier() == "mcp.editor.url" })
            }
            try await click(NSPoint(x: 45, y: 28), in: sheet)
        }
    }
}

private final class OAuthMetadataURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (response, data) = try XCTUnwrap(Self.handler)(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
