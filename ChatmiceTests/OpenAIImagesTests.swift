import AppKit
import CoreData
import SwiftUI
import XCTest
@testable import Chatmice

final class OpenAIImagesTests: XCTestCase {
    @MainActor
    func testCurrentPromptModelHeadersAndMultipleImagesPersist() async throws {
        let fixture = try ImagesFixture()
        defer { fixture.close() }
        let service = fixture.service()
        let message = try await fixture.send(service, messages: [
            ["role": "system", "content": "Persona must not be sent"],
            ["role": "user", "content": "Old prompt"],
            ["role": "assistant", "content": "<image-uuid>old-output</image-uuid>"],
            ["role": "user", "content": "Draw a red square"],
        ])
        let request = try XCTUnwrap(fixture.capture.requests.first)
        XCTAssertEqual(request.url?.path, "/v1/images/generations")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try fixture.body(request)
        XCTAssertEqual(Set(body.keys), ["model", "prompt", "n", "output_format"])
        XCTAssertEqual(body["model"] as? String, "gpt-image-2.6")
        XCTAssertEqual(body["prompt"] as? String, "Draw a red square")
        XCTAssertEqual(body["n"] as? Int, 1)
        XCTAssertEqual(body["output_format"] as? String, "png")
        try fixture.assertImages(message, count: 2)
    }

    @MainActor
    func testConfiguredRoutesNormalizeAtActualRequestBoundary() async throws {
        let fixture = try ImagesFixture()
        defer { fixture.close() }
        for path in ["", "/", "/v1", "/v1/", "/v1/images", "/v1/images/generations", "/v1/images/generations/", "/v1/responses", "/v1/chat/completions", "/proxy/openai/v1/responses"] {
            let service = fixture.service(path: path)
            _ = try await fixture.send(service)
            let expected = path.hasPrefix("/proxy") ? "/proxy/openai/v1/images/generations" : "/v1/images/generations"
            XCTAssertEqual(fixture.capture.requests.last?.url?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")), expected.trimmingCharacters(in: CharacterSet(charactersIn: "/")), path)
        }
    }

    @MainActor
    func testCustomHeadersOverrideAuthorizationAndPreserveCustomModel() async throws {
        let fixture = try ImagesFixture()
        defer { fixture.close() }
        let service = fixture.service(model: "tenant/private-image-2.6", headers: ["Authorization": "custom-auth", "X-Image-Tenant": "fixture"])
        _ = try await fixture.send(service)
        let request = try XCTUnwrap(fixture.capture.requests.last)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "custom-auth")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Image-Tenant"), "fixture")
        XCTAssertEqual(try fixture.body(request)["model"] as? String, "tenant/private-image-2.6")
    }

    @MainActor
    func testStreamingDeliversCompletedImageBatch() async throws {
        let fixture = try ImagesFixture()
        defer { fixture.close() }
        let service = fixture.service()
        let stream = try await service.sendMessageStream([["role": "user", "content": "Generate squares"]], temperature: 0.9)
        var chunks: [String] = []
        for try await chunk in stream { chunks.append(chunk) }
        XCTAssertEqual(chunks.count, 1)
        try fixture.assertImages(try XCTUnwrap(chunks.first), count: 2)
        XCTAssertNil(try fixture.body(try XCTUnwrap(fixture.capture.requests.last))["stream"])
    }

    @MainActor
    func testMalformedResponsesDoNotPersistPartialImages() async throws {
        let fixture = try ImagesFixture()
        defer { fixture.close() }
        let valid = fixture.png.base64EncodedString()
        for payload in ["not-json", "{}", #"{"data":[]}"#, #"{"data":[{"url":"https://invalid/image.png"}]}"#,
                        #"{"data":[{"b64_json":"%%%"}]}"#,
                        "{\"data\":[{\"b64_json\":\"\(valid)\"},{\"b64_json\":\"bm90LWFuLWltYWdl\"}]}" ] {
            fixture.capture.reply = (200, Data(payload.utf8))
            do {
                _ = try await fixture.send(fixture.service())
                XCTFail("Malformed image response succeeded: \(payload.prefix(40))")
            } catch let error as APIError {
                guard case .decodingFailed = error else { return XCTFail("Unexpected error: \(error)") }
            }
            XCTAssertEqual(try fixture.context.count(for: ImageEntity.fetchRequest()), 0)
        }
    }

