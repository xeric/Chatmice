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
