//
//  ChatDraftManager.swift
//  Chatmice
//
//  Created by Renat Notfullin on 10.01.2026.
//

import CoreData
import Foundation

final class ChatDraftManager: ObservableObject {
    private let viewContext: NSManagedObjectContext
    private let backgroundContext: NSManagedObjectContext
    private var saveWorkItem: DispatchWorkItem?
    private weak var pendingChat: ChatEntity?
    private var pendingMessageProvider: (() -> String)?
    private var pendingImageProvider: (() -> [ImageAttachment])?
    private var pendingFileProvider: (() -> [DocumentAttachment])?
    init(viewContext: NSManagedObjectContext) {
        self.viewContext = viewContext
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = viewContext.persistentStoreCoordinator
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        context.transactionAuthor = AppConstants.draftTransactionAuthor
        context.undoManager = nil
        self.backgroundContext = context
    }

    func scheduleSave(
        chat: ChatEntity,
        messageProvider: @escaping () -> String,
        imageProvider: @escaping () -> [ImageAttachment],
        fileProvider: @escaping () -> [DocumentAttachment],
        isEditingSystemMessage: Bool
    ) {
        guard !isEditingSystemMessage else { return }
        saveWorkItem?.cancel()

        pendingChat = chat
        pendingMessageProvider = messageProvider
        pendingImageProvider = imageProvider
        pendingFileProvider = fileProvider

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let chat = self.pendingChat else { return }
            let message = self.pendingMessageProvider?() ?? ""
            let imageIDs = (self.pendingImageProvider?() ?? [])
                .filter { $0.error == nil }
                .map(\.id)
            let fileIDs = (self.pendingFileProvider?() ?? [])
                .filter { $0.error == nil }
                .map(\.id)
            self.persistDraft(
                chatID: chat.objectID,
                message: message,
                imageIDs: imageIDs,
                fileIDs: fileIDs
            )
        }

        saveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: workItem)
    }

    func persistImmediately(
        chat: ChatEntity,
        message: String,
        images: [ImageAttachment],
        files: [DocumentAttachment],
        isEditingSystemMessage: Bool
    ) {
        guard !isEditingSystemMessage else { return }
        saveWorkItem?.cancel()
        let imageIDs = images
            .filter { $0.error == nil }
            .map(\.id)
        let fileIDs = files
            .filter { $0.error == nil }
            .map(\.id)
        persistDraft(
            chatID: chat.objectID,
            message: message,
            imageIDs: imageIDs,
            fileIDs: fileIDs
        )
    }

    func clearDraft(chat: ChatEntity) {
        persistDraft(
            chatID: chat.objectID,
            message: "",
            imageIDs: [],
            fileIDs: []
        )
    }

    func draftMessage(for chat: ChatEntity) -> String {
        fetchDraftSnapshot(for: chat.objectID).message
    }

    func draftSnapshot(for chat: ChatEntity) -> (message: String, imageIDs: [UUID], fileIDs: [UUID]) {
        fetchDraftSnapshot(for: chat.objectID)
    }

    func loadDraftAttachments(
        imageIDs: [UUID],
        fileIDs: [UUID]
    ) -> (images: [ImageAttachment], files: [DocumentAttachment]) {
        let images = loadDraftImages(ids: imageIDs)
        let files = loadDraftFiles(ids: fileIDs)
        return (images, files)
    }

    private func fetchDraftSnapshot(for chatID: NSManagedObjectID) -> (message: String, imageIDs: [UUID], fileIDs: [UUID]) {
        if chatID.isTemporaryID {
            return fetchDraftSnapshot(in: viewContext, chatID: chatID) ?? ("", [], [])
        }

        if let snapshot = fetchDraftSnapshot(in: backgroundContext, chatID: chatID, refreshIfNeeded: true) {
            return snapshot
        }

        return fetchDraftSnapshot(in: viewContext, chatID: chatID) ?? ("", [], [])
    }

    private func fetchDraftSnapshot(
        in context: NSManagedObjectContext,
        chatID: NSManagedObjectID,
        refreshIfNeeded: Bool = false
    ) -> (message: String, imageIDs: [UUID], fileIDs: [UUID])? {
        var snapshot: (message: String, imageIDs: [UUID], fileIDs: [UUID])?
        context.performAndWait {
            guard let chat = try? context.existingObject(with: chatID) as? ChatEntity else {
                return
            }
            if refreshIfNeeded, !context.hasChanges {
                context.refresh(chat, mergeChanges: true)
            }
            let message = detachString(chat.draftMessage)
            let imageIDsValue = chat.draftImageIDs.map { String($0) }
            let fileIDsValue = chat.draftFileIDs.map { String($0) }
            snapshot = (message, decodeDraftIDs(imageIDsValue), decodeDraftIDs(fileIDsValue))
        }
        return snapshot
    }

    private func persistDraft(
        chatID: NSManagedObjectID,
        message: String,
        imageIDs: [UUID],
        fileIDs: [UUID]
    ) {
        if chatID.isTemporaryID {
            viewContext.perform {
                do {
                    guard let chat = try self.viewContext.existingObject(with: chatID) as? ChatEntity else { return }
                    chat.draftMessage = message
                    chat.draftImageIDs = self.encodeDraftIDs(imageIDs)
                    chat.draftFileIDs = self.encodeDraftIDs(fileIDs)
                    self.viewContext.saveWithRetryOnQueue(attempts: 1)
                }
                catch {
                    print("Failed to persist draft in view context: \(error)")
                    self.viewContext.rollback()
                }
            }
            return
        }

        backgroundContext.perform {
            do {
                guard let chat = try self.backgroundContext.existingObject(with: chatID) as? ChatEntity else { return }
                chat.draftMessage = message
                chat.draftImageIDs = self.encodeDraftIDs(imageIDs)
                chat.draftFileIDs = self.encodeDraftIDs(fileIDs)
                self.backgroundContext.saveWithRetryOnQueue(attempts: 1)
            }
            catch {
                print("Failed to persist draft in background context: \(error)")
                self.backgroundContext.rollback()
            }
        }
    }

    private func loadDraftImages(ids: [UUID]) -> [ImageAttachment] {
        guard !ids.isEmpty else { return [] }
        var attachments: [ImageAttachment] = []
        viewContext.performAndWait {
            let request = NSFetchRequest<ImageEntity>(entityName: "ImageEntity")
            request.predicate = NSPredicate(format: "id IN %@", ids)

            let results = (try? viewContext.fetch(request)) ?? []
            let imageMap: [UUID: ImageEntity] = Dictionary(uniqueKeysWithValues: results.compactMap { entity in
                guard let id = entity.id else { return nil }
                return (id, entity)
            })

            attachments = ids.compactMap { id in
                guard let entity = imageMap[id] else { return nil }
                return ImageAttachment(imageEntity: entity)
            }
        }
        return attachments
    }

    private func loadDraftFiles(ids: [UUID]) -> [DocumentAttachment] {
        guard !ids.isEmpty else { return [] }
        var attachments: [DocumentAttachment] = []
        viewContext.performAndWait {
            let request = NSFetchRequest<DocumentEntity>(entityName: "DocumentEntity")
            request.predicate = NSPredicate(format: "id IN %@", ids)

            let results = (try? viewContext.fetch(request)) ?? []
            let fileMap: [UUID: DocumentEntity] = Dictionary(uniqueKeysWithValues: results.compactMap { entity in
                guard let id = entity.id else { return nil }
                return (id, entity)
            })

            attachments = ids.compactMap { id in
                guard let entity = fileMap[id] else { return nil }
                return DocumentAttachment(documentEntity: entity)
            }
        }
        return attachments
    }

    private func encodeDraftIDs(_ ids: [UUID]) -> String? {
        guard !ids.isEmpty else { return nil }
        let strings = ids.map { $0.uuidString }
        guard let data = try? JSONEncoder().encode(strings),
              let encoded = String(data: data, encoding: .utf8) else {
            return nil
        }
        return encoded
    }

    private func decodeDraftIDs(_ value: String?) -> [UUID] {
        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else { return [] }
        if let strings = try? JSONDecoder().decode([String].self, from: data) {
            return strings.compactMap { UUID(uuidString: $0) }
        }
        return []
    }

    private func detachString(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "" }
        let bytes = Array(value.utf8)
        return String(decoding: bytes, as: UTF8.self)
    }
}