    @MainActor
    func testHTTPFailuresUseExistingAPIErrors() async throws {
        let fixture = try ImagesFixture()
        defer { fixture.close() }
        for status in [400, 401, 429, 500] {
            fixture.capture.reply = (status, Data(#"{"error":{"message":"fixture denial"}}"#.utf8))
            do {
                _ = try await fixture.send(fixture.service())
                XCTFail("HTTP \(status) succeeded")
            } catch let error as APIError {
                switch (status, error) {
                case (401, .unauthorized), (429, .rateLimited): break
                case (400, .serverError(let detail)), (500, .serverError(let detail)):
                    XCTAssertTrue(detail.contains("fixture denial"))
                default: XCTFail("Unexpected HTTP \(status) error \(error)")
                }
            }
        }
        XCTAssertEqual(try fixture.context.count(for: ImageEntity.fetchRequest()), 0)
    }

    @MainActor
    func testEmptyBody404StreamReportsHTTPStatusWithoutRetrying() async throws {
        let fixture = try ImagesFixture()
        defer { fixture.close() }
        fixture.capture.reply = (404, Data())
        let service = fixture.service(model: "openai-official/gpt-image-2.5")
        let stream = try await service.sendMessageStream([["role": "user", "content": "Draw a living room"]], temperature: 0.7)
        do {
            for try await _ in stream { XCTFail("HTTP 404 must not emit images") }
            XCTFail("HTTP 404 must fail the image request")
        } catch let error as APIError {
            XCTAssertEqual(error.localizedDescription, "Server error: HTTP 404: Empty or unreadable response body.")
        }
        XCTAssertEqual(fixture.capture.requests.count, 1, "A rejected generation must not be retried automatically")
        let request = try XCTUnwrap(fixture.capture.requests.first)
        XCTAssertEqual(request.url?.path, "/v1/images/generations")
        XCTAssertEqual(try fixture.body(request)["model"] as? String, "openai-official/gpt-image-2.5")
        XCTAssertEqual(try fixture.context.count(for: ImageEntity.fetchRequest()), 0)
    }

    @MainActor
    func testInputImagesFilesAndEmptyPromptsFailBeforeNetwork() async throws {
        let fixture = try ImagesFixture()
        defer { fixture.close() }
        for prompt in ["Draw this <image-uuid>\(UUID())</image-uuid>", "<file-uuid>\(UUID())</file-uuid>", "  \n\t"] {
            do {
                _ = try await fixture.send(fixture.service(), messages: [["role": "user", "content": prompt]])
                XCTFail("Unsupported prompt succeeded")
            } catch let error as APIError {
                switch error {
                case .attachmentNotReady(let detail): XCTAssertTrue(detail.contains("not supported"))
                case .noApiService(let detail): XCTAssertTrue(detail.contains("Describe"))
                default: XCTFail("Unexpected validation error: \(error)")
                }
            }
        }
        XCTAssertTrue(fixture.capture.requests.isEmpty)
    }

    @MainActor
    func testConnectionAndCapabilityTestsOnlyReadModelCatalog() async throws {
        let fixture = try ImagesFixture()
        defer { fixture.close() }
        fixture.capture.reply = (200, Data(#"{"data":[{"id":"gpt-image-2.6"}]}"#.utf8))
        let config = fixture.config(path: "/v1/chat/completions")
        let result = await ModelCapabilityProbe.test(config: config, modelID: config.model, session: fixture.session)
        XCTAssertTrue(result.connectionSucceeded)
        XCTAssertEqual(result.visionSupported, false)
        XCTAssertEqual(result.audioSupported, false)
        XCTAssertEqual(result.reasoningSupported, false)
        let manager = MessageManager(apiService: fixture.service(path: "/v1/images/generations"), viewContext: fixture.context)
        let tested: Result<Void, Error> = await withCheckedContinuation { continuation in
            manager.testAPI(model: config.model) { continuation.resume(returning: $0) }
        }
        try tested.get()
        let unavailable = await ModelCapabilityProbe.test(config: config, modelID: "private-unlisted-image", session: fixture.session)
        XCTAssertFalse(unavailable.connectionSucceeded)
        XCTAssertTrue(unavailable.errorMessage?.contains("No image was generated") == true)
        XCTAssertEqual(fixture.capture.requests.count, 3)
        XCTAssertTrue(fixture.capture.requests.allSatisfy { $0.httpMethod == "GET" && $0.url?.path == "/v1/models" })
        XCTAssertEqual(try fixture.context.count(for: ImageEntity.fetchRequest()), 0)
    }

    @MainActor
    func testCancellationStopsGenerationWithoutPersistingImages() async throws {
        let fixture = try ImagesFixture()
        defer { fixture.close() }
        let started = expectation(description: "Image request starts")
        let finished = expectation(description: "Cancelled image request finishes")
        fixture.capture.hold = true
        fixture.capture.onRequest = { started.fulfill() }
        let service = fixture.service()
        service.sendMessage([["role": "user", "content": "Draw a square"]], temperature: 0.7) { result in
            switch result {
            case .success: XCTFail("Cancelled generation succeeded")
            case .failure(.requestFailed(let error)):
                XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)
            case .failure(let error): XCTFail("Unexpected cancellation error: \(error)")
            }
            finished.fulfill()
        }
        await fulfillment(of: [started], timeout: 5)
        service.cancelCurrentRequest()
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(try fixture.context.count(for: ImageEntity.fetchRequest()), 0)
    }

    @MainActor
    func testMessageManagerSendAndStreamKeepImageMarkersAndLocalTitles() async throws {
        let fixture = try ImagesFixture()
        defer { fixture.close() }
        let chat = ChatEntity(context: fixture.context)
        chat.id = UUID()
        chat.name = ""
        chat.gptModel = "gpt-image-2.6"
        chat.systemMessage = "Persona instruction must not be sent"
        chat.requestMessages = [["role": "assistant", "content": "prior generated <image-uuid>old</image-uuid>"]]
        chat.contextInputTokens = 9_000_000
        let user = MessageEntity(context: fixture.context)
        user.id = 1
        user.sequence = 1
        user.own = true
        user.body = "Draw a local square"
        user.timestamp = Date()
        user.chat = chat
        chat.addToMessages(user)
        try fixture.context.save()
        let manager = MessageManager(apiService: fixture.service(), viewContext: fixture.context)
        let sent: Result<Void, Error> = await withCheckedContinuation { continuation in
            manager.sendMessage("Draw a local square", in: chat, contextSize: 20) { continuation.resume(returning: $0) }
        }
        try sent.get()
        // ChatLogicHandler saves the own message before either UI submission path.
        let nextUser = MessageEntity(context: fixture.context)
        nextUser.id = chat.nextSequence()
        nextUser.sequence = nextUser.id
        nextUser.own = true
        nextUser.body = "Draw another square"
        nextUser.timestamp = Date()
        nextUser.chat = chat
        chat.addToMessages(nextUser)
        try fixture.context.save()
        let streamed: Result<Void, Error> = await withCheckedContinuation { continuation in
            manager.sendMessageStream("Draw another square", in: chat, contextSize: 20) { continuation.resume(returning: $0) }
        }
        try streamed.get()
        manager.generateChatNameIfNeeded(chat: chat)
        XCTAssertEqual(chat.name, "Draw a local square")
        XCTAssertEqual(fixture.capture.requests.count, 2, "Titles and compaction must not generate images")
        XCTAssertEqual(chat.messagesArray.filter { !$0.own }.count, 2)
        for message in chat.messagesArray.filter({ !$0.own }) { try fixture.assertImages(message.body, count: 2) }
        XCTAssertEqual(try fixture.body(try XCTUnwrap(fixture.capture.requests.last))["prompt"] as? String, "Draw another square")
        XCTAssertFalse(chat.waitingForResponse)
    }

    @MainActor
    func testNativeProtocolPickerAndSavedConfigReopen() async throws {
        let fixture = try ImagesFixture()
        defer { fixture.close() }
        let encoded = try JSONEncoder().encode(fixture.config())
        let decoded = try JSONDecoder().decode(APIServiceConfig.self, from: encoded)
        let entity = APIServiceEntity(context: fixture.context)
        entity.name = "Isolated image provider"
        entity.type = decoded.type
        entity.model = decoded.model
        entity.url = decoded.apiUrl
        try fixture.context.save()
        let reopened = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        reopened.persistentStoreCoordinator = fixture.context.persistentStoreCoordinator
        let saved = try XCTUnwrap(try reopened.fetch(APIServiceEntity.fetchRequest()).first)
        XCTAssertEqual(saved.type, "openai-images")
        XCTAssertEqual(saved.model, "gpt-image-2.6")
        let root = ProviderEditorSheet(service: saved, initialPreset: nil, onSave: {}, onDelete: {})
            .environment(\.managedObjectContext, reopened)
        let host = NSHostingView(rootView: root)
        let window = makeWindow(host: host, title: "Images protocol — isolated local smoke", height: 560)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
        var labels: [String] = []
        var visited = Set<ObjectIdentifier>()
        func visit(_ object: AnyObject) {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            if let node = object as? any NSAccessibilityProtocol {
                if let value = node.accessibilityValue() as? String { labels.append(value) }
                if let label = node.accessibilityLabel() { labels.append(label) }
                if let title = node.accessibilityTitle() { labels.append(title) }
                for child in node.accessibilityChildren() ?? [] { visit(child as AnyObject) }
            }
            for child in (object as? NSView)?.subviews ?? [] { visit(child) }
        }
        visit(host)
        XCTAssertTrue(labels.contains(where: { $0.contains("Image Generations (OpenAI / GPT Image)") }), labels.joined(separator: ", "))
        let accessibility = XCTAttachment(string: labels.joined(separator: "\n"))
        accessibility.name = "Images-protocol-reopened-accessibility"
        accessibility.lifetime = .keepAlways
        add(accessibility)
        // SwiftUI's model Text is visible in the screenshot but is not exposed as a native AX node.
        // Exact type/model persistence is asserted on the reopened context above.
        attachScreenshot(host, name: "Images-protocol-picker-reopened")
    }

    @MainActor
    func testGeneratedImagesRenderInNativeMessageView() async throws {
        let fixture = try ImagesFixture()
        defer { fixture.close() }
        let markers = try await fixture.send(fixture.service())
        let ids = markers.extractImageUUIDs()
        let stored = try fixture.context.fetch(ImageEntity.fetchRequest())
        let elements: [MessageElements] = try ids.map { id in
            let entity = try XCTUnwrap(stored.first { $0.id == id })
            return .image(try XCTUnwrap(NSImage(data: try XCTUnwrap(entity.image))), id)
        }
        let root = MessageContentView(message: nil, content: markers, isStreaming: false, own: false,
            effectiveFontSize: 15, colorScheme: .dark, inlineAttachments: true,
            reasoningDuration: nil, isActiveReasoning: false, prefetchedElements: elements,
            searchText: .constant(""), currentSearchOccurrence: nil, allowsStreamingLayout: false)
            .environmentObject(PreviewStateManager())
            .frame(width: 650, alignment: .leading).padding(16)
        let host = NSHostingView(rootView: root)
        let window = makeWindow(host: host, title: "Generated images — offline local smoke", height: 680)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        var redPixels = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 5) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 5) {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   color.redComponent > 0.7, color.greenComponent < 0.3, color.blueComponent < 0.3 { redPixels += 1 }
            }
        }
        XCTAssertGreaterThan(redPixels, 1_000, "Persisted local red image fixtures should be visible, not UUID marker text")
        attachScreenshot(host, name: "Images-generated-native-rendering")
    }

