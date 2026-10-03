//
//  ChatInputView.swift
//  Chatmice
//
//  Created by Renat Notfullin on 20.01.2025.
//

import SwiftUI
import UniformTypeIdentifiers

struct ChatInputView: View {
    @ObservedObject var chat: ChatEntity
    @Bindable var inputBuffer: ChatInputBuffer
    @Binding var editSystemMessage: Bool
    @Binding var attachedImages: [ImageAttachment]
    @Binding var attachedFiles: [DocumentAttachment]
    @Binding var isBottomContainerExpanded: Bool
    let isInferenceInProgress: Bool
    
    let imageUploadsAllowed: Bool
    let pdfUploadsAllowed: Bool
    let imageGenerationSupported: Bool
    let onSendMessage: () -> Void
    let onAddImage: () -> Void
    let onAddFile: () -> Void
    let onStopInference: () -> Void
    let onCancelSystemMessageEdit: () -> Void
    let onTextSettled: () -> Void
    
    @StateObject private var store = ChatStore(persistenceController: PersistenceController.shared)
    
    var body: some View {
        ChatBottomContainerView(
            chat: chat,
            inputBuffer: inputBuffer,
            isExpanded: $isBottomContainerExpanded,
            attachedImages: $attachedImages,
            attachedFiles: $attachedFiles,
            isInferenceInProgress: isInferenceInProgress,
            isEditingSystemMessage: editSystemMessage,
            imageUploadsAllowed: imageUploadsAllowed,
            pdfUploadsAllowed: pdfUploadsAllowed,
            imageGenerationSupported: imageGenerationSupported,
            onSendMessage: {
                if editSystemMessage {
                    chat.systemMessage = inputBuffer.text
                    inputBuffer.text = ""
                    editSystemMessage = false
                    store.saveInCoreData()
                }
                else if !isInferenceInProgress,
                        !inputBuffer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    onSendMessage()
                }
            },
            onAddImage: onAddImage,
            onAddFile: onAddFile,
            onStopInference: onStopInference,
            onCancelEdit: onCancelSystemMessageEdit,
            onTextSettled: onTextSettled
        )
    }
}

#Preview {
    ChatInputView(
        chat: ChatEntity(),
        inputBuffer: ChatInputBuffer(text: "Test message"),
        editSystemMessage: .constant(false),
        attachedImages: .constant([]),
        attachedFiles: .constant([]),
        isBottomContainerExpanded: .constant(false),
        isInferenceInProgress: false,
        imageUploadsAllowed: true,
        pdfUploadsAllowed: true,
        imageGenerationSupported: true,
        onSendMessage: {},
        onAddImage: {},
        onAddFile: {},
        onStopInference: {},
        onCancelSystemMessageEdit: {},
        onTextSettled: {}
    )
}
