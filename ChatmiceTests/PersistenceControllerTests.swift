import XCTest

@testable import Chatmice

final class PersistenceControllerTests: XCTestCase {
    @MainActor
    func testInMemoryControllersReuseManagedObjectModel() {
        let first = PersistenceController(inMemory: true)
        let second = PersistenceController(inMemory: true)

        XCTAssertTrue(
            first.container.managedObjectModel === second.container.managedObjectModel,
            "Multiple model instances make Core Data entity-to-subclass resolution ambiguous"
        )

    }
}
