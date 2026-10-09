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

    func testVisionProbeRequiresSemanticRedResponseAcrossProtocols() {
        let responses: [(type: String, json: String)] = [
            ("deepseek", #"{"choices":[{"message":{"content":"red"}}]}"#),
            ("claude", #"{"content":[{"type":"text","text":"red"}]}"#),
            ("gemini", #"{"candidates":[{"content":{"parts":[{"text":"red"}]}}]}"#),
            ("openai-responses", #"{"output":[{"content":[{"type":"output_text","text":"red"}]}]}"#),
            ("ollama", #"{"message":{"content":"red"}}"#),
        ]

        for response in responses {
            XCTAssertTrue(
                ModelCapabilityProbe.responseProvesVision(
                    data: Data(response.json.utf8),
                    serviceType: response.type
                ),
                response.type
            )
        }

        let genericSuccess = #"{"choices":[{"message":{"content":"OK"}}]}"#
        XCTAssertFalse(
            ModelCapabilityProbe.responseProvesVision(
                data: Data(genericSuccess.utf8),
                serviceType: "deepseek"
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

    func testScreenshotDataURLBecomesModelImagePayload() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let output = "data:image/png;base64,\(png.base64EncodedString())"

        let payload = try XCTUnwrap(ChatmiceEngine.toolImagePayload(from: output))

        XCTAssertEqual(payload.mediaType, "image/png")
        XCTAssertEqual(Data(base64Encoded: payload.data), png)
        XCTAssertNil(ChatmiceEngine.toolImagePayload(from: "Screenshot complete"))
        XCTAssertNil(ChatmiceEngine.toolImagePayload(from: "data:image/png;base64,not-base64"))
    }

    func testScreenshotEncoderBalancesDimensionsQualityAndPayloadBudget() throws {
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
        let image = try XCTUnwrap(source.cgImage)

        let encoded = try ScreenshotImageEncoder.encode(image)

        XCTAssertLessThanOrEqual(max(encoded.width, encoded.height), ScreenshotImageEncoder.maximumDimension)
        XCTAssertLessThanOrEqual(encoded.data.count, ScreenshotImageEncoder.maximumBytes)
        XCTAssertGreaterThanOrEqual(encoded.quality, 0.44)
        XCTAssertNotNil(NSImage(data: encoded.data))
    }

    func testPromptTooLongServerErrorHasActionableMessage() {
        let error = ErrorMessage(
            type: .serverError(#"HTTP 400: {"errorMessage":"{\"message\":\"prompt is too long\"}"}"#),
            timestamp: Date()
        )

        XCTAssertEqual(error.displayTitle, "Server Error")
        XCTAssertTrue(error.displayMessage.contains("context limit"))
        XCTAssertTrue(error.displayMessage.contains("Reduce attachments"))
    }

    func testGenericUpstreamErrorPreservesProviderMessage() {
        let error = ErrorMessage(
            type: .serverError(#"HTTP 502: {"error":{"message":"Upstream gateway unavailable"}}"#),
            timestamp: Date()
        )

        XCTAssertEqual(error.displayMessage, "Upstream gateway unavailable")
    }

    func testMonthlyBudgetErrorPreservesProviderMessageAndDisablesRetry() {
        let error = ErrorMessage(
            type: .serverError(
                #"HTTP 402: {"errorCode":"MONTHLY_CAP_REACHED","errorMessage":"Your monthly AI budget of 500 EUR is used up. Your budget resets automatically on the 1st of next month."}"#
            ),
            timestamp: Date()
        )

        XCTAssertEqual(error.displayTitle, "Usage Limit Reached")
        XCTAssertEqual(
            error.displayMessage,
            "Your monthly AI budget of 500 EUR is used up. Your budget resets automatically on the 1st of next month."
        )
        XCTAssertFalse(error.canRetry)
    }

    @MainActor
    func testFailedActivitySnapshotRetainsProviderErrorForRendering() async throws {
        let chatId = UUID()
        let message = "Your monthly AI budget is used up."
        ChatActivityStore.shared.updatePresentationContext(
            focusedChatId: chatId,
            applicationIsActive: true
        )

        ChatActivityEvents.post(ChatActivityEvent(chatId: chatId, kind: .failed(message: message)))
        await Task.yield()

        let snapshot = try XCTUnwrap(ChatActivityStore.shared.snapshot(for: chatId))
        guard case .failed(let storedMessage) = snapshot.phase else {
            return XCTFail("Expected failed activity snapshot")
        }
        XCTAssertEqual(storedMessage, message)

        ChatActivityEvents.post(ChatActivityEvent(chatId: chatId, kind: .cancelled))
        await Task.yield()
        ChatActivityStore.shared.updatePresentationContext(
            focusedChatId: nil,
            applicationIsActive: true
        )
    }

    @MainActor
    func testUpdateFeedParametersAddFreshCacheKey() throws {
        let parameters = V3UpdateCoordinator.cacheBustFeedParameters(
            date: Date(timeIntervalSince1970: 1_234)
        )
        let parameter = try XCTUnwrap(parameters.first)

        XCTAssertEqual(parameter["key"], "cacheBust")
        XCTAssertEqual(parameter["value"], "1234")
        XCTAssertEqual(parameter["displayKey"], "")
        XCTAssertEqual(parameter["displayValue"], "")
        XCTAssertTrue(
            V3UpdateCoordinator.shared.responds(
                to: NSSelectorFromString("feedParametersForUpdater:sendingSystemProfile:")
            )
        )
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
    func testDisabledWebSearchForcesStoredModesOff() {
        XCTAssertEqual(
            ChatmiceEngine.effectiveSearchMode(
                searchEnabled: false,
                storedMode: .native,
                isSonarModel: false
            ),
            .off
        )
        XCTAssertEqual(
            ChatmiceEngine.effectiveSearchMode(
                searchEnabled: false,
                storedMode: .web,
                isSonarModel: true
            ),
            .off
        )
    }


    func testDatabaseBackupCopiesCurrentStoreFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chatmice-backup-test-\(UUID().uuidString)", isDirectory: true)
        let storeDirectory = root.appendingPathComponent("store", isDirectory: true)
        let backupsDirectory = root.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sqliteURL = storeDirectory.appendingPathComponent("chatmiceDataModel.sqlite")
        let walURL = storeDirectory.appendingPathComponent("chatmiceDataModel.sqlite-wal")
        try Data("database".utf8).write(to: sqliteURL)
        try Data("wal".utf8).write(to: walURL)

        let backupURL = try DatabaseBackupManager.createBackup(
            from: sqliteURL,
            in: backupsDirectory,
            named: "Manual-Test"
        )

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: backupURL.appendingPathComponent("chatmiceDataModel.sqlite").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: backupURL.appendingPathComponent("chatmiceDataModel.sqlite-wal").path
        ))
    }

    func testSkillsRemainListedWhenAgentToolsAreDisabled() async {
        let sources = await ToolSourceCatalog.load(
            fileToolsEnabled: false,
            bashEnabled: false,
            skillsEnabled: true,
            computerEnabled: false
        )
        let sourceIDs = Set(sources.map(\.id))

        XCTAssertTrue(sourceIDs.contains(ToolSourceID.skills))
        XCTAssertFalse(sourceIDs.contains(ToolSourceID.fileTool))
        XCTAssertFalse(sourceIDs.contains(ToolSourceID.codeExecution))
        XCTAssertFalse(sourceIDs.contains(ToolSourceID.computerUse))
    }

    func testDisabledBuiltInToolsAreExcludedFromSourceCatalog() async {
        let sources = await ToolSourceCatalog.load(
            fileToolsEnabled: false,
            bashEnabled: false,
            skillsEnabled: false,
            computerEnabled: false
        )
        let sourceIDs = Set(sources.map(\.id))

        XCTAssertFalse(sourceIDs.contains(ToolSourceID.fileTool))
        XCTAssertFalse(sourceIDs.contains(ToolSourceID.codeExecution))
        XCTAssertFalse(sourceIDs.contains(ToolSourceID.skills))
        XCTAssertFalse(sourceIDs.contains(ToolSourceID.computerUse))
    }

    func testResponsesTurnKeepsConfiguredWireAPIWhenToolsAreDisabled() async throws {
        let chatID = UUID()
        let defaults = UserDefaults.standard
        let previousToolsValue = defaults.object(forKey: ChatmiceEngine.toolsEnabledKey)
        let previousWebSearchData = defaults.data(forKey: WebSearchSettings.storageKey)
        var webSearchSettings = WebSearchSettings.load()
        webSearchSettings.enabled = true
        webSearchSettings.save()
        defaults.set(false, forKey: ChatmiceEngine.toolsEnabledKey)
        SearchModeStore.setMode(.native, for: chatID)
        defer {
            SearchModeStore.setMode(.off, for: chatID)
            if let previousToolsValue {
                defaults.set(previousToolsValue, forKey: ChatmiceEngine.toolsEnabledKey)
            } else {
                defaults.removeObject(forKey: ChatmiceEngine.toolsEnabledKey)
            }
            if let previousWebSearchData {
                defaults.set(previousWebSearchData, forKey: WebSearchSettings.storageKey)
            } else {
                defaults.removeObject(forKey: WebSearchSettings.storageKey)
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
        let previousWebSearchData = defaults.data(forKey: WebSearchSettings.storageKey)
        var webSearchSettings = WebSearchSettings.load()
        webSearchSettings.enabled = true
        webSearchSettings.save()
        defaults.set(false, forKey: ChatmiceEngine.toolsEnabledKey)
        SearchModeStore.setMode(.native, for: chatID)
        defer {
            SearchModeStore.setMode(.off, for: chatID)
            if let previousToolsValue {
                defaults.set(previousToolsValue, forKey: ChatmiceEngine.toolsEnabledKey)
            } else {
                defaults.removeObject(forKey: ChatmiceEngine.toolsEnabledKey)
            }
            if let previousWebSearchData {
                defaults.set(previousWebSearchData, forKey: WebSearchSettings.storageKey)
            } else {
                defaults.removeObject(forKey: WebSearchSettings.storageKey)
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
