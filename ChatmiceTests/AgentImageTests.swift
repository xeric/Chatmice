import AppKit
import CoreData
import XCTest

@testable import Chatmice

final class AgentImageTests: XCTestCase {
    @MainActor
    func testChatCompletionsIncludesUserImageBytesMIMEAndText() async throws {
        try await assertInitialImageRequest(provider: .chatCompletions)
    }

    @MainActor
    func testResponsesIncludesUserImageBytesMIMEAndText() async throws {
        try await assertInitialImageRequest(provider: .responses)
    }

    @MainActor
    func testClaudeIncludesUserImageBytesMIMEAndText() async throws {
        try await assertInitialImageRequest(provider: .claude)
    }

    @MainActor
    func testGeminiIncludesUserImageBytesMIMEAndText() async throws {
        try await assertInitialImageRequest(provider: .gemini)
    }

    @MainActor
    func testOllamaIncludesUserImageBytesAndText() async throws {
        try await assertInitialImageRequest(provider: .ollama)
    }

    @MainActor
    func testImageOnlyUserMessagesSurviveEveryProviderEncoder() async throws {
        for provider in ImageTestProvider.allCases {
            try await assertInitialImageRequest(provider: provider, text: "")
        }
    }

    @MainActor
    func testMissingUserImagesFailBeforeAnyProviderRequest() async throws {
        for provider in ImageTestProvider.allCases {
            let fixture = try await AgentImageFixture(provider: provider)
            defer { fixture.close() }
            let missingID = UUID()
            do {
                _ = try await fixture.send(content: "What is this? <image-uuid>\(missingID)</image-uuid>")
                XCTFail("\(provider): a missing image must not become a text-only request")
            } catch let error as APIError {
                guard case .attachmentNotReady = error else {
                    XCTFail("\(provider): expected attachmentNotReady, received \(error)")
                    continue
                }
            }
            XCTAssertTrue(fixture.capture.requests.isEmpty, "\(provider): missing images must fail before HTTP")
        }
    }

    @MainActor
    func testUserImagesRemainAvailableAfterToolRoundsForEveryProvider() async throws {
        for provider in ImageTestProvider.allCases {
            let fixture = try await AgentImageFixture(provider: provider)
            defer { fixture.close() }
            let text = "Inspect the image and the workspace."
            fixture.capture.reply = { _, index in
                if index == 0 {
                    // Removing the stored entity proves the next round reuses resolved bytes.
                    try fixture.deleteImage()
                    return provider.toolCallReply
                }
                return provider.finalReply
            }

            let result = try await fixture.send(content: fixture.content(text: text))
            XCTAssertTrue(result.contains("pong"), provider.rawValue)
            let requests = fixture.capture.postRequests
            XCTAssertEqual(requests.count, 2, provider.rawValue)
            for request in requests {
                try assertUserImage(body: request.body, provider: provider, text: text, bytes: fixture.png)
            }
            let second = try XCTUnwrap(requests.last)
            try assertDirectoryToolResult(body: second.body, provider: provider)
        }
    }