    @MainActor
    private func makeWindow<Content: View>(host: NSHostingView<Content>, title: String, height: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 700, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = title
        window.appearance = NSAppearance(named: .darkAqua)
        host.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        return window
    }

    @MainActor
    private func attachScreenshot<Content: View>(_ host: NSHostingView<Content>, name: String) {
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return XCTFail("No screenshot bitmap") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return XCTFail("No screenshot PNG") }
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

@MainActor
private final class ImagesFixture {
    let context: NSManagedObjectContext
    let session: URLSession
    let capture = ImagesCapture()
    let png: Data
    let host = "\(UUID().uuidString.lowercased()).images-fixture.invalid"

    init() throws {
        // Share model identity, not storage: duplicate models break Core Data's +entity lookup in the host app.
        let model = PersistenceController.shared.container.managedObjectModel
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        try coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
        context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        for y in 0..<64 {
            for x in 0..<64 {
                let offset = y * bitmap.bytesPerRow + x * 4
                pixels[offset] = 255
                pixels[offset + 1] = 0
                pixels[offset + 2] = 0
                pixels[offset + 3] = 255
            }
        }
        png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        capture.reply = (200, try JSONSerialization.data(withJSONObject: ["data": [["b64_json": png.base64EncodedString()], ["b64_json": png.base64EncodedString()]]]))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImagesURLProtocol.self]
        session = URLSession(configuration: configuration)
        ImagesURLProtocol.register(capture, host: host)
    }

