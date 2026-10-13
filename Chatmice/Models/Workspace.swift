import CoreData
import Foundation

public final class WorkspaceEntity: NSManagedObject, Identifiable {
    @NSManaged public var id: UUID
    @NSManaged public var name: String
    @NSManaged public var path: String
    @NSManaged public var isTemporary: Bool
    @NSManaged public var createdDate: Date?
    @NSManaged public var sortOrder: Int64
    @NSManaged public var chats: NSSet?

    public var rootURL: URL {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
    }
}

enum WorkspacePathPolicy {
    static func containedURL(for path: String, root: URL) throws -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw WorkspacePathError.emptyPath
        }

        let expanded = NSString(string: trimmed).expandingTildeInPath
        let candidate = URL(fileURLWithPath: expanded, relativeTo: root)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        guard contains(candidate, in: canonicalRoot) else {
            throw WorkspacePathError.outsideWorkspace(canonicalRoot.path)
        }
        return candidate
    }

    static func contains(_ candidate: URL, in root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let candidatePath = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }
}

enum WorkspacePathError: LocalizedError {
    case emptyPath
    case outsideWorkspace(String)

    var errorDescription: String? {
        switch self {
        case .emptyPath:
            return "Path must not be empty."
        case .outsideWorkspace(let root):
            return "Path must stay inside workspace: \(root)"
        }
    }
}

enum WorkspaceManager {
    static let temporaryWorkspaceID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    static let temporaryWorkspaceName = "Temporary Chats"
    static let temporaryWorkspaceURL = URL(fileURLWithPath: "/tmp/chatmice", isDirectory: true)

    @MainActor
    static func prepare(in context: NSManagedObjectContext) throws -> WorkspaceEntity {
        try FileManager.default.createDirectory(at: temporaryWorkspaceURL, withIntermediateDirectories: true)

        let request = NSFetchRequest<WorkspaceEntity>(entityName: "WorkspaceEntity")
        request.predicate = NSPredicate(format: "id == %@", temporaryWorkspaceID as CVarArg)
        request.fetchLimit = 1

        let workspace = try context.fetch(request).first ?? WorkspaceEntity(context: context)
        workspace.id = temporaryWorkspaceID
        workspace.name = temporaryWorkspaceName
        workspace.path = temporaryWorkspaceURL.path
        workspace.isTemporary = true
        workspace.createdDate = workspace.createdDate ?? Date.distantPast

        let chatsRequest = NSFetchRequest<ChatEntity>(entityName: "ChatEntity")
        chatsRequest.predicate = NSPredicate(format: "workspace == nil")
        for chat in try context.fetch(chatsRequest) {
            chat.workspace = workspace
        }

        try normalizeSortOrders(in: context)
        if context.hasChanges {
            try context.save()
        }
        return workspace
    }

    @MainActor
    static func create(name: String, directory: URL, in context: NSManagedObjectContext) throws -> WorkspaceEntity {
        let values = try validatedValues(name: name, directory: directory, excluding: nil, in: context)
        let workspace = WorkspaceEntity(context: context)
        workspace.id = UUID()
        workspace.name = values.name
        workspace.path = values.path
        workspace.isTemporary = false
        workspace.createdDate = Date()
        workspace.sortOrder = try nextSortOrder(in: context)
        do {
            try context.save()
        } catch {
            context.delete(workspace)
            throw error
        }
        return workspace
    }

    @MainActor
    static func update(_ workspace: WorkspaceEntity, name: String, directory: URL, in context: NSManagedObjectContext) throws {
        try requireEditable(workspace, in: context)
        let values = try validatedValues(name: name, directory: directory, excluding: workspace, in: context)
        let previousName = workspace.name
        let previousPath = workspace.path
        workspace.name = values.name
        workspace.path = values.path
        do {
            try context.save()
        } catch {
            workspace.name = previousName
            workspace.path = previousPath
            throw error
        }
    }
    @MainActor
    static func reorder(_ workspaces: [WorkspaceEntity], in context: NSManagedObjectContext) throws {
        let previousOrders = workspaces.map(\.sortOrder)
        for (index, workspace) in workspaces.enumerated() {
            workspace.sortOrder = Int64(index)
        }
        do {
            try context.save()
        } catch {
            for (workspace, previousOrder) in zip(workspaces, previousOrders) {
                workspace.sortOrder = previousOrder
            }
            throw error
        }
    }

