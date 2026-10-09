//
//  ChatView.swift
//  Chatmice

//
//  Created by Renat Notfullin on 18.03.2023.
//

import Combine
import CoreData
import SwiftUI
import UniformTypeIdentifiers

@Observable
final class ChatInputBuffer {
    var text: String

    init(text: String = "") {
        self.text = text
    }
}

struct ChatView: View {
    let viewContext: NSManagedObjectContext
    @ObservedObject var chat: ChatEntity
    @Binding var searchText: String
    let window: NSWindow?
    @AppStorage("lastOpenedChatId") var lastOpenedChatId = ""

    // UI State
    @State private var messageField = ""
    @State private var inputBuffer: ChatInputBuffer
    @State private var editSystemMessage: Bool = false
    @State private var attachedImages: [ImageAttachment] = []
    @State private var attachedFiles: [DocumentAttachment] = []
    @State private var attachedAudio: DocumentAttachment?
    @State private var isBottomContainerExpanded = false
    @State private var reasoningStartTimes: [NSManagedObjectID: Date] = [:]
    @State private var reasoningDurations: [NSManagedObjectID: TimeInterval] = [:]
    @State private var lastRequestStartTime: Date?
    @State private var activeReasoningMessageID: NSManagedObjectID?
    @State private var modelCapabilityRevision = 0

    // View models and logic
    @ObservedObject private var chatViewModel: ChatViewModel
    @ObservedObject private var logicHandler: ChatLogicHandler
    @StateObject private var draftManager: ChatDraftManager

    // Environment
    @Environment(\.colorScheme) private var colorScheme
    var backgroundColor = Color.clear
    private let reasoningTimer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    // MARK: - Initialization
    init(
        viewContext: NSManagedObjectContext,
        chat: ChatEntity,
        searchText: Binding<String>,
        window: NSWindow?
    ) {
        self.viewContext = viewContext
        self._chat = ObservedObject(wrappedValue: chat)
        self._searchText = searchText
        self.window = window

        // Initialize view models
        let viewModel = ChatViewModel(chat: chat, viewContext: viewContext)
        self._chatViewModel = ObservedObject(wrappedValue: viewModel)

        // Keep request state tied to the selected chat without resetting the full view identity.
        let handler = ChatLogicHandler(viewContext: viewContext, chat: chat, chatViewModel: viewModel)
        self._logicHandler = ObservedObject(wrappedValue: handler)
        let draftManager = ChatDraftManager(viewContext: viewContext)
        self._draftManager = StateObject(wrappedValue: draftManager)

        let draftSnapshot = draftManager.draftSnapshot(for: chat)
        let attachmentSnapshot = draftManager.loadDraftAttachments(
            imageIDs: draftSnapshot.imageIDs,
            fileIDs: draftSnapshot.fileIDs
        )
        self._inputBuffer = State(initialValue: ChatInputBuffer(text: draftSnapshot.message))
        self._attachedImages = State(initialValue: attachmentSnapshot.images)
        self._attachedFiles = State(initialValue: attachmentSnapshot.files)
    }

    private var pdfUploadsAllowed: Bool {
        chat.apiService?.pdfUploadsAllowed ?? false
    }

    private var imageUploadsAllowed: Bool {
        _ = modelCapabilityRevision
        guard let service = chat.apiService else { return false }
        let testedVision = service.id.flatMap {
            ModelCapabilityTestStore.results(for: $0)[chat.gptModel]?.visionSupported
        }
        if testedVision == false { return false }
        if service.imageUploadsAllowed { return true }
        return service.type?.lowercased() == "deepseek" && testedVision == true
    }

    private var imageGenerationSupported: Bool {
        chat.apiService?.imageGenerationSupported ?? false
    }

    private var audioInputAllowed: Bool {
        AudioInputCapability.supportsAudio(serviceType: chat.apiService?.type, modelID: chat.gptModel)
    }

    private var isInferenceInProgress: Bool {
        logicHandler.isStreaming || chat.waitingForResponse
    }

    private var attachmentDraftSignature: AttachmentDraftSignature {
        AttachmentDraftSignature(
            imageIDs: attachedImages.map(\.id),
            fileIDs: attachedFiles.map(\.id),
            imageReadyStates: attachedImages.map(\.isReadyForUpload),
            fileReadyStates: attachedFiles.map(\.isReadyForUpload)
        )
    }

