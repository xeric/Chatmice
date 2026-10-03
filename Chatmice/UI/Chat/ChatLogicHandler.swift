//
//  ChatLogicHandler.swift
//  Chatmice
//
//  Created by Renat Notfullin on 20.01.2025.
//

import CoreData
import SwiftUI
import Foundation
import UniformTypeIdentifiers

@MainActor
final class ChatLogicHandler: ObservableObject {
    private let viewContext: NSManagedObjectContext
    private let chat: ChatEntity
    private let chatViewModel: ChatViewModel
    
    @Published var currentError: ErrorMessage?
    @Published var isStreaming: Bool = false
    @Published var userIsScrolling: Bool = false
    private var activeRequestID: UUID?
    
    init(viewContext: NSManagedObjectContext, chat: ChatEntity, chatViewModel: ChatViewModel) {
        self.viewContext = viewContext
        self.chat = chat
        self.chatViewModel = chatViewModel
    }
    
    func sendMessage(messageText: String, attachedImages: [ImageAttachment], attachedFiles: [DocumentAttachment]) {
        guard !chat.waitingForResponse, !isStreaming else { return }
        guard chatViewModel.canSendMessage else {
            currentError = ErrorMessage(
                type: .noApiService("No API service selected. Select the API service to send your first message"),
                timestamp: Date()
            )
            return
        }

        resetError()

        let pendingImages = attachedImages.filter { !$0.isReadyForUpload }
        let pendingFiles = attachedFiles.filter { !$0.isReadyForUpload }
        if !pendingImages.isEmpty || !pendingFiles.isEmpty {
            let hasErrors = pendingImages.contains { $0.error != nil } || pendingFiles.contains { $0.error != nil }
            let message = hasErrors
                ? "One or more attachments failed to load. Remove them or try again."
                : "Attachments are still loading. Please wait until they finish."
            currentError = ErrorMessage(type: .attachmentNotReady(message), timestamp: Date())
            return
        }

        var messageContents: [MessageContent] = []

        if !messageText.isEmpty {
            messageContents.append(MessageContent(text: messageText))
        }

        for attachment in attachedImages {
            if attachment.imageEntity?.image == nil {
                attachment.saveToEntity(context: viewContext, waitForCompletion: true)
            }
            messageContents.append(MessageContent(imageAttachment: attachment))
        }

        for attachment in attachedFiles {
            if attachment.documentEntity?.fileData == nil {
                attachment.saveToEntity(context: viewContext, waitForCompletion: true)
            }
            messageContents.append(MessageContent(fileAttachment: attachment))
        }

        let messageBody: String
        let hasAttachments = !attachedImages.isEmpty || !attachedFiles.isEmpty

        if hasAttachments {
            messageBody = messageContents.toString()
        } else {
            messageBody = messageText
        }

        saveNewMessageInStore(with: messageBody)
        userIsScrolling = false

        if chat.apiService?.useStreamResponse ?? true {
            sendStreamMessage(messageBody)
        } else {
            sendRegularMessage(messageBody)
        }
    }
    
    func selectAndAddImages(completion: @escaping ([ImageAttachment]) -> Void) {
        guard chat.apiService?.imageUploadsAllowed == true else { return }

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.jpeg, .png, .heic, .heif, UTType(filenameExtension: "webp")].compactMap { $0 }
        panel.title = "Select Images"
        panel.message = "Choose images to upload"