    @MainActor
    func testResponsesNonStreamingFallbackRetainsResolvedUserImage() async throws {
        let fixture = try await AgentImageFixture(provider: .responses)
        defer { fixture.close() }
        let text = "Describe this image."
        fixture.capture.reply = { _, index in
            if index == 0 {
                try fixture.deleteImage()
                return ImageTestReply(status: 405, contentType: "application/json", payload: #"{"error":{"message":"streaming unsupported"}}"#)
            }
            return ImageTestReply(status: 200, contentType: "application/json", payload: #"{"output_text":"pong","output":[]}"#)
        }

        let result = try await fixture.send(content: fixture.content(text: text))
        XCTAssertEqual(result, "pong")
        let requests = fixture.capture.postRequests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.map { $0.url.path }, ["/v1/responses", "/v1/responses"])
        XCTAssertEqual(requests.first?.body["stream"] as? Bool, true)
        XCTAssertNotEqual(requests.last?.body["stream"] as? Bool, true)
        for request in requests {
            try assertUserImage(body: request.body, provider: .responses, text: text, bytes: fixture.png)
        }
    }

    @MainActor
    func testResponsesChatCompletionsFallbackRetainsResolvedUserImage() async throws {
        let fixture = try await AgentImageFixture(provider: .responses)
        defer { fixture.close() }
        let text = "Describe this image."
        fixture.capture.reply = { _, index in
            if index == 0 { try fixture.deleteImage() }
            if index < 2 {
                return ImageTestReply(status: 404, contentType: "application/json", payload: #"{"error":{"message":"Responses tools unsupported"}}"#)
            }
            return ImageTestProvider.chatCompletions.finalReply
        }

        let result = try await fixture.send(content: fixture.content(text: text))
        XCTAssertEqual(result, "pong")
        let requests = fixture.capture.postRequests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests.map { $0.url.path }, ["/v1/responses", "/v1/responses", "/v1/chat/completions"])
        for request in requests.prefix(2) {
            try assertUserImage(body: request.body, provider: .responses, text: text, bytes: fixture.png)
        }
        let fallback = try XCTUnwrap(requests.last)
        try assertUserImage(body: fallback.body, provider: .chatCompletions, text: text, bytes: fixture.png)
    }


    @MainActor
    private func assertInitialImageRequest(provider: ImageTestProvider, text: String = "What color is the image?") async throws {
        let fixture = try await AgentImageFixture(provider: provider)
        defer { fixture.close() }
        let result = try await fixture.send(content: fixture.content(text: text))
        XCTAssertEqual(result, "pong", provider.rawValue)
        let requests = fixture.capture.postRequests
        XCTAssertEqual(requests.count, 1, provider.rawValue)
        let request = try XCTUnwrap(requests.first)
        try assertUserImage(body: request.body, provider: provider, text: text, bytes: fixture.png)
        XCTAssertNotNil(request.body["tools"], "\(provider): exercise the agent path, not the base handler")
    }

    private func assertUserImage(body: [String: Any], provider: ImageTestProvider, text: String, bytes: Data) throws {
        let messagesKey = provider == .responses ? "input" : provider == .gemini ? "contents" : "messages"
        let messages = try XCTUnwrap(body[messagesKey] as? [[String: Any]])
        let user = try XCTUnwrap(messages.first { $0["role"] as? String == "user" }, provider.rawValue)
        var encodedImage: String
        switch provider {
        case .chatCompletions, .responses:
            let parts = try XCTUnwrap(user["content"] as? [[String: Any]])
            let imageType = provider == .responses ? "input_image" : "image_url"
            let images = parts.filter { $0["type"] as? String == imageType }
            XCTAssertEqual(images.count, 1, provider.rawValue)
            let image = try XCTUnwrap(images.first)
            let dataURL = try XCTUnwrap(provider == .responses ? image["image_url"] as? String : (image["image_url"] as? [String: Any])?["url"] as? String)
            XCTAssertTrue(dataURL.hasPrefix("data:image/png;base64,"), provider.rawValue)
            encodedImage = String(dataURL.dropFirst("data:image/png;base64,".count))
            XCTAssertEqual(parts.compactMap { $0["text"] as? String }.joined(), text, provider.rawValue)
        case .claude:
            let parts = try XCTUnwrap(user["content"] as? [[String: Any]])
            let images = parts.filter { $0["type"] as? String == "image" }
            XCTAssertEqual(images.count, 1)
            let source = try XCTUnwrap(images.first?["source"] as? [String: Any])
            XCTAssertEqual(source["type"] as? String, "base64")
            XCTAssertEqual(source["media_type"] as? String, "image/png")
            encodedImage = try XCTUnwrap(source["data"] as? String)
            XCTAssertEqual(parts.compactMap { $0["text"] as? String }.joined(), text)
        case .gemini:
            let parts = try XCTUnwrap(user["parts"] as? [[String: Any]])
            let images = parts.compactMap { $0["inlineData"] as? [String: Any] }
            XCTAssertEqual(images.count, 1)
            let image = try XCTUnwrap(images.first)
            XCTAssertEqual(image["mimeType"] as? String, "image/png")
            encodedImage = try XCTUnwrap(image["data"] as? String)
            XCTAssertEqual(parts.compactMap { $0["text"] as? String }.joined(), text)
        case .ollama:
            let images = try XCTUnwrap(user["images"] as? [String])
            XCTAssertEqual(images.count, 1)
            encodedImage = try XCTUnwrap(images.first)
            XCTAssertFalse(encodedImage.hasPrefix("data:"), "Ollama requires raw base64 and has no MIME field")
            XCTAssertEqual(user["content"] as? String, text)
        }
        XCTAssertEqual(try XCTUnwrap(Data(base64Encoded: encodedImage)), bytes, provider.rawValue)
        let serializedUser = try JSONSerialization.data(withJSONObject: user)
        XCTAssertFalse(String(decoding: serializedUser, as: UTF8.self).contains("image-uuid"), provider.rawValue)
    }

    private func assertDirectoryToolResult(body: [String: Any], provider: ImageTestProvider) throws {
        switch provider {
        case .chatCompletions, .ollama:
            let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
            let result = try XCTUnwrap(messages.first { $0["role"] as? String == "tool" })
            XCTAssertTrue(try XCTUnwrap(result["content"] as? String).contains("fixture.txt"))
        case .responses:
            let input = try XCTUnwrap(body["input"] as? [[String: Any]])
            let result = try XCTUnwrap(input.first { $0["type"] as? String == "function_call_output" })
            XCTAssertTrue(try XCTUnwrap(result["output"] as? String).contains("fixture.txt"))
        case .claude:
            let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
            let blocks = messages.flatMap { $0["content"] as? [[String: Any]] ?? [] }
            let result = try XCTUnwrap(blocks.first { $0["type"] as? String == "tool_result" })
            XCTAssertEqual(result["is_error"] as? Bool, false)
            XCTAssertTrue(try XCTUnwrap(result["content"] as? String).contains("fixture.txt"))
        case .gemini:
            let contents = try XCTUnwrap(body["contents"] as? [[String: Any]])
            let parts = contents.flatMap { $0["parts"] as? [[String: Any]] ?? [] }
            let functionResponse = try XCTUnwrap(parts.compactMap { $0["functionResponse"] as? [String: Any] }.first)
            XCTAssertEqual(functionResponse["name"] as? String, "list_directory")
            let response = try XCTUnwrap(functionResponse["response"] as? [String: Any])
            XCTAssertTrue(try XCTUnwrap(response["result"] as? String).contains("fixture.txt"))
        }
    }
}

private enum ImageTestProvider: String, CaseIterable {
    case chatCompletions = "chatgpt"
    case responses = "openai-responses"
    case claude
    case gemini
    case ollama

