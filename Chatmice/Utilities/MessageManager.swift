//
//  MessageManager.swift
//  Chatmice
//
//  Created by Renat on 28.07.2024.
//

import CoreData
import Foundation

class MessageManager: ObservableObject {
    private var apiService: APIService
    private var viewContext: NSManagedObjectContext
    private var streamTask: Task<Void, Never>?
    private var cancelRequested = false
    private var streamGeneration: UUID?
    private var activeChatId: UUID?

    init(apiService: APIService, viewContext: NSManagedObjectContext) {
        self.apiService = apiService
        self.viewContext = viewContext
    }

    func update(apiService: APIService, viewContext: NSManagedObjectContext) {
        self.apiService = apiService
        self.viewContext = viewContext
    }

    private func beginActivity(for chatId: UUID) {
        activeChatId = chatId
        ChatActivityEvents.post(ChatActivityEvent(chatId: chatId, kind: .started))
        ChatActivityEvents.post(ChatActivityEvent(chatId: chatId, kind: .waitingForModel))

        (apiService as? AgentActivityReporting)?.setActivityHandler { signal in
            let kind: ChatActivityEventKind
            switch signal {
            case .waitingForModel:
                kind = .waitingForModel
            case .awaitingApproval(let tool, let detail):
                kind = .awaitingApproval(tool: tool, detail: detail)
            case .runningTool(let tool, let detail):
                kind = .runningTool(tool: tool, detail: detail)
            case .processingToolResult(let tool):
                kind = .processingToolResult(tool: tool)
            }
            ChatActivityEvents.post(ChatActivityEvent(chatId: chatId, kind: kind))
        }
    }

    private func endActivity(for chatId: UUID, kind: ChatActivityEventKind) {
        ChatActivityEvents.post(ChatActivityEvent(chatId: chatId, kind: kind))
        (apiService as? AgentActivityReporting)?.setActivityHandler(nil)
        if activeChatId == chatId {
            activeChatId = nil
        }
    }

