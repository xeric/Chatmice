import CoreData
import XCTest
@testable import Chatmice

final class WorkspaceTests: XCTestCase {
    @MainActor
    func testPreparingTemporaryWorkspacePreservesAssignedChats() throws {
        let context = try makeContext()
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try WorkspaceManager.create(name: "Project", directory: root, in: context)
        let assigned = ChatEntity(context: context)
        assigned.id = UUID()
        assigned.workspace = workspace
        let legacy = ChatEntity(context: context)
        legacy.id = UUID()
        try context.save()

        let temporary = try WorkspaceManager.prepare(in: context)
        _ = try WorkspaceManager.prepare(in: context)
        context.refreshAllObjects()

        XCTAssertEqual(assigned.workspace, workspace)
        XCTAssertEqual(legacy.workspace, temporary)
        XCTAssertFalse((temporary.chats as? Set<ChatEntity> ?? []).contains(assigned))
        XCTAssertTrue((workspace.chats as? Set<ChatEntity> ?? []).contains(assigned))
    }

    @MainActor
    func testEditingWorkspaceKeepsChatsAndFilesAndValidatesFolder() throws {
        let context = try makeContext()
        let base = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let first = base.appendingPathComponent("first", isDirectory: true)
        let second = base.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let file = first.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: file)
        let workspace = try WorkspaceManager.create(name: "Before", directory: first, in: context)
        let id = workspace.id
        let chat = ChatEntity(context: context)
        chat.id = UUID()
        chat.workspace = workspace
        try context.save()

        try WorkspaceManager.update(workspace, name: " Renamed ", directory: first, in: context)
        try WorkspaceManager.update(workspace, name: "Renamed", directory: second, in: context)
        context.refreshAllObjects()
        XCTAssertEqual(workspace.id, id)
        XCTAssertEqual(workspace.name, "Renamed")
        XCTAssertEqual(workspace.rootURL, second.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertEqual(chat.workspace, workspace)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "keep")
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.appendingPathComponent("keep.txt").path))

        _ = try WorkspaceManager.create(name: "Other", directory: first, in: context)
        XCTAssertThrowsError(try WorkspaceManager.update(workspace, name: "Conflict", directory: first, in: context))
        XCTAssertThrowsError(try WorkspaceManager.update(workspace, name: " ", directory: second, in: context))
        XCTAssertThrowsError(try WorkspaceManager.update(workspace, name: "Missing", directory: base.appendingPathComponent("missing"), in: context))
        XCTAssertEqual(workspace.name, "Renamed")
        XCTAssertEqual(workspace.rootURL, second.standardizedFileURL.resolvingSymlinksInPath())
    }

    @MainActor
    func testDeletingWorkspaceDeletesChatsAndMessagesButPreservesFiles() throws {
        let context = try makeContext()
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("keep.txt")
        try Data("untouched".utf8).write(to: file)
        let workspace = try WorkspaceManager.create(name: "Project", directory: root, in: context)
        let workspaceID = workspace.id
        let chat = ChatEntity(context: context)
        chat.id = UUID()
        chat.workspace = workspace
        let message = MessageEntity(context: context)
        message.body = "deleted history"
        message.chat = chat
        try context.save()

        chat.waitingForResponse = true
        XCTAssertThrowsError(try WorkspaceManager.remove(workspace, in: context))
        XCTAssertThrowsError(try WorkspaceManager.update(workspace, name: "Busy", directory: root, in: context))
        XCTAssertEqual(chat.workspace, workspace)
        chat.waitingForResponse = false
        let temporary = try WorkspaceManager.remove(workspace, in: context)

        let workspaceRequest = NSFetchRequest<WorkspaceEntity>(entityName: "WorkspaceEntity")
        workspaceRequest.predicate = NSPredicate(format: "id == %@", workspaceID as CVarArg)
        XCTAssertEqual(try context.count(for: workspaceRequest), 0)
        XCTAssertEqual(try context.count(for: NSFetchRequest<ChatEntity>(entityName: "ChatEntity")), 0)
        XCTAssertEqual(try context.count(for: NSFetchRequest<MessageEntity>(entityName: "MessageEntity")), 0)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "untouched")
        XCTAssertThrowsError(try WorkspaceManager.remove(temporary, in: context))
        XCTAssertThrowsError(try WorkspaceManager.update(temporary, name: "Changed", directory: root, in: context))
    }

    @MainActor
    func testReorderingWorkspacesPersistsAndNewWorkspaceAppends() throws {
        let context = try makeContext()
        let firstRoot = try makeDirectory()
        let secondRoot = try makeDirectory()
        let thirdRoot = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: firstRoot)
            try? FileManager.default.removeItem(at: secondRoot)
            try? FileManager.default.removeItem(at: thirdRoot)
        }

        let temporary = try WorkspaceManager.prepare(in: context)
        let first = try WorkspaceManager.create(name: "First", directory: firstRoot, in: context)
        let second = try WorkspaceManager.create(name: "Second", directory: secondRoot, in: context)

        try WorkspaceManager.reorder([second, temporary, first], in: context)
        let third = try WorkspaceManager.create(name: "Third", directory: thirdRoot, in: context)

        let request = NSFetchRequest<WorkspaceEntity>(entityName: "WorkspaceEntity")
        request.sortDescriptors = [NSSortDescriptor(keyPath: \WorkspaceEntity.sortOrder, ascending: true)]
        XCTAssertEqual(try context.fetch(request).map(\.name), ["Second", "Temporary Chats", "First", "Third"])
        XCTAssertEqual(third.sortOrder, 3)
    }

    @MainActor
    private func makeContext() throws -> NSManagedObjectContext {
        let model = PersistenceController.shared.container.managedObjectModel
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        try coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        return context
    }

    private func makeDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Chatmice-WorkspaceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
