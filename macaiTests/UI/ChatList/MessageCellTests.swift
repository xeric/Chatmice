import XCTest
@testable import macai

final class MessageCellTests: XCTestCase {
    func testAssistantDisplayNameReturnsPersonaNameWhenEnabled() {
        let displayName = MessageCell.assistantDisplayName(
            personaName: "Software Engineer",
            showAssistantNameInSidebar: true
        )

        XCTAssertEqual(displayName, "Software Engineer")
    }

    func testAssistantDisplayNameReturnsFallbackWhenEnabledWithoutPersona() {
        let displayName = MessageCell.assistantDisplayName(
            personaName: nil,
            showAssistantNameInSidebar: true
        )

        XCTAssertEqual(displayName, "No assistant selected")
    }

    func testAssistantDisplayNameReturnsNilWhenDisabled() {
        let displayName = MessageCell.assistantDisplayName(
            personaName: "History Buff",
            showAssistantNameInSidebar: false
        )

        XCTAssertNil(displayName)
    }
}
