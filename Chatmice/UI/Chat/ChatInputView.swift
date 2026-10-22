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
    @Binding var attachedImages: [ImageAttachment]
    @Binding var attachedFiles: [DocumentAttachment]
    @Binding var attachedAudio: DocumentAttachment?
    let isInferenceInProgress: Bool
    
    let imageUploadsAllowed: Bool
    let pdfUploadsAllowed: Bool
    let imageGenerationSupported: Bool
    let audioInputAllowed: Bool
    let onSendMessage: () -> Void
    let onAddImage: () -> Void
    let onAddFile: () -> Void
    let onStopInference: () -> Void
    let onTextSettled: () -> Void
    
    
    var body: some View {
        ChatBottomContainerView(
            chat: chat,
            inputBuffer: inputBuffer,
            attachedImages: $attachedImages,
            attachedFiles: $attachedFiles,
            attachedAudio: $attachedAudio,
            isInferenceInProgress: isInferenceInProgress,
            imageUploadsAllowed: imageUploadsAllowed,
            pdfUploadsAllowed: pdfUploadsAllowed,
            imageGenerationSupported: imageGenerationSupported,
            audioInputAllowed: audioInputAllowed,
            onSendMessage: onSendMessage,
            onAddImage: onAddImage,
            onAddFile: onAddFile,
            onStopInference: onStopInference,
            onTextSettled: onTextSettled
        )
    }
}

#Preview {
    ChatInputView(
        chat: ChatEntity(),
        inputBuffer: ChatInputBuffer(text: "Test message"),
        attachedImages: .constant([]),
        attachedFiles: .constant([]),
        attachedAudio: .constant(nil),
        isInferenceInProgress: false,
        imageUploadsAllowed: true,
        pdfUploadsAllowed: true,
        imageGenerationSupported: true,
        audioInputAllowed: true,
        onSendMessage: {},
        onAddImage: {},
        onAddFile: {},
        onStopInference: {},
        onTextSettled: {}
    )
}
