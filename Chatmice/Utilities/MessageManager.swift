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
    private var compactingChatIDs = Set<UUID>()

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
        if let responseToReplace { prepareForRetry(responseToReplace, in: chat) }
        beginActivity(for: chat.id)
        chat.waitingForResponse = true
        let temperature = (chat.persona?.temperature ?? AppConstants.defaultTemperatureForChat).roundedToOneDecimal()

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let didCompact = try await self.compactContextBeforeSendingIfNeeded(
                    chat: chat,
                    recentMessageLimit: contextSize
                )
                let requestMessages = self.prepareRequestMessages(
                    userMessage: message,
                    chat: chat,
                    contextSize: contextSize,
                    excluding: responseToReplace
                )
                if didCompact { self.persistRecalculatedContextUsage(chat: chat, requestMessages: requestMessages) }
                _ = self.apiService.consumeLatestTokenUsage()
                ChatActivityEvents.post(ChatActivityEvent(chatId: chat.id, kind: .waitingForModel))
                self.apiService.sendMessage(requestMessages, temperature: temperature) { [weak self] result in
                    Task { @MainActor in
                        self?.handleNonStreamingResult(
                            result,
                            chat: chat,
                            requestMessages: requestMessages,
                            completion: completion
                        )
                    }
                }
            } catch {
                chat.waitingForResponse = false
                self.endActivity(for: chat.id, kind: .failed(message: error.localizedDescription))
                completion(.failure(error))
            }
        }
    }

    @MainActor
    private func handleNonStreamingResult(
        _ result: Result<String, APIError>,
        chat: ChatEntity,
        requestMessages: [[String: String]],
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        switch result {
        case .success(let messageBody):
            chat.waitingForResponse = false
            let partsEnvelope = encodePartsEnvelope(
                from: (apiService as? GeminiHandler)?.consumeLastResponseParts(),
                serviceType: chat.apiService?.type
            )
            addMessageToChat(chat: chat, message: messageBody, partsEnvelope: partsEnvelope)
            replaceLastAssistantRequestMessage(
                in: chat,
                content: messageBody,
                geminiParts: decodePartsEnvelopeToBase64(partsEnvelope),
                isRetry: false
            )
            viewContext.saveWithRetry(attempts: 1)
            let usage = ContextManagement.resolvedUsage(
                reported: apiService.consumeLatestTokenUsage(),
                requestMessages: requestMessages,
                response: ToolActivityRecord.replacingMarkersForModel(in: messageBody)
            )
            persistContextUsage(chat: chat, usage: usage)
            endActivity(for: chat.id, kind: .completed)
            NotificationCenter.default.post(name: NSNotification.Name("NonStreamingMessageCompleted"), object: chat)
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
            completion(.success(()))
        case .failure(let error):
            chat.waitingForResponse = false
            endActivity(for: chat.id, kind: .failed(message: error.localizedDescription))
            completion(.failure(error))
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
        StreamingResponseStore.shared.begin(chatId: chat.id)

        streamTask = Task { [self] in
            var accumulatedResponse = ""
            var deferImageResponse = false
            var streamingMessage: MessageEntity?
            var postedStreamingActivity = false
            var requestMessages: [[String: String]] = []

            defer {
                StreamingResponseStore.shared.clear(chatId: chat.id)
                if self.streamGeneration == generation {
                    self.streamTask = nil
                    self.streamGeneration = nil
                    self.cancelRequested = false
                    chat.waitingForResponse = false
                    self.viewContext.saveWithRetry(attempts: 1)
                }
            }

            do {
                let didCompact = try await compactContextBeforeSendingIfNeeded(
                    chat: chat,
                    recentMessageLimit: contextSize
                )
                requestMessages = prepareRequestMessages(
                    userMessage: message,
                    chat: chat,
                    contextSize: contextSize,
                    excluding: responseToReplace
                )
                if didCompact { persistRecalculatedContextUsage(chat: chat, requestMessages: requestMessages) }
                _ = apiService.consumeLatestTokenUsage()
                ChatActivityEvents.post(ChatActivityEvent(chatId: chat.id, kind: .waitingForModel))
                let stream = try await apiService.sendMessageStream(requestMessages, temperature: temperature)
                AppLogger.shared.info("message.stream.started provider=\(apiService.name) chat=\(chat.id.uuidString)")
                for try await chunk in stream {
                    if Task.isCancelled || cancelRequested || streamGeneration != generation {
                        break
                    }
                    guard !chunk.isEmpty else { continue }
                    if !postedStreamingActivity, !chunk.contains(ToolActivityRecord.openingTag) {
                        postedStreamingActivity = true
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
                        StreamingResponseStore.shared.clear(chatId: chat.id)
                    }

                    if deferImageResponse { continue }

                    if streamingMessage == nil {
                        if chat.lastMessage?.own != false {
                            self.addMessageToChat(chat: chat, message: accumulatedResponse)
                        }
                        streamingMessage = chat.lastMessage?.own == false ? chat.lastMessage : nil
                    }
                    if StreamingResponseStore.shared.offer(accumulatedResponse, for: chat.id) {
                        await Task.yield()
                    }
                }

                guard !Task.isCancelled, !cancelRequested, streamGeneration == generation else {
                    if let streamingMessage, !accumulatedResponse.isEmpty {
                        StreamingResponseStore.shared.finish(accumulatedResponse, for: chat.id)
                        updateLastMessage(
                            chat: chat,
                            lastMessage: streamingMessage,
                            accumulatedResponse: accumulatedResponse
                        )
                    }
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

                StreamingResponseStore.shared.finish(accumulatedResponse, for: chat.id)
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
                let usage = ContextManagement.resolvedUsage(
                    reported: self.apiService.consumeLatestTokenUsage(),
                    requestMessages: requestMessages,
                    response: ToolActivityRecord.replacingMarkersForModel(in: accumulatedResponse)
                )
                persistContextUsage(chat: chat, usage: usage)
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
                if let streamingMessage, !accumulatedResponse.isEmpty {
                    StreamingResponseStore.shared.finish(accumulatedResponse, for: chat.id)
                    updateLastMessage(
                        chat: chat,
                        lastMessage: streamingMessage,
                        accumulatedResponse: accumulatedResponse
                    )
                }
                if streamGeneration == generation {
                    self.endActivity(for: chat.id, kind: .cancelled)
                }
                completion(.failure(CancellationError()))
            }
            catch {
                if let streamingMessage, !accumulatedResponse.isEmpty {
                    StreamingResponseStore.shared.finish(accumulatedResponse, for: chat.id)
                    updateLastMessage(
                        chat: chat,
                        lastMessage: streamingMessage,
                        accumulatedResponse: accumulatedResponse
                    )
                }
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
        newMessage.messageKind = .message
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
        ContextManagement.invalidateCheckpoints(in: chat, covering: response.sequence)
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
        contextSize _: Int,
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
            messages.append([
                "role": "user",
                "content": "Take this message as the system message: \(chat.systemMessage)",
            ])
        }

        let projection = ContextManagement.projection(in: chat.messagesArray)
        if let checkpoint = projection.checkpoint {
            messages.append([
                "role": "system",
                "content": "Conversation checkpoint covering earlier messages:\n\n\(checkpoint.body)",
            ])
        }
        let conversationMessages = projection.messages.filter { message in
            guard let responseToReplace else { return true }
            return message.objectID != responseToReplace.objectID
        }

        for message in conversationMessages {
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

        let lastMessage = messages.last?["content"] ?? ""
        if lastMessage != userMessage, let userMessage {
            messages.append([
                "role": "user",
                "content": userMessage,
            ])
        }

        return messages
    }

    @MainActor
    private func persistContextUsage(chat: ChatEntity, usage: ModelTokenUsage) {
        guard !chat.isDeleted else { return }
        chat.contextInputTokens = Int64(usage.inputTokens)
        chat.contextOutputTokens = Int64(usage.outputTokens)
        // A nil timestamp marks estimated counts; legacy positive counts with a date are reported.
        chat.contextUpdatedAt = usage.isEstimated ? nil : Date()
        viewContext.saveWithRetry(attempts: 1)
    }

    @MainActor
    private func persistRecalculatedContextUsage(
        chat: ChatEntity,
        requestMessages: [[String: String]]
    ) {
        let inputTokens = requestMessages.reduce(0) {
            $0 + ContextManagement.estimatedTokens(in: $1["content"] ?? "")
        }
        persistContextUsage(
            chat: chat,
            usage: ModelTokenUsage(inputTokens: inputTokens, outputTokens: 0, isEstimated: true)
        )
    }

    @MainActor
    private func compactContextBeforeSendingIfNeeded(
        chat: ChatEntity,
        recentMessageLimit: Int
    ) async throws -> Bool {
        guard !chat.isDeleted,
              let resolution = ModelContextRegistry.resolve(service: chat.apiService, modelID: chat.gptModel)
        else { return false }
        let usedTokens = Int(chat.contextInputTokens + chat.contextOutputTokens)
        guard ContextManagement.shouldCompact(
            inputTokens: usedTokens,
            contextWindowTokens: resolution.tokens
        ) else { return false }
        guard !compactingChatIDs.contains(chat.id) else {
            throw APIError.serverError("Context compaction is already in progress. Retry when it finishes.")
        }
        ChatActivityEvents.post(ChatActivityEvent(chatId: chat.id, kind: .compactingContext))

        let allMessages = chat.messagesArray
        let previousCheckpoint = ContextManagement.latestValidCheckpoint(in: allMessages)
        let previousCutoff = previousCheckpoint?.checkpointCoversThroughSequence ?? 0
        let uncompacted = allMessages.filter {
            $0.messageKind == .message && $0.sequence > previousCutoff
        }
        let candidateCount = ContextManagement.compactionCandidateCount(
            messages: uncompacted,
            inputTokens: usedTokens,
            contextWindowTokens: resolution.tokens,
            recentMessageLimit: recentMessageLimit
        )
        let candidates = Array(uncompacted.prefix(candidateCount))
        guard let cutoff = candidates.last?.sequence else {
            throw APIError.serverError(
                "The context is above the configured limit, but no older conversation messages are available to compact."
            )
        }

        compactingChatIDs.insert(chat.id)
        defer { compactingChatIDs.remove(chat.id) }
        AppLogger.shared.info(
            "context.compaction.preflight.started chat=\(chat.id.uuidString) "
                + "used=\(usedTokens) window=\(resolution.tokens)"
        )

        var sourceSections: [String] = []
        if let previousCheckpoint {
            sourceSections.append("Previous checkpoint:\n\(previousCheckpoint.body)")
        }
        sourceSections.append(
            candidates.map { message in
                let role = message.own ? "USER" : "ASSISTANT"
                return "\(role) [message \(message.sequence)]:\n\(message.body)"
            }.joined(separator: "\n\n")
        )

        do {
            let result = try await apiService.compactContext(sourceSections.joined(separator: "\n\n"))
            guard !chat.isDeleted, candidates.allSatisfy({ !$0.isDeleted }) else { return false }
            let checkpoint = MessageEntity(context: viewContext)
            checkpoint.messageKind = .contextCheckpoint
            checkpoint.name = "Context checkpoint"
            checkpoint.body = result.summary
            checkpoint.timestamp = Date()
            checkpoint.own = false
            checkpoint.waitingForResponse = false
            checkpoint.checkpointCoversThroughSequence = cutoff
            checkpoint.checkpointOriginalTokens = Int64(usedTokens)
            checkpoint.checkpointCompactedTokens = Int64(
                result.usage?.outputTokens ?? ContextManagement.estimatedTokens(in: result.summary)
            )
            checkpoint.checkpointValid = true
            checkpoint.chat = chat
            chat.addToMessages(checkpoint)
            chat.objectWillChange.send()
            viewContext.saveWithRetry(attempts: 1)
            AppLogger.shared.info(
                "context.compaction.preflight.completed chat=\(chat.id.uuidString) "
                    + "original=\(usedTokens) compacted=\(checkpoint.checkpointCompactedTokens) cutoff=\(cutoff)"
            )
            return true
        } catch {
            AppLogger.shared.error(
                "context.compaction.preflight.failed chat=\(chat.id.uuidString) error=\(error.localizedDescription)"
            )
            throw error
        }
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