    func config(path: String = "/v1", model: String = "gpt-image-2.6", headers: [String: String] = [:]) -> APIServiceConfig {
        APIServiceConfig(name: "Isolated image fixture", apiUrl: URL(string: "https://\(host)\(path)")!, apiKey: "fixture-key", model: model, type: "openai-images", customHeaders: headers)
    }

    func service(path: String = "/v1", model: String = "gpt-image-2.6", headers: [String: String] = [:]) -> APIService {
        APIServiceFactory.createAPIService(config: config(path: path, model: model, headers: headers), chatID: UUID(), session: session, imageContext: context)
    }

    func send(_ service: APIService, messages: [[String: String]] = [["role": "user", "content": "Draw a square"]]) async throws -> String {
        let result: Result<String, APIError> = await withCheckedContinuation { continuation in
            service.sendMessage(messages, temperature: 0.7) { continuation.resume(returning: $0) }
        }
        return try result.get()
    }

    func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: ImagesURLProtocol.bodyData(request)) as? [String: Any])
    }

    func assertImages(_ markers: String, count: Int) throws {
        let ids = markers.extractImageUUIDs()
        XCTAssertEqual(ids.count, count)
        XCTAssertEqual(Set(ids).count, count)
        let images = try context.fetch(ImageEntity.fetchRequest())
        for id in ids {
            let image = try XCTUnwrap(images.first { $0.id == id })
            XCTAssertEqual(image.image, png)
            XCTAssertEqual(image.imageFormat, "png")
            XCTAssertNotNil(image.thumbnail)
        }
    }

    func close() {
        session.invalidateAndCancel()
        ImagesURLProtocol.unregister(host: host)
    }
}

private final class ImagesCapture {
    private let lock = NSLock()
    private var storage: [URLRequest] = []
    private var response: (Int, Data) = (200, Data())
    var hold = false
    var onRequest: (() -> Void)?
    var requests: [URLRequest] { lock.withLock { storage } }
    var reply: (Int, Data) {
        get { lock.withLock { response } }
        set { lock.withLock { response = newValue } }
    }
    func handle(_ request: URLRequest) -> (Int, Data) {
        let value = lock.withLock { storage.append(request); return response }
        onRequest?()
        return value
    }
}

private final class ImagesURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var captures: [String: ImagesCapture] = [:]
    static func register(_ capture: ImagesCapture, host: String) { lock.withLock { captures[host] = capture } }
    static func unregister(host: String) { lock.withLock { _ = captures.removeValue(forKey: host) } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".images-fixture.invalid") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let capture = try XCTUnwrap(Self.lock.withLock { Self.captures[request.url?.host ?? ""] })
            let (status, data) = capture.handle(request)
            if capture.hold { return }
            let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    static func bodyData(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
            if count == 0 { return data }
            data.append(buffer, count: count)
        }
    }
}
