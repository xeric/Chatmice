//
//  ChatmiceTests.swift
//  ChatmiceTests
//
//  Created by Renat Notfullin on 11.03.2023.
//

import AppKit
import XCTest

@testable import Chatmice

final class ChatmiceTests: XCTestCase {
    func testCloudKitRequiresConfiguredContainerInSignedEntitlements() {
        XCTAssertFalse(
            AppConstants.supportsCloudKit(
                containerIdentifier: "iCloud.xeric.com.chatmice",
                entitlementIdentifiers: []
            )
        )
        XCTAssertFalse(
            AppConstants.supportsCloudKit(
                containerIdentifier: "iCloud.xeric.com.chatmice",
                entitlementIdentifiers: ["iCloud.com.chatmice.app"]
            )
        )
        XCTAssertTrue(
            AppConstants.supportsCloudKit(
                containerIdentifier: "iCloud.xeric.com.chatmice",
                entitlementIdentifiers: ["iCloud.xeric.com.chatmice"]
            )
        )
    }

    @MainActor
    func testStreamingMessageIsVisibleBeforeStreamCompletes() async {
        let persistence = PersistenceController(inMemory: true)
        XCTAssertEqual(persistence.loadState, .ready)
        let context = persistence.container.viewContext
        let chat = ChatEntity(context: context)
        chat.id = UUID()
        chat.createdDate = Date()
        chat.updatedDate = Date()
        chat.systemMessage = ""
        chat.gptModel = "test"
        chat.name = "Test"
        chat.requestMessages = []

        let userMessage = MessageEntity(context: context)
        userMessage.id = 1
        userMessage.sequence = 1
        userMessage.body = "Question"
        userMessage.timestamp = Date()
        userMessage.own = true
        userMessage.chat = chat
        chat.addToMessages(userMessage)
        context.processPendingChanges()

        let viewModel = ChatViewModel(chat: chat, viewContext: context)
        let manager = MessageManager(apiService: DelayedStreamingAPIService(), viewContext: context)
        let completed = expectation(description: "stream completed")

        manager.sendMessageStream("Question", in: chat, contextSize: 10) { result in
            if case .failure(let error) = result {
                XCTFail("Unexpected stream failure: \(error)")
            }
            completed.fulfill()
        }

        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(viewModel.sortedMessages.count, 2)
        XCTAssertEqual(viewModel.sortedMessages.last?.body, "Hello")

        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(viewModel.sortedMessages.last?.body, "Hello world")
    }

    func testSkillStoreRestrictsCatalogPromptAndReads() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let enabledID = "enabled-\(UUID().uuidString)"
        let disabledID = "disabled-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: root) }

