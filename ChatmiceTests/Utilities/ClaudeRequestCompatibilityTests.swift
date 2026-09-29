import Foundation
import XCTest
@testable import Chatmice

final class ClaudeRequestCompatibilityTests: XCTestCase {
    override func tearDown() {
        ClaudeCatalogURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testClaude4OpusPayloadOmitsTemperature() {
        var payload: [String: Any] = ["model": "anthropic--claude-4.8-opus"]

        ClaudeRequestCompatibility.addTemperature(0.7, model: "anthropic--claude-4.8-opus", to: &payload)

        XCTAssertNil(payload["temperature"], "Claude 4 Opus endpoints reject temperature in this compatibility mode")
    }

    func testClaude35PayloadKeepsTemperature() {
        var payload: [String: Any] = ["model": "claude-3-5-sonnet-latest"]

        ClaudeRequestCompatibility.addTemperature(0.7, model: "claude-3-5-sonnet-latest", to: &payload)

        XCTAssertEqual(payload["temperature"] as? Float, Float(0.7))
    }

    func testDisplayNameResolvesToAdvertisedWireIDAndCachesCatalog() async {
        let expectedID = "claude-fable-5-dd-supo-8.4-edualc--ciporhtna/erocia"
        var requestCount = 0
        ClaudeCatalogURLProtocol.requestHandler = { request in
            requestCount += 1
            XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:8899/v1/models")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = Data("""
            {"data":[{"id":"\(expectedID)","display_name":"anthropic--claude-4.8-opus"}]}
            """.utf8)
            return (response, data)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClaudeCatalogURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let resolver = ClaudeModelResolver()
        let baseURL = URL(string: "http://127.0.0.1:8899/v1")!

        let first = await resolver.resolve(
            "anthropic--claude-4.8-opus",
            baseURL: baseURL,
            apiKey: "test-key",
            session: session
        )
        let second = await resolver.resolve(
            "anthropic--claude-4.8-opus",
            baseURL: baseURL,
            apiKey: "test-key",
            session: session
        )

        XCTAssertEqual(first, expectedID)
        XCTAssertEqual(second, expectedID)
        XCTAssertEqual(requestCount, 1)
    }

    func testProviderErrorBodyKeepsActionableMessage() {
        let data = Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"unknown provider for model"}}"#.utf8)

        let message = ClaudeRequestCompatibility.errorMessage(statusCode: 400, data: data)

        XCTAssertEqual(message, "HTTP 400: unknown provider for model")
    }

    func testClaudeGatewayAliasResolvesAdaptiveDialect() {
        let profile = ModelReasoningRegistry.resolve(
            modelID: "anthropic--claude-4.8-opus",
            serviceType: "claude"
        )

        XCTAssertEqual(profile.dialect, .anthropicAdaptive)
        XCTAssertTrue(profile.supportedEfforts.contains(.high))
    }

    func testClaude45UsesBudgetPayload() {
        let profile = ModelReasoningRegistry.resolve(modelID: "claude-sonnet-4-5", serviceType: "claude")
        var payload: [String: Any] = [:]

        ReasoningRequestEncoder.apply(selection: .high, profile: profile, maxTokens: 8_192, to: &payload)

        let thinking = payload["thinking"] as? [String: Any]
        XCTAssertEqual(profile.dialect, .anthropicBudget(min: 1_024, max: 64_000))
        XCTAssertEqual(thinking?["budget_tokens"] as? Int, 6_553)
    }

    func testQwenDialectComesFromEndpointProtocol() {
        let openAI = ModelReasoningRegistry.resolve(modelID: "qwen3.8-27b-dev-preview", serviceType: "chatgpt")
        let anthropic = ModelReasoningRegistry.resolve(modelID: "qwen3.8-27b-dev-preview", serviceType: "claude")

        XCTAssertEqual(openAI.dialect, .openAIEffort)
        XCTAssertEqual(anthropic.dialect, .unsupported)
    }

    func testOpenAICompatibleQwenEmitsReasoningEffort() {
        let profile = ModelReasoningRegistry.resolve(modelID: "qwen3.8-27b-dev-preview", serviceType: "chatgpt")
        var payload: [String: Any] = [:]

        ReasoningRequestEncoder.apply(selection: .high, profile: profile, maxTokens: 32_768, to: &payload)

        XCTAssertEqual(payload["reasoning_effort"] as? String, "high")
    }

    func testGeminiGenerationUsesVersionSpecificDialect() {
        let gemini2 = ModelReasoningRegistry.resolve(modelID: "gemini-2.5-pro", serviceType: "gemini")
        let gemini3 = ModelReasoningRegistry.resolve(modelID: "gemini-3-pro", serviceType: "gemini")

        XCTAssertEqual(gemini2.dialect, .geminiBudget(min: 0, max: 24_576))
        XCTAssertEqual(gemini3.dialect, .geminiLevel)
    }
}

private final class ClaudeCatalogURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let requestHandler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try requestHandler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