    var finalReply: ImageTestReply {
        let payload: String
        switch self {
        case .chatCompletions:
            payload = "data: {\"choices\":[{\"delta\":{\"content\":\"pong\"}}]}\n\ndata: [DONE]\n\n"
        case .responses:
            payload = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"pong\"}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"output\":[]}}\n\n"
        case .claude:
            payload = "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"pong\"}}\n\ndata: {\"type\":\"message_stop\"}\n\n"
        case .gemini:
            payload = "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"pong\"}]},\"finishReason\":\"STOP\"}]}\n\n"
        case .ollama:
            payload = "{\"message\":{\"role\":\"assistant\",\"content\":\"pong\"},\"done\":true}\n"
        }
        return ImageTestReply(status: 200, contentType: self == .ollama ? "application/x-ndjson" : "text/event-stream", payload: payload)
    }

    var toolCallReply: ImageTestReply {
        let payload: String
        switch self {
        case .chatCompletions:
            payload = "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call-directory\",\"type\":\"function\",\"function\":{\"name\":\"list_directory\",\"arguments\":\"{\\\"path\\\":\\\".\\\"}\"}}]},\"finish_reason\":\"tool_calls\"}]}\n\ndata: [DONE]\n\n"
        case .responses:
            payload = "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"function_call\",\"id\":\"item-directory\",\"call_id\":\"call-directory\",\"name\":\"list_directory\",\"arguments\":\"{\\\"path\\\":\\\".\\\"}\"}}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"output\":[]}}\n\n"
        case .claude:
            payload = "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"call-directory\",\"name\":\"list_directory\",\"input\":{}}}\n\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"path\\\":\\\".\\\"}\"}}\n\ndata: {\"type\":\"message_stop\"}\n\n"
        case .gemini:
            payload = "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"functionCall\":{\"name\":\"list_directory\",\"args\":{\"path\":\".\"}}}]}}]}\n\n"
        case .ollama:
            payload = "{\"message\":{\"role\":\"assistant\",\"content\":\"\",\"tool_calls\":[{\"function\":{\"name\":\"list_directory\",\"arguments\":{\"path\":\".\"}}}]},\"done\":true}\n"
        }
        return ImageTestReply(status: 200, contentType: self == .ollama ? "application/x-ndjson" : "text/event-stream", payload: payload)
    }
}

private struct ImageTestReply {
    let status: Int
    let contentType: String
    let payload: String
}

private final class AgentImageFixture {
    let png: Data
    let imageID: UUID
    let capture = AgentImageRequestCapture()
    private let context: NSManagedObjectContext
    private let workspace: URL
    private let host: String
    private let session: URLSession
    private let engine: ChatmiceEngine
    private let savedPreferences: [String: Any]
    private static let preferenceKeys = [
        ChatmiceEngine.toolsEnabledKey, "chatmiceFileToolsEnabled", ChatmiceEngine.bashEnabledKey,
        ChatmiceEngine.skillsEnabledKey, ChatmiceEngine.computerEnabledKey,
        "chatmiceToolSelectionState", "chatmiceSearchModes", WebSearchSettings.storageKey,
    ]

