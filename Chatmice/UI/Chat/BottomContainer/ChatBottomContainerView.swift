//
//  ChatBottomContainerView.swift
//  Chatmice
//
//  Created by Renat on 19.01.2025.
//
import SwiftUI

struct ChatBottomContainerView: View {
    @ObservedObject var chat: ChatEntity
    @Bindable var inputBuffer: ChatInputBuffer
    @Binding var attachedImages: [ImageAttachment]
    @Binding var attachedFiles: [DocumentAttachment]
    @Binding var attachedAudio: DocumentAttachment?
    let isInferenceInProgress: Bool
    var imageUploadsAllowed: Bool
    var pdfUploadsAllowed: Bool
    var imageGenerationSupported: Bool
    var audioInputAllowed: Bool
    var onSendMessage: () -> Void
    var onAddImage: () -> Void
    var onAddFile: () -> Void
    var onStopInference: () -> Void
    var onTextSettled: () -> Void

    init(
        chat: ChatEntity,
        inputBuffer: ChatInputBuffer,
        attachedImages: Binding<[ImageAttachment]> = .constant([]),
        attachedFiles: Binding<[DocumentAttachment]> = .constant([]),
        attachedAudio: Binding<DocumentAttachment?> = .constant(nil),
        isInferenceInProgress: Bool = false,
        imageUploadsAllowed: Bool = false,
        pdfUploadsAllowed: Bool = false,
        imageGenerationSupported: Bool = false,
        audioInputAllowed: Bool = false,
        onSendMessage: @escaping () -> Void,
        onAddImage: @escaping () -> Void = {},
        onAddFile: @escaping () -> Void = {},
        onStopInference: @escaping () -> Void = {},
        onTextSettled: @escaping () -> Void = {},
    ) {
        self.chat = chat
        self.inputBuffer = inputBuffer
        self._attachedImages = attachedImages
        self._attachedFiles = attachedFiles
        self._attachedAudio = attachedAudio
        self.isInferenceInProgress = isInferenceInProgress
        self.imageUploadsAllowed = imageUploadsAllowed
        self.pdfUploadsAllowed = pdfUploadsAllowed
        self.imageGenerationSupported = imageGenerationSupported
        self.audioInputAllowed = audioInputAllowed
        self.onSendMessage = onSendMessage
        self.onAddImage = onAddImage
        self.onAddFile = onAddFile
        self.onStopInference = onStopInference
        self.onTextSettled = onTextSettled
    }
    private var hasModelSelected: Bool {
        !chat.gptModel.isEmpty && chat.apiService != nil
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {

                if !hasModelSelected {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(Color.orange)
                            .font(.system(size: 13))

                        Text("Please select an AI Model from the top bar to start chatting.")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.secondary)

                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                }

                HStack {
                    MessageInputView(
                        chat: chat,
                        text: $inputBuffer.text,
                        attachedImages: $attachedImages,
                        attachedFiles: $attachedFiles,
                        attachedAudio: $attachedAudio,
                        isInferenceInProgress: isInferenceInProgress,
                        imageUploadsAllowed: imageUploadsAllowed,
                        pdfUploadsAllowed: pdfUploadsAllowed,
                        imageGenerationSupported: imageGenerationSupported,
                        audioInputAllowed: audioInputAllowed,
                        onEnter: onSendMessage,
                        onAddImage: onAddImage,
                        onAddFile: onAddFile,
                        onStopInference: onStopInference,
                        onTextSettled: onTextSettled
                    )
                    .disabled(!hasModelSelected)
                    .opacity(hasModelSelected ? 1.0 : 0.6)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

        }

    }
}