    func sendMessage(
        _ message: String,
        in chat: ChatEntity,
        contextSize: Int,
        replacing responseToReplace: MessageEntity? = nil,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let requestMessages = prepareRequestMessages(
            userMessage: message,
            chat: chat,
            contextSize: contextSize,
            excluding: responseToReplace
        )
        if let responseToReplace {
            prepareForRetry(responseToReplace, in: chat)
        }
        beginActivity(for: chat.id)
        chat.waitingForResponse = true
        let temperature = (chat.persona?.temperature ?? AppConstants.defaultTemperatureForChat).roundedToOneDecimal()

        let handleResult: (Result<String, APIError>) -> Void = { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let messageBody):
                chat.waitingForResponse = false
                let partsEnvelope = encodePartsEnvelope(
                    from: (self.apiService as? GeminiHandler)?.consumeLastResponseParts(),
                    serviceType: chat.apiService?.type
                )
                self.addMessageToChat(chat: chat, message: messageBody, partsEnvelope: partsEnvelope)
                self.replaceLastAssistantRequestMessage(
                    in: chat,
                    content: messageBody,
                    geminiParts: decodePartsEnvelopeToBase64(partsEnvelope),
                    isRetry: false
                )
                self.viewContext.saveWithRetry(attempts: 1)
                self.endActivity(for: chat.id, kind: .completed)

                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: NSNotification.Name("NonStreamingMessageCompleted"),
                        object: chat
                    )
                    NotificationCenter.default.post(
                        name: NSNotification.Name("ChatResponseCompleted"),
                        object: chat,
                        userInfo: [
                            "responseId": UUID().uuidString,
                            "chatId": chat.id,
                            "message": messageBody,
                            "chatName": chat.name,
                        ]
                    )
                }

                completion(.success(()))

            case .failure(let error):
                chat.waitingForResponse = false
                self.endActivity(for: chat.id, kind: .failed(message: error.localizedDescription))
                completion(.failure(error))
            }
        }

        apiService.sendMessage(requestMessages, temperature: temperature) { result in
            handleResult(result)
        }
    }

    @MainActor
    func sendMessageStream(
        _ message: String,
        in chat: ChatEntity,
        contextSize: Int,
        replacing responseToReplace: MessageEntity? = nil,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let requestMessages = prepareRequestMessages(
            userMessage: message,
            chat: chat,
            contextSize: contextSize,
            excluding: responseToReplace
        )
        if let responseToReplace {
            prepareForRetry(responseToReplace, in: chat)
        }

        streamTask?.cancel()
        apiService.cancelCurrentRequest()

        let generation = UUID()
        streamGeneration = generation
        cancelRequested = false
        let temperature = (chat.persona?.temperature ?? AppConstants.defaultTemperatureForChat).roundedToOneDecimal()
        beginActivity(for: chat.id)
        chat.waitingForResponse = true

        streamTask = Task { [self] in
            defer {
                if self.streamGeneration == generation {
                    self.streamTask = nil
                    self.streamGeneration = nil
                    self.cancelRequested = false
                    chat.waitingForResponse = false
                    self.viewContext.saveWithRetry(attempts: 1)
                }
            }

            do {
                let stream = try await apiService.sendMessageStream(requestMessages, temperature: temperature)
                AppLogger.shared.info("message.stream.started provider=\(apiService.name) chat=\(chat.id.uuidString)")
                var accumulatedResponse = ""
                var deferImageResponse = false
                var streamingMessage: MessageEntity?

                for try await chunk in stream {
                    if Task.isCancelled || cancelRequested || streamGeneration != generation {
                        break
                    }
                    guard !chunk.isEmpty else { continue }
                    if !chunk.contains(ToolActivityRecord.openingTag) {
                        ChatActivityEvents.post(ChatActivityEvent(chatId: chat.id, kind: .streamingResponse))
                    }

                    accumulatedResponse += chunk

                    if !deferImageResponse && chunk.contains("<image-uuid>") {
                        deferImageResponse = true
                        if let message = streamingMessage ?? (chat.lastMessage?.own == false ? chat.lastMessage : nil) {
                            chat.removeFromMessages(message)
                            viewContext.delete(message)
                            streamingMessage = nil
                            chat.objectWillChange.send()
                        }
                    }

                    if deferImageResponse { continue }
                    guard let lastMessage = chat.lastMessage else { continue }

                    if lastMessage.own {
                        self.addMessageToChat(chat: chat, message: accumulatedResponse)
                        streamingMessage = chat.lastMessage
                    }
                    else {
                        updateLastMessage(
                            chat: chat,
                            lastMessage: lastMessage,
                            accumulatedResponse: accumulatedResponse
                        )
                        streamingMessage = lastMessage
                    }
                }

                guard !Task.isCancelled, !cancelRequested, streamGeneration == generation else {
                    if streamGeneration == generation {
                        self.endActivity(for: chat.id, kind: .cancelled)
                    }
                    completion(.failure(CancellationError()))
                    return
                }

                guard !accumulatedResponse.isEmpty else {
                    AppLogger.shared.error("message.stream.empty provider=\(apiService.name) chat=\(chat.id.uuidString)")
                    self.endActivity(
                        for: chat.id,
                        kind: .failed(message: APIError.invalidResponse.localizedDescription)
                    )
                    completion(.failure(APIError.invalidResponse))
                    return
                }

                let geminiParts = encodePartsEnvelope(
                    from: (self.apiService as? GeminiHandler)?.consumeLastResponseParts(),
                    serviceType: chat.apiService?.type
                )

                if deferImageResponse {
                    self.addMessageToChat(chat: chat, message: accumulatedResponse, partsEnvelope: geminiParts)
                }
                else if let assistantMessage = streamingMessage
                    ?? (chat.lastMessage?.own == false ? chat.lastMessage : nil)
                {
                    updateLastMessage(
                        chat: chat,
                        lastMessage: assistantMessage,
                        accumulatedResponse: accumulatedResponse
                    )
                    assistantMessage.messageParts = geminiParts
                }
                else {
                    self.addMessageToChat(chat: chat, message: accumulatedResponse, partsEnvelope: geminiParts)
                }

                replaceLastAssistantRequestMessage(
                    in: chat,
                    content: accumulatedResponse,
                    geminiParts: decodePartsEnvelopeToBase64(geminiParts),
                    isRetry: false
                )

                try? self.viewContext.save()
                NotificationCenter.default.post(
                    name: NSNotification.Name("ChatResponseCompleted"),
                    object: chat,
                    userInfo: [
                        "responseId": UUID().uuidString,
                        "chatId": chat.id,
                        "message": accumulatedResponse,
                        "chatName": chat.name,
                    ]
                )
                self.endActivity(for: chat.id, kind: .completed)
                completion(.success(()))
            }
            catch is CancellationError {
                if streamGeneration == generation {
                    self.endActivity(for: chat.id, kind: .cancelled)
                }
                completion(.failure(CancellationError()))
            }
            catch {
                AppLogger.shared.error(
                    "message.stream.failed provider=\(apiService.name) chat=\(chat.id.uuidString) error=\(error.localizedDescription)"
                )
                if streamGeneration == generation {
                    self.endActivity(for: chat.id, kind: .failed(message: error.localizedDescription))
                }
                completion(.failure(error))
            }

        }
    }

    func cancelCurrentRequest() {
        cancelRequested = true
        streamTask?.cancel()
        apiService.cancelCurrentRequest()
        if let activeChatId {
            endActivity(for: activeChatId, kind: .cancelled)
        }
    }

    func generateChatNameIfNeeded(chat: ChatEntity, force: Bool = false) {
        guard force || chat.name == "", !chat.messagesArray.isEmpty else {
            #if DEBUG
                print("Chat name not needed, skipping generation")
            #endif
            return
        }

        let firstUserMessage = chat.messagesArray.first(where: { $0.own })?.body ?? ""
        let titleSource = String(firstUserMessage.prefix(4_000))
        let requestMessages: [[String: String]] = [
            ["role": "system", "content": chat.systemMessage],
            ["role": "user", "content": titleSource],
            ["role": "user", "content": AppConstants.chatGptGenerateChatInstruction],
        ]
        let personaTemperature = (chat.persona?.temperature ?? AppConstants.defaultTemperatureForChat)
            .roundedToOneDecimal()

        apiService.sendMessage(requestMessages, temperature: personaTemperature) {
            [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let messageBody):
                let chatName = self.sanitizeChatName(messageBody)
                chat.name = chatName
                self.viewContext.saveWithRetry(attempts: 3)
            case .failure(let error):
                print("Error generating chat name: \(error)")
            }
        }
    }

    private func sanitizeChatName(_ rawName: String) -> String {
        if let range = rawName.range(of: "**(.+?)**", options: .regularExpression) {
            return String(rawName[range]).trimmingCharacters(in: CharacterSet(charactersIn: "*"))
        }

        let lines = rawName.components(separatedBy: .newlines)
        if let lastNonEmptyLine = lines.last(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return lastNonEmptyLine.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testAPI(model: String, completion: @escaping (Result<Void, Error>) -> Void) {
        var requestMessages: [[String: String]] = []
        let temperature: Float = 1

        if !AppConstants.openAiReasoningModels.contains(model) {
            requestMessages.append([
                "role": "system",
                "content": "You are a test assistant.",
            ])
        }

        requestMessages.append(
            [
                "role": "user",
                "content": "This is a test message.",
            ])

        apiService.sendMessage(requestMessages, temperature: temperature) { result in
            switch result {
            case .success(_):
                completion(.success(()))

            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    private func prepareRequestMessages(
        userMessage: String,
        chat: ChatEntity,
        contextSize: Int,
        excluding responseToReplace: MessageEntity? = nil
    ) -> [[String: String]] {
        var messages = constructRequestMessages(
            chat: chat,
            forUserMessage: userMessage,
            contextSize: contextSize,
            excluding: responseToReplace
        )

        // Strip vendor-specific payloads when current service is not Gemini to avoid API validation errors.
        if !(apiService is GeminiHandler) {
            messages = messages.map { msg in
                var m = msg
                m.removeValue(forKey: "message_parts")
                return m
            }
        }

        return messages
    }

    private func addMessageToChat(chat: ChatEntity, message: String, partsEnvelope: Data? = nil) {
        let newMessage = MessageEntity(context: self.viewContext)
        let sequence = chat.nextSequence()
        newMessage.id = sequence
        if chat.responds(to: #selector(getter: MessageEntity.sequence))
            || (chat.managedObjectContext?.persistentStoreCoordinator?.managedObjectModel.entitiesByName[
                "MessageEntity"
            ]?.attributesByName["sequence"] != nil)
        {
            newMessage.sequence = sequence
        }
        newMessage.body = message
        newMessage.timestamp = Date()
        newMessage.own = false
        newMessage.messageParts = partsEnvelope
        newMessage.chat = chat

        chat.updatedDate = Date()
        chat.addToMessages(newMessage)
        viewContext.processPendingChanges()
        chat.objectWillChange.send()
    }

    private func addNewMessageToRequestMessages(
        chat: ChatEntity,
        content: String,
        role: String,
        geminiParts: String? = nil
    ) {
        var message: [String: String] = ["role": role, "content": content]
        if let geminiParts {
            message["message_parts"] = geminiParts
        }
        chat.requestMessages.append(message)
    }

    private func prepareForRetry(_ response: MessageEntity, in chat: ChatEntity) {
        if let lastAssistantIndex = chat.requestMessages.lastIndex(where: { $0["role"] == AppConstants.defaultRole }) {
            chat.requestMessages.remove(at: lastAssistantIndex)
        }
        guard !response.isDeleted else { return }
        chat.removeFromMessages(response)
        viewContext.delete(response)
        viewContext.processPendingChanges()
        chat.objectWillChange.send()
        viewContext.saveWithRetry(attempts: 1)
    }

    private func replaceLastAssistantRequestMessage(
        in chat: ChatEntity,
        content: String,
        geminiParts: String?,
        isRetry: Bool
    ) {
        if isRetry,
            let lastAssistantIndex = chat.requestMessages.lastIndex(where: { $0["role"] == AppConstants.defaultRole })
        {
            chat.requestMessages.remove(at: lastAssistantIndex)
        }
        addNewMessageToRequestMessages(
            chat: chat,
            content: content,
            role: AppConstants.defaultRole,
            geminiParts: geminiParts
        )
    }

    private func updateLastMessage(chat: ChatEntity, lastMessage: MessageEntity, accumulatedResponse: String) {
        lastMessage.body = accumulatedResponse
        lastMessage.timestamp = Date()
        lastMessage.waitingForResponse = false
        chat.updatedDate = Date()

        chat.objectWillChange.send()
    }

    private func constructRequestMessages(
        chat: ChatEntity,
        forUserMessage userMessage: String?,
        contextSize: Int,
        excluding responseToReplace: MessageEntity? = nil
    ) -> [[String: String]] {
        var messages: [[String: String]] = []

        if !AppConstants.openAiReasoningModels.contains(chat.gptModel) {
            messages.append([
                "role": "system",
                "content": chat.systemMessage,
            ])
        }
        else {
            // Models like o1-mini and o1-preview don't support "system" role. However, we can pass the system message with "user" role instead.
            messages.append([
                "role": "user",
                "content": "Take this message as the system message: \(chat.systemMessage)",
            ])
        }

        let sortedMessages = chat.messagesArray
            .filter { message in
                guard let responseToReplace else { return true }
                return message.objectID != responseToReplace.objectID
            }
            .suffix(contextSize)

        // Add conversation history
        for message in sortedMessages {
            var payload: [String: String] = [
                "role": message.own ? "user" : "assistant",
                "content": ToolActivityRecord.replacingMarkersForModel(in: message.body),
            ]

            if let envelope = message.messageParts,
                let base64 = decodePartsEnvelopeToBase64(envelope),
                envelopeHasVendorGemini(envelope)
            {
                payload["message_parts"] = base64
            }

            messages.append(payload)
        }

        // Add new user message if provided
        let lastMessage = messages.last?["content"] ?? ""
        if lastMessage != userMessage {
            if let userMessage = userMessage {
                messages.append([
                    "role": "user",
                    "content": userMessage,
                ])
            }
        }

        return messages
    }

    // MARK: - Parts encoding helpers
    private func encodePartsEnvelope(from parts: [GeminiPartRequest]?, serviceType: String?) -> Data? {
        guard let parts, !parts.isEmpty else { return nil }
        let envelope = PartsEnvelope(serviceType: (serviceType ?? "gemini"), parts: parts)
        return try? JSONEncoder().encode(envelope)
    }

    private func decodePartsEnvelopeToBase64(_ data: Data?) -> String? {
        guard let data else { return nil }
        return data.base64EncodedString()
    }

    private func envelopeHasVendorGemini(_ data: Data) -> Bool {
        guard let env = try? JSONDecoder().decode(PartsEnvelope.self, from: data) else { return false }
        return env.serviceType.lowercased() == "gemini"
    }
}