    init(provider: ImageTestProvider) async throws {
        let imageID = UUID()
        self.imageID = imageID
        let defaults = UserDefaults.standard
        savedPreferences = Dictionary(uniqueKeysWithValues: Self.preferenceKeys.compactMap { key in defaults.object(forKey: key).map { (key, $0) } })
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ))
        for y in 0..<2 {
            for x in 0..<2 { bitmap.setColor(.systemRed, atX: x, y: y) }
        }
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        self.png = png
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: PersistenceController.shared.container.managedObjectModel)
        try coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        self.context = context
        context.persistentStoreCoordinator = coordinator
        try context.performAndWait {
            let image = ImageEntity(context: context)
            image.id = imageID
            image.image = png
            image.imageFormat = "png"
            try context.save()
        }
        workspace = FileManager.default.temporaryDirectory.appendingPathComponent("Chatmice-AgentImage-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("directory tool fixture".utf8).write(to: workspace.appendingPathComponent("fixture.txt"))
        host = "\(UUID().uuidString.lowercased()).agent-image.invalid"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AgentImageURLProtocol.self]
        session = URLSession(configuration: configuration)
        let path = provider == .ollama ? "/api/chat" : "/v1"
        let config = APIServiceConfig(name: "Image regression", apiUrl: try XCTUnwrap(URL(string: "https://\(host)\(path)")), apiKey: "fixture-key", model: "image-test-\(UUID())", type: provider.rawValue)
        let base: APIService
        switch provider {
        case .chatCompletions: base = ChatGPTHandler(config: config, session: session)
        case .responses: base = OpenAIResponsesHandler(config: config, session: session, imageGenerationSupported: false)
        case .claude: base = ClaudeHandler(config: config, session: session)
        case .gemini: base = GeminiHandler(config: config, session: session)
        case .ollama: base = OllamaHandler(config: config, session: session)
        }
        let chatID = UUID()
        engine = ChatmiceEngine(baseService: base, config: config, chatID: chatID, workspaceURL: workspace, session: session, attachmentContext: context)
        capture.reply = { _, _ in provider.finalReply }
        AgentImageURLProtocol.register(capture, host: host)

        defaults.set(true, forKey: ChatmiceEngine.toolsEnabledKey)
        defaults.set(true, forKey: "chatmiceFileToolsEnabled")
        defaults.set(false, forKey: ChatmiceEngine.bashEnabledKey)
        defaults.set(false, forKey: ChatmiceEngine.skillsEnabledKey)
        defaults.set(false, forKey: ChatmiceEngine.computerEnabledKey)
        var search = WebSearchSettings.load()
        search.enabled = false
        search.save()
        SearchModeStore.setMode(.off, for: chatID)
        // An explicit per-chat selection avoids inheriting disabled user defaults.
        ToolSelectionStore.setSourceEnabled(true, sourceID: ToolSourceID.fileTool, for: chatID)
        let servers = await MCPService.shared.statuses()
        ToolSelectionStore.setSourcesEnabled(false, sourceIDs: servers.map { ToolSourceID.mcpServer($0.name) }, for: chatID)
    }

    func content(text: String) -> String {
        text.isEmpty ? "<image-uuid>\(imageID)</image-uuid>" : "\(text) <image-uuid>\(imageID)</image-uuid>"
    }

    func send(content: String) async throws -> String {
        let stream = try await engine.sendMessageStream([["role": "user", "content": content]], temperature: 0.7)
        var result = ""
        for try await chunk in stream { result += chunk }
        return result
    }

    func deleteImage() throws {
        try context.performAndWait {
            let request: NSFetchRequest<ImageEntity> = ImageEntity.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", imageID as CVarArg)
            for image in try context.fetch(request) { context.delete(image) }
            try context.save()
        }
    }

    func close() {
        engine.cancelCurrentRequest()
        session.invalidateAndCancel()
        AgentImageURLProtocol.unregister(host: host)
        capture.reply = nil
        context.performAndWait { context.reset() }
        try? FileManager.default.removeItem(at: workspace)
        for key in Self.preferenceKeys {
            if let value = savedPreferences[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }
}

private struct AgentImageCapturedRequest {
    let url: URL
    let method: String
    let body: [String: Any]
}

private final class AgentImageRequestCapture {
    var reply: ((AgentImageCapturedRequest, Int) throws -> ImageTestReply)?
    private let lock = NSLock()
    private var captured: [AgentImageCapturedRequest] = []
    var requests: [AgentImageCapturedRequest] { lock.withLock { captured } }
    var postRequests: [AgentImageCapturedRequest] { requests.filter { $0.method == "POST" } }

    func handle(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
        let url = try XCTUnwrap(request.url)
        let method = request.httpMethod ?? "GET"
        let body = method == "POST" ? try XCTUnwrap(JSONSerialization.jsonObject(with: AgentImageURLProtocol.bodyData(request)) as? [String: Any]) : [:]
        let value = AgentImageCapturedRequest(url: url, method: method, body: body)
        let index = lock.withLock {
            let index = captured.filter { $0.method == "POST" }.count
            captured.append(value)
            return index
        }
        let response: ImageTestReply
        if method == "GET" {
            // Claude resolves model aliases before sending its first turn.
            response = ImageTestReply(status: 200, contentType: "application/json", payload: #"{"data":[]}"#)
        } else {
            response = try XCTUnwrap(reply)(value, index)
        }
        let http = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: response.status, httpVersion: nil, headerFields: ["Content-Type": response.contentType]))
        return (http, Data(response.payload.utf8))
    }
}

private final class AgentImageURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var captures: [String: AgentImageRequestCapture] = [:]

    static func register(_ capture: AgentImageRequestCapture, host: String) {
        lock.withLock { captures[host] = capture }
    }

    static func unregister(host: String) {
        lock.withLock { _ = captures.removeValue(forKey: host) }
    }

    static func bodyData(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
            if count == 0 { return data }
            data.append(buffer, count: count)
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".agent-image.invalid") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let capture = try XCTUnwrap(Self.lock.withLock { Self.captures[request.url?.host ?? ""] })
            let (response, data) = try capture.handle(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