    // MARK: - Body
    var body: some View {
        VStack(spacing: 0) {
            chatMessagesView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            chatInputView
                .fixedSize(horizontal: false, vertical: true)
        }
        .background(backgroundColor)
        .navigationTitle(chat.name != "" ? chat.name : chat.persona?.name ?? "Chatmice LLM chat")
        .onAppear {
            self.lastOpenedChatId = chat.id.uuidString
        }
        .onReceive(NotificationCenter.default.publisher(for: ModelCapabilityTestStore.didChangeNotification)) {
            notification in
            guard notification.object as? UUID == chat.apiService?.id else { return }
            modelCapabilityRevision += 1
        }
        .onChange(of: chat.objectID) { oldChatID, newChatID in
            DispatchQueue.main.async {
                guard chat.objectID == newChatID else { return }
                switchConversation(from: oldChatID)
            }
        }
        .onDisappear {
            draftManager.persistImmediately(
                chat: chat,
                message: inputBuffer.text,
                images: attachedImages,
                files: attachedFiles,
                isEditingSystemMessage: editSystemMessage
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("RecreateMessageManager"))) {
            notification in
            if let chatId = notification.userInfo?["chatId"] as? UUID,
                chatId == chat.id
            {
                print("RecreateMessageManager notification received for chat \(chatId)")
                chatViewModel.recreateMessageManager()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("RetryMessage"))) { notification in
            if let targetChatID = notification.userInfo?["chatId"] as? UUID {
                guard targetChatID == chat.id else { return }
            }
            else if let targetWindowID = notification.userInfo?["windowId"] as? Int {
                guard targetWindowID != 0, targetWindowID == window?.windowNumber else { return }
            }
            else {
                return
            }
            lastRequestStartTime = Date()
            logicHandler.handleRetryMessage()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("StopInference"))) { _ in
            logicHandler.stopInference()
            resetReasoningTimingState()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("IgnoreError"))) { _ in
            logicHandler.ignoreError()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("FindNext"))) { _ in
            if !searchText.isEmpty {
                chatViewModel.goToNextOccurrence()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("FindPrevious"))) { _ in
            if !searchText.isEmpty {
                chatViewModel.goToPreviousOccurrence()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ChatResponseCompleted"))) {
            notification in
            guard let notificationChat = notification.object as? ChatEntity, notificationChat == chat else { return }
            if let lastMessage = chat.lastMessage, !lastMessage.own {
                finalizeReasoningTimingIfNeeded(for: lastMessage)
            }
            lastRequestStartTime = nil
        }
        .onReceive(reasoningTimer) { _ in
            updateLiveReasoningDurationIfNeeded()
        }
        .toolbar {
            if !searchText.isEmpty && !chatViewModel.searchOccurrences.isEmpty {
                SearchNavigationView(chatViewModel: chatViewModel)
            }
        }
        .onChange(of: searchText) { _, newSearchText in
            chatViewModel.updateSearchOccurrences(searchText: newSearchText)
        }
        .onChange(of: attachmentDraftSignature) {
            guard !editSystemMessage else { return }
            scheduleDraftSave()
        }
        .onChange(of: editSystemMessage) { _, isEditing in
            if !isEditing, inputBuffer.text.isEmpty {
                inputBuffer.text = draftManager.draftMessage(for: chat)
            }
        }
        .onChange(of: chatViewModel.sortedMessages.count) { _, newCount in
            if newCount == 1 {
                withAnimation {
                    isBottomContainerExpanded = false
                }
            }
        }
        .onChange(of: chat.lastMessage?.body) {
            guard let lastMessage = chat.lastMessage, !lastMessage.own else { return }
            updateReasoningTiming(for: lastMessage, isStreamingActive: logicHandler.isStreaming)
        }
        .onExitCommand {
            if editSystemMessage {
                cancelSystemMessageEdit()
            }
        }
    }

    private var chatMessagesView: some View {
        ChatMessagesView(
            chat: chat,
            chatViewModel: chatViewModel,
            inputBuffer: inputBuffer,
            editSystemMessage: $editSystemMessage,
            isStreaming: $logicHandler.isStreaming,
            currentError: $logicHandler.currentError,
            userIsScrolling: $logicHandler.userIsScrolling,
            searchText: $searchText,
            reasoningDurations: reasoningDurations,
            activeReasoningMessageID: activeReasoningMessageID
        )
    }

    private var chatInputView: some View {
        ChatInputView(
            chat: chat,
            inputBuffer: inputBuffer,
            editSystemMessage: $editSystemMessage,
            attachedImages: $attachedImages,
            attachedFiles: $attachedFiles,
            attachedAudio: $attachedAudio,
            isBottomContainerExpanded: $isBottomContainerExpanded,
            isInferenceInProgress: isInferenceInProgress,
            imageUploadsAllowed: imageUploadsAllowed,
            pdfUploadsAllowed: pdfUploadsAllowed,
            imageGenerationSupported: imageGenerationSupported,
            audioInputAllowed: audioInputAllowed,
            onSendMessage: handleSendMessage,
            onAddImage: handleAddImage,
            onAddFile: handleAddFile,
            onStopInference: handleStopInference,
            onCancelSystemMessageEdit: cancelSystemMessageEdit,
            onTextSettled: scheduleDraftSave
        )
    }

    private func handleSendMessage() {
        lastRequestStartTime = Date()
        logicHandler.sendMessage(
            messageText: inputBuffer.text,
            attachedImages: attachedImages,
            attachedFiles: attachedFiles,
            attachedAudio: attachedAudio
        )
        inputBuffer.text = ""
        attachedImages = []
        attachedFiles = []
        attachedAudio = nil
        draftManager.clearDraft(chat: chat)
    }

    private func handleAddImage() {
        logicHandler.selectAndAddImages { newAttachments in
            withAnimation {
                attachedImages.append(contentsOf: newAttachments)
            }
        }
    }

    private func handleAddFile() {
        logicHandler.selectAndAddPDFs { newAttachments in
            withAnimation {
                attachedFiles.append(contentsOf: newAttachments)
            }
        }
    }

    private func handleStopInference() {
        logicHandler.stopInference()
        resetReasoningTimingState()
    }

    private func switchConversation(from oldChatID: NSManagedObjectID) {
        if let oldChat = try? viewContext.existingObject(with: oldChatID) as? ChatEntity,
            !oldChat.isDeleted
        {
            draftManager.persistImmediately(
                chat: oldChat,
                message: inputBuffer.text,
                images: attachedImages,
                files: attachedFiles,
                isEditingSystemMessage: editSystemMessage
            )
        }

        let draftSnapshot = draftManager.draftSnapshot(for: chat)
        let attachmentSnapshot = draftManager.loadDraftAttachments(
            imageIDs: draftSnapshot.imageIDs,
            fileIDs: draftSnapshot.fileIDs
        )
        inputBuffer.text = draftSnapshot.message
        attachedImages = attachmentSnapshot.images
        attachedFiles = attachmentSnapshot.files
        editSystemMessage = false
        isBottomContainerExpanded = chat.messagesCount == 0
        searchText = ""
        resetReasoningTimingState()
    }

    private func scheduleDraftSave() {
        draftManager.scheduleSave(
            chat: chat,
            messageProvider: { inputBuffer.text },
            imageProvider: { attachedImages },
            fileProvider: { attachedFiles },
            isEditingSystemMessage: editSystemMessage
        )
    }

    private func cancelSystemMessageEdit() {
        guard editSystemMessage else { return }
        inputBuffer.text = draftManager.draftMessage(for: chat)
        editSystemMessage = false
    }

    private func updateReasoningTiming(for message: MessageEntity, isStreamingActive: Bool) {
        let body = message.body
        guard body.contains("<think>") else { return }

        let messageID = message.objectID
        if message.reasoningDuration > 0 {
            return
        }

        if reasoningStartTimes[messageID] == nil {
            guard isStreamingActive || lastRequestStartTime != nil else { return }
            let startTime = isStreamingActive ? Date() : (lastRequestStartTime ?? Date())
            reasoningStartTimes[messageID] = startTime
            activeReasoningMessageID = messageID
            reasoningDurations[messageID] = 0
        }

        if body.contains("</think>"), let startTime = reasoningStartTimes[messageID] {
            let duration = max(0, Date().timeIntervalSince(startTime))
            reasoningDurations[messageID] = duration
            persistReasoningDuration(duration, for: message)
            activeReasoningMessageID = nil
            reasoningStartTimes.removeValue(forKey: messageID)
        }
    }

    private func updateLiveReasoningDurationIfNeeded() {
        guard let messageID = activeReasoningMessageID,
            let startTime = reasoningStartTimes[messageID]
        else { return }
        reasoningDurations[messageID] = max(0, Date().timeIntervalSince(startTime))
    }

    private func finalizeReasoningTimingIfNeeded(for message: MessageEntity) {
        let messageID = message.objectID
        guard message.reasoningDuration == 0 else { return }
        guard let startTime = reasoningStartTimes[messageID] else { return }
        let duration = max(0, Date().timeIntervalSince(startTime))
        reasoningDurations[messageID] = duration
        persistReasoningDuration(duration, for: message)
        activeReasoningMessageID = nil
        reasoningStartTimes.removeValue(forKey: messageID)
    }

    private func persistReasoningDuration(_ duration: TimeInterval, for message: MessageEntity) {
        guard duration > 0 else { return }
        message.reasoningDuration = duration
        viewContext.saveWithRetry(attempts: 1)
    }

    private func resetReasoningTimingState() {
        lastRequestStartTime = nil
        for messageID in reasoningStartTimes.keys {
            reasoningDurations.removeValue(forKey: messageID)
        }
        reasoningStartTimes.removeAll()
        activeReasoningMessageID = nil
    }
}

private struct AttachmentDraftSignature: Equatable {
    let imageIDs: [UUID]
    let fileIDs: [UUID]
    let imageReadyStates: [Bool]
    let fileReadyStates: [Bool]
}

struct SearchNavigationView: View {
    @ObservedObject var chatViewModel: ChatViewModel

    var body: some View {
        HStack {
            if let currentIndex = chatViewModel.currentSearchIndex {
                Text("\(currentIndex + 1) of \(chatViewModel.searchOccurrences.count)")
                    .font(.system(size: 12))
            }

            Button(action: {
                chatViewModel.goToPreviousOccurrence()
            }) {
                Image(systemName: "chevron.up")
            }
            .disabled(chatViewModel.searchOccurrences.isEmpty)

            Button(action: {
                chatViewModel.goToNextOccurrence()
            }) {
                Image(systemName: "chevron.down")
            }
            .disabled(chatViewModel.searchOccurrences.isEmpty)
        }
    }
}
