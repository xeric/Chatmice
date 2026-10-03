//
//  ChatmiceTests.swift
//  ChatmiceTests
//
//  Created by Renat Notfullin on 11.03.2023.
//

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
