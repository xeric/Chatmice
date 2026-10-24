import XCTest

@testable import Chatmice

final class ChatActivityStoreTests: XCTestCase {
    @MainActor
    func testCompactionActivityExplainsPreflightWork() async throws {
        let chatId = UUID()
        ChatActivityStore.shared.updatePresentationContext(
            focusedChatId: chatId,
            applicationIsActive: true
        )

        ChatActivityEvents.post(ChatActivityEvent(chatId: chatId, kind: .compactingContext))
        await Task.yield()

        let snapshot = try XCTUnwrap(ChatActivityStore.shared.activeSnapshot(for: chatId))
        XCTAssertEqual(snapshot.phase, .compactingContext)
        XCTAssertEqual(snapshot.phase.title, "Compacting context")
        XCTAssertEqual(snapshot.phase.detail, "Summarizing earlier messages before sending")

        ChatActivityEvents.post(ChatActivityEvent(chatId: chatId, kind: .waitingForModel))
        await Task.yield()
        XCTAssertEqual(ChatActivityStore.shared.activeSnapshot(for: chatId)?.phase, .waitingForModel)

        ChatActivityEvents.post(ChatActivityEvent(chatId: chatId, kind: .cancelled))
        await Task.yield()
        ChatActivityStore.shared.updatePresentationContext(
            focusedChatId: nil,
            applicationIsActive: true
        )
    }
}