        for (identifier, name) in [(enabledID, "Enabled Skill"), (disabledID, "Disabled Skill")] {
            let directory = root.appendingPathComponent(identifier, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try "---\nname: \(name)\ndescription: Test skill\n---\nInstructions for \(name)"
                .write(to: directory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        }

        let store = SkillStore(directories: [root], allowedIdentifiers: [enabledID])
        let skills = await store.skills()
        XCTAssertEqual(skills.map(\.name), ["Enabled Skill"])

        let prompt = await store.systemPromptSection()
        XCTAssertTrue(prompt.contains("Enabled Skill"))
        XCTAssertFalse(prompt.contains("Disabled Skill"))

        do {
            _ = try await store.read(name: "Disabled Skill", path: nil)
            XCTFail("A chat-disabled Skill must not be readable")
        }
        catch {
            XCTAssertTrue(error is ToolError)
        }
    }

    func testSkillSelectionIsIsolatedPerChatAndResettable() {
        let defaults = UserDefaults.standard
        let storageKey = "chatmiceToolSelectionState"
        let previousState = defaults.data(forKey: storageKey)
        defer {
            if let previousState {
                defaults.set(previousState, forKey: storageKey)
            }
            else {
                defaults.removeObject(forKey: storageKey)
            }
        }
        defaults.removeObject(forKey: storageKey)

        let firstChat = UUID()
        let secondChat = UUID()
        let sourceID = ToolSourceID.skill("test-skill")

        ToolSelectionStore.setSourceEnabled(false, sourceID: sourceID, for: firstChat)
        XCTAssertTrue(ToolSelectionStore.disabledSourceIDs(for: firstChat).contains(sourceID))
        XCTAssertFalse(ToolSelectionStore.disabledSourceIDs(for: secondChat).contains(sourceID))
        XCTAssertFalse(ToolSelectionStore.disabledSourceIDs(for: nil).contains(sourceID))

        ToolSelectionStore.resetSourcesToDefaults([sourceID], for: firstChat)
        XCTAssertFalse(ToolSelectionStore.disabledSourceIDs(for: firstChat).contains(sourceID))
    }

    func testScreenshotToolActivityPersistsRenderableImage() throws {
        let source = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 3_440,
                pixelsHigh: 1_440,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        let png = try XCTUnwrap(source.representation(using: .png, properties: [:]))
        let activity = ToolActivityRecord(
            name: "computer.screenshot",
            input: "{}",
            output: "data:image/png;base64,\(png.base64EncodedString())",
            isError: false
        ).compactedForPersistence()
        let url = try XCTUnwrap(activity.storedImageURL)
        defer { try? FileManager.default.removeItem(at: url) }
        let preview = try XCTUnwrap(activity.storedImage)

        XCTAssertFalse(activity.output.contains("base64"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertLessThanOrEqual(max(preview.size.width, preview.size.height), 1_600)
    }

    @MainActor
    func testMessageWithMissingTimestampRemainsRenderableForRetry() {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let chat = ChatEntity(context: context)
        chat.id = UUID()
        chat.name = "Retry regression"
        chat.systemMessage = ""
        chat.gptModel = "test"
        chat.requestMessages = []

        let message = MessageEntity(context: context)
        message.id = 1
        message.sequence = 1
        message.name = "assistant"
        message.body = "Failed response"
        message.own = false
        message.chat = chat
        chat.addToMessages(message)
        context.processPendingChanges()

        let messages = ChatViewModel(chat: chat, viewContext: context).sortedMessages
        XCTAssertEqual(messages.count, 1)
        XCTAssertNil(messages[0].timestamp)
    }

    func testOpenAIResponsesFallsBackWhenStreamingIsUnsupported() async throws {
        var requests: [Bool] = []
        ResponsesFallbackURLProtocol.requestHandler = { request in
            let body = try XCTUnwrap(request.httpBody)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let isStreaming = json["stream"] as? Bool == true
            requests.append(isStreaming)

            let status = isStreaming ? 404 : 200
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let payload = isStreaming
                ? #"{"error":{"message":"streaming unsupported"}}"#
                : #"{"output_text":"pong"}"#
            return (response, Data(payload.utf8))
        }
        defer { ResponsesFallbackURLProtocol.requestHandler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResponsesFallbackURLProtocol.self]
        let handler = OpenAIResponsesHandler(
            config: APIServiceConfig(
                name: "HAI OpenAI",
                apiUrl: URL(string: "http://127.0.0.1:6655/openai/v1")!,
                apiKey: "test-key",
                model: "gpt-5.6-luna",
                type: "openai-responses"
            ),
            session: URLSession(configuration: configuration),
            imageGenerationSupported: false
        )

        let stream = try await handler.sendMessageStream(
            [["role": "user", "content": "ping"]],
            temperature: 0.7
        )
        var result = ""
        for try await chunk in stream {
            result += chunk
        }

        XCTAssertEqual(result, "pong")
        XCTAssertEqual(requests, [true, false])
    }

    func testResponsesTextRequestFallsBackToNormalizedChatCompletionsURL() async throws {
        var paths: [String] = []
        ResponsesFallbackURLProtocol.requestHandler = { request in
            paths.append(request.url?.path ?? "")
            let isChatCompletions = request.url?.path.hasSuffix("/chat/completions") == true
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: isChatCompletions ? 200 : 404,
                httpVersion: nil,
                headerFields: ["Content-Type": isChatCompletions ? "text/event-stream" : "application/json"]
            )!
            let payload = isChatCompletions
                ? "data: {\"choices\":[{\"delta\":{\"content\":\"pong\"}}]}\n\ndata: [DONE]\n\n"
                : #"{"error":{"message":"Responses unsupported"}}"#
            return (response, Data(payload.utf8))
        }
        defer { ResponsesFallbackURLProtocol.requestHandler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResponsesFallbackURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let config = APIServiceConfig(
            name: "Responses",
            apiUrl: URL(string: "http://127.0.0.1:9988/openai/v1/responses")!,
            apiKey: "test-key",
            model: "gpt-5.6-luna",
            type: "openai-responses"
        )
        let handler = OpenAIResponsesHandler(config: config, session: session, imageGenerationSupported: false)

        let stream = try await handler.sendMessageStream(
            [["role": "user", "content": "ping"]],
            temperature: 0.7
        )
        var result = ""
        for try await chunk in stream { result += chunk }

        XCTAssertEqual(result, "pong")
        XCTAssertEqual(paths, [
            "/openai/v1/responses",
            "/openai/v1/responses",
            "/openai/v1/chat/completions",
        ])
    }

    func testAppLoggerWritesPersistentLogFile() throws {
        let marker = "log-test-\(UUID().uuidString)"
        AppLogger.shared.error(marker)
        let contents = try String(contentsOf: AppLogger.logFileURL, encoding: .utf8)
        XCTAssertTrue(contents.contains(marker))
        XCTAssertEqual(AppLogger.logFileURL.lastPathComponent, "chatmice.log")
    }

    func testSearchRoutingIsIndependentFromGeneralTools() {
        XCTAssertFalse(ChatmiceEngine.shouldUseAgentRequestPath(toolsEnabled: false, searchMode: .off))
        XCTAssertTrue(ChatmiceEngine.shouldUseAgentRequestPath(toolsEnabled: true, searchMode: .off))
        XCTAssertTrue(ChatmiceEngine.shouldUseAgentRequestPath(toolsEnabled: false, searchMode: .native))
        XCTAssertTrue(ChatmiceEngine.shouldUseAgentRequestPath(toolsEnabled: false, searchMode: .web))
    }

    func testResponsesTurnKeepsConfiguredWireAPIWhenToolsAreDisabled() async throws {
        let chatID = UUID()
        let defaults = UserDefaults.standard
        let previousToolsValue = defaults.object(forKey: ChatmiceEngine.toolsEnabledKey)
        defaults.set(false, forKey: ChatmiceEngine.toolsEnabledKey)
        SearchModeStore.setMode(.native, for: chatID)
        defer {
            SearchModeStore.setMode(.off, for: chatID)
            if let previousToolsValue {
                defaults.set(previousToolsValue, forKey: ChatmiceEngine.toolsEnabledKey)
            } else {
                defaults.removeObject(forKey: ChatmiceEngine.toolsEnabledKey)
            }
            ResponsesFallbackURLProtocol.requestHandler = nil
        }

        var capturedRequest: URLRequest?
        ResponsesFallbackURLProtocol.requestHandler = { request in
            capturedRequest = request
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            let payload = """
            data: {"type":"response.output_text.delta","delta":"pong"}

            data: {"type":"response.completed","response":{"output":[]}}

            """
            return (response, Data(payload.utf8))
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResponsesFallbackURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let config = APIServiceConfig(
            name: "Responses",
            apiUrl: URL(string: "http://127.0.0.1:6655/openai/v1")!,
            apiKey: "test-key",
            model: "gpt-5.6-luna",
            type: "openai-responses"
        )
        let base = OpenAIResponsesHandler(config: config, session: session, imageGenerationSupported: false)
        let engine = ChatmiceEngine(baseService: base, config: config, chatID: chatID, session: session)

        let stream = try await engine.sendMessageStream([["role": "user", "content": "ping"]], temperature: 0.7)
        var result = ""
        for try await chunk in stream { result += chunk }

        XCTAssertEqual(result, "pong")
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url?.path, "/openai/v1")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertNotNil(body["input"])
        XCTAssertNil(body["messages"])
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertTrue(tools.contains { $0["type"] as? String == "web_search_preview" })
    }

    func testResponsesTurnFallsBackToChatCompletionsOnlyAfterResponsesRejectsTools() async throws {
        let chatID = UUID()
        let defaults = UserDefaults.standard
        let previousToolsValue = defaults.object(forKey: ChatmiceEngine.toolsEnabledKey)
        defaults.set(false, forKey: ChatmiceEngine.toolsEnabledKey)
        SearchModeStore.setMode(.native, for: chatID)
        defer {
            SearchModeStore.setMode(.off, for: chatID)
            if let previousToolsValue {
                defaults.set(previousToolsValue, forKey: ChatmiceEngine.toolsEnabledKey)
            } else {
                defaults.removeObject(forKey: ChatmiceEngine.toolsEnabledKey)
            }
            ResponsesFallbackURLProtocol.requestHandler = nil
        }

        var paths: [String] = []
        ResponsesFallbackURLProtocol.requestHandler = { request in
            paths.append(request.url?.path ?? "")
            let body = try XCTUnwrap(request.httpBody)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let isChatCompletions = json["messages"] != nil
            let status = isChatCompletions ? 200 : 404
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": isChatCompletions ? "text/event-stream" : "application/json"]
            )!
            let payload = isChatCompletions
                ? "data: {\"choices\":[{\"delta\":{\"content\":\"pong\"}}]}\n\ndata: [DONE]\n\n"
                : #"{"error":{"message":"Responses tools unsupported"}}"#
            return (response, Data(payload.utf8))
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResponsesFallbackURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let config = APIServiceConfig(
            name: "HAI Responses",
            apiUrl: URL(string: "http://127.0.0.1:6655/openai/v1")!,
            apiKey: "test-key",
            model: "gpt-5.6-luna",
            type: "openai-responses"
        )
        let base = OpenAIResponsesHandler(config: config, session: session, imageGenerationSupported: false)
        let engine = ChatmiceEngine(baseService: base, config: config, chatID: chatID, session: session)

        let stream = try await engine.sendMessageStream([["role": "user", "content": "ping"]], temperature: 0.7)
        var result = ""
        for try await chunk in stream { result += chunk }

        XCTAssertEqual(result, "pong")
        XCTAssertEqual(paths, ["/openai/v1", "/openai/v1", "/openai/v1/chat/completions"])
    }

    func testOllamaTurnKeepsNativeChatEndpointWhenToolsAreEnabled() async throws {
        let chatID = UUID()
        let defaults = UserDefaults.standard
        let previousToolsValue = defaults.object(forKey: ChatmiceEngine.toolsEnabledKey)
        let previousFileToolsValue = defaults.object(forKey: "chatmiceFileToolsEnabled")
        defaults.set(true, forKey: ChatmiceEngine.toolsEnabledKey)
        defaults.set(true, forKey: "chatmiceFileToolsEnabled")
        ToolSelectionStore.setSourceEnabled(true, sourceID: ToolSourceID.fileTool, for: chatID)
        defer {
            if let previousToolsValue { defaults.set(previousToolsValue, forKey: ChatmiceEngine.toolsEnabledKey) }
            else { defaults.removeObject(forKey: ChatmiceEngine.toolsEnabledKey) }
            if let previousFileToolsValue { defaults.set(previousFileToolsValue, forKey: "chatmiceFileToolsEnabled") }
            else { defaults.removeObject(forKey: "chatmiceFileToolsEnabled") }
            ResponsesFallbackURLProtocol.requestHandler = nil
        }

        var capturedRequest: URLRequest?
        ResponsesFallbackURLProtocol.requestHandler = { request in
            capturedRequest = request
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/x-ndjson"]
            )!
            return (response, Data(#"{"message":{"role":"assistant","content":"pong"},"done":true}"#.utf8))
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResponsesFallbackURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let config = APIServiceConfig(
            name: "Ollama",
            apiUrl: URL(string: "http://127.0.0.1:11434/api/chat")!,
            apiKey: "",
            model: "qwen3",
            type: "ollama"
        )
        let base = OllamaHandler(config: config, session: session)
        let engine = ChatmiceEngine(baseService: base, config: config, chatID: chatID, session: session)

        let stream = try await engine.sendMessageStream([["role": "user", "content": "ping"]], temperature: 0.7)
        var result = ""
        for try await chunk in stream { result += chunk }

        XCTAssertEqual(result, "pong")
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url?.path, "/api/chat")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertNotNil(body["messages"])
        XCTAssertNotNil(body["tools"])
        XCTAssertNil(body["input"])
    }

    func testNewProviderUsesServiceIDAsCredentialIdentifier() throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let manager = APIServiceManager(viewContext: context)

        let service = manager.createAPIService(
            name: "Custom Provider",
            type: "openai-responses",
            url: URL(string: "http://127.0.0.1:6655/openai/v1")!,
            model: "gpt-5.6-luna",
            contextSize: 20,
            useStreamResponse: true,
            generateChatNames: true
        )

        XCTAssertEqual(service.tokenIdentifier, try XCTUnwrap(service.id).uuidString)
    }

    func testCredentialResolverFallsBackToServiceID() throws {
        let incorrectIdentifier = UUID().uuidString
        let serviceIdentifier = UUID().uuidString
        try TokenManager.setToken("test-secret", for: serviceIdentifier)
        defer { try? TokenManager.deleteToken(for: serviceIdentifier) }

        let resolved = try TokenManager.resolveToken(
            preferredIdentifier: incorrectIdentifier,
            fallbackIdentifier: serviceIdentifier
        )

        XCTAssertEqual(resolved.token, "test-secret")
        XCTAssertEqual(resolved.identifier, serviceIdentifier)
    }

}


private final class DelayedStreamingAPIService: APIService {
    let name = "Delayed stream"
    let baseURL = URL(string: "https://example.invalid")!

    func sendMessage(
        _ requestMessages: [[String: String]],
        temperature: Float,
        completion: @escaping (Result<String, APIError>) -> Void
    ) {
        completion(.failure(.invalidResponse))
    }

    func sendMessageStream(
        _ requestMessages: [[String: String]],
        temperature: Float
    ) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                continuation.yield("Hello")
                try? await Task.sleep(for: .milliseconds(250))
                continuation.yield(" world")
                continuation.finish()
            }
        }
    }

    func fetchModels() async throws -> [AIModel] { [] }
    func cancelCurrentRequest() {}
}

private final class ResponsesFallbackURLProtocol: URLProtocol {
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
        }
        catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