    @MainActor
    private static func normalizeSortOrders(in context: NSManagedObjectContext) throws {
        let request = NSFetchRequest<WorkspaceEntity>(entityName: "WorkspaceEntity")
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \WorkspaceEntity.sortOrder, ascending: true),
            NSSortDescriptor(keyPath: \WorkspaceEntity.isTemporary, ascending: false),
            NSSortDescriptor(keyPath: \WorkspaceEntity.createdDate, ascending: true),
        ]
        let workspaces = try context.fetch(request)
        let orders = workspaces.map(\.sortOrder)
        guard orders.contains(where: { $0 < 0 }) || Set(orders).count != orders.count else { return }
        for (index, workspace) in workspaces.enumerated() {
            workspace.sortOrder = Int64(index)
        }
    }

    @MainActor
    private static func nextSortOrder(in context: NSManagedObjectContext) throws -> Int64 {
        let request = NSFetchRequest<WorkspaceEntity>(entityName: "WorkspaceEntity")
        request.sortDescriptors = [NSSortDescriptor(keyPath: \WorkspaceEntity.sortOrder, ascending: false)]
        request.fetchLimit = 1
        return try context.fetch(request).first.map { $0.sortOrder + 1 } ?? 0
    }

    @MainActor
    @discardableResult
    static func remove(_ workspace: WorkspaceEntity, in context: NSManagedObjectContext) throws -> WorkspaceEntity {
        try requireEditable(workspace, in: context)
        let temporary = try prepare(in: context)
        let chatsRequest = NSFetchRequest<ChatEntity>(entityName: "ChatEntity")
        chatsRequest.predicate = NSPredicate(format: "workspace == %@", workspace)
        let chats = try context.fetch(chatsRequest)

        if !chats.isEmpty {
            let messagesRequest = NSFetchRequest<MessageEntity>(entityName: "MessageEntity")
            messagesRequest.predicate = NSPredicate(format: "chat IN %@", chats)
            for message in try context.fetch(messagesRequest) {
                context.delete(message)
            }
            for chat in chats {
                context.delete(chat)
            }
        }
        context.delete(workspace)
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        return temporary
    }

    @MainActor
    private static func requireEditable(_ workspace: WorkspaceEntity, in context: NSManagedObjectContext) throws {
        guard !workspace.isTemporary, workspace.id != temporaryWorkspaceID else {
            throw WorkspaceCreationError.temporaryWorkspace
        }
        let request = NSFetchRequest<ChatEntity>(entityName: "ChatEntity")
        request.predicate = NSPredicate(format: "workspace == %@ AND waitingForResponse == YES", workspace)
        guard try context.count(for: request) == 0 else {
            throw WorkspaceCreationError.activeConversation
        }
    }

    @MainActor
    private static func validatedValues(
        name: String,
        directory: URL,
        excluding workspace: WorkspaceEntity?,
        in context: NSManagedObjectContext
    ) throws -> (name: String, path: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw WorkspaceCreationError.missingName }
        let canonicalDirectory = directory.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonicalDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw WorkspaceCreationError.invalidDirectory }
        let request = NSFetchRequest<WorkspaceEntity>(entityName: "WorkspaceEntity")
        request.predicate = NSPredicate(format: "path == %@", canonicalDirectory.path)
        guard try context.fetch(request).allSatisfy({ $0 == workspace }) else {
            throw WorkspaceCreationError.duplicateDirectory
        }
        return (trimmedName, canonicalDirectory.path)
    }
}

enum WorkspaceCreationError: LocalizedError {
    case missingName
    case invalidDirectory
    case duplicateDirectory
    case temporaryWorkspace
    case activeConversation

    var errorDescription: String? {
        switch self {
        case .missingName:
            return "Enter a workspace name."
        case .invalidDirectory:
            return "Choose an existing folder."
        case .duplicateDirectory:
            return "A workspace already uses this folder."
        case .temporaryWorkspace:
            return "Temporary Chats cannot be edited or deleted."
        case .activeConversation:
            return "Wait for this workspace's active conversations to finish, or stop them before editing or deleting it."
        }
    }
}