        panel.begin { response in
            if response == .OK {
                var newAttachments: [ImageAttachment] = []
                for url in panel.urls {
                    let attachment = ImageAttachment(url: url, context: self.viewContext)
                    newAttachments.append(attachment)
                }
                DispatchQueue.main.async {
                    completion(newAttachments)
                }
            }
        }
    }

    func selectAndAddPDFs(completion: @escaping ([DocumentAttachment]) -> Void) {
        guard supportsPDFUploads() else { return }

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.pdf]
        panel.title = "Select PDFs"
        panel.message = "Choose PDF documents to upload"

        panel.begin { response in
            if response == .OK {
                var newAttachments: [DocumentAttachment] = []
                for url in panel.urls {
                    let attachment = DocumentAttachment(url: url, context: self.viewContext)
                    newAttachments.append(attachment)
                }
                DispatchQueue.main.async {
                    completion(newAttachments)
                }
            }
        }
    }
    
    func handleRetryMessage() {
        guard chatViewModel.canSendMessage else {
            currentError = ErrorMessage(
                type: .noApiService("No API service selected. Select an API service before retrying."),
                timestamp: Date()
            )
            return
        }

        if chat.waitingForResponse || isStreaming {
            chatViewModel.stopInference()
            handleResponseFinished()
        }

        let messages = chatViewModel.sortedMessages
        let responseToReplace = messages.last.flatMap { $0.own ? nil : $0 }
        let userMessage = responseToReplace == nil
            ? messages.last(where: { $0.own })
            : messages.dropLast().last(where: { $0.own })

        guard let userMessage, !userMessage.body.isEmpty else { return }

        resetError()
        userIsScrolling = false

        if chat.apiService?.useStreamResponse ?? true {
            sendStreamMessage(userMessage.body, replacing: responseToReplace)
        } else {
            sendRegularMessage(userMessage.body, replacing: responseToReplace)
        }
    }
    
    func ignoreError() {
        currentError = nil
    }
    
    // MARK: - Private Methods
    
    private func sendStreamMessage(_ messageBody: String, replacing responseToReplace: MessageEntity? = nil) {
        let requestID = UUID()
        activeRequestID = requestID
        isStreaming = true
        chat.waitingForResponse = true
        chatViewModel.sendMessageStream(
            messageBody,
            contextSize: Int(chat.apiService?.contextSize ?? Int16(AppConstants.chatGptContextSize)),
            replacing: responseToReplace
        ) { [weak self] result in
            Task { @MainActor in
                guard let self, self.activeRequestID == requestID else { return }
                switch result {
                case .success:
                    self.handleResponseFinished(requestID: requestID)
                    self.chatViewModel.generateChatNameIfNeeded()
                case .failure(let error):
                    if !self.shouldSuppressError(error) {
                        print("Error sending message: \(error)")
                        let apiError = error as? APIError ?? .unknown("Unknown error occurred")
                        self.currentError = ErrorMessage(type: apiError, timestamp: Date())
                    }
                    self.handleResponseFinished(requestID: requestID)
                }
            }
        }
    }
    
    private func sendRegularMessage(_ messageBody: String, replacing responseToReplace: MessageEntity? = nil) {
        let requestID = UUID()
        activeRequestID = requestID
        chat.waitingForResponse = true
        chatViewModel.sendMessage(
            messageBody,
            contextSize: Int(chat.apiService?.contextSize ?? Int16(AppConstants.chatGptContextSize)),
            replacing: responseToReplace
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.activeRequestID == requestID else { return }
                switch result {
                case .success:
                    self.chatViewModel.generateChatNameIfNeeded()
                    self.handleResponseFinished(requestID: requestID)
                case .failure(let error):
                    if !self.shouldSuppressError(error) {
                        print("Error sending message: \(error)")
                        let apiError = error as? APIError ?? .unknown("Unknown error occurred")
                        self.currentError = ErrorMessage(type: apiError, timestamp: Date())
                    }
                    self.handleResponseFinished(requestID: requestID)
                }
            }
        }
    }
    
    private func saveNewMessageInStore(with messageBody: String) {
        let newMessageEntity = MessageEntity(context: viewContext)
        let sequence = chat.nextSequence()
        newMessageEntity.id = sequence
        if chat.managedObjectContext?.persistentStoreCoordinator?.managedObjectModel.entitiesByName["MessageEntity"]?.attributesByName["sequence"] != nil {
            newMessageEntity.sequence = sequence
        }
        newMessageEntity.body = messageBody
        newMessageEntity.timestamp = Date()
        newMessageEntity.own = true
        newMessageEntity.chat = chat

        chat.updatedDate = Date()
        chat.addToMessages(newMessageEntity)
        chat.objectWillChange.send()
        
        viewContext.saveWithRetry(attempts: 1)
    }
    
    private func handleResponseFinished(requestID: UUID? = nil) {
        if let requestID, activeRequestID != requestID { return }
        activeRequestID = nil
        isStreaming = false
        chat.waitingForResponse = false
        userIsScrolling = false
        viewContext.saveWithRetry(attempts: 1)
    }

    func stopInference() {
        guard chat.waitingForResponse || isStreaming else { return }
        activeRequestID = nil
        chatViewModel.stopInference()
        handleResponseFinished()
    }

    private func shouldSuppressError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let apiError = error as? APIError {
            switch apiError {
            case .requestFailed(let underlyingError):
                let nsError = underlyingError as NSError
                return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
            default:
                return false
            }
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }
    
    private func resetError() {
        currentError = nil
    }

    private func supportsPDFUploads() -> Bool {
        return chat.apiService?.pdfUploadsAllowed == true
    }
}
