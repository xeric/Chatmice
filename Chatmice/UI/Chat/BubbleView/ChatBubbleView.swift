//
//  ChatBubbleView.swift
//  Chatmice
//
//  Created by Renat Notfullin on 18.03.2023.
//

import AppKit
import CoreData
import Foundation
import SwiftUI

enum MessageElements {
    case text(String)
    case table(header: [String], data: [[String]])
    case code(code: String, lang: String, indent: Int)
    case formula(String)
    case thinking(String, isExpanded: Bool)
    case toolActivity(ToolActivityRecord)
    case image(NSImage, UUID)
    case file(FileAttachmentInfo)
}

struct FileAttachmentInfo: Identifiable {
    let id: UUID
    let filename: String
    let mimeType: String?
}

struct ChatBubbleContent: Equatable {
    let message: String
    let own: Bool
    let waitingForResponse: Bool?
    let errorMessage: ErrorMessage?
    let systemMessage: Bool
    let isStreaming: Bool
    let isLatestMessage: Bool
    let reasoningDuration: TimeInterval?
    let isActiveReasoning: Bool

    static func == (lhs: ChatBubbleContent, rhs: ChatBubbleContent) -> Bool {
        return lhs.message == rhs.message && lhs.own == rhs.own && lhs.waitingForResponse == rhs.waitingForResponse
            && lhs.systemMessage == rhs.systemMessage && lhs.isStreaming == rhs.isStreaming
            && lhs.isLatestMessage == rhs.isLatestMessage && lhs.reasoningDuration == rhs.reasoningDuration
            && lhs.isActiveReasoning == rhs.isActiveReasoning && lhs.errorMessage?.timestamp == rhs.errorMessage?.timestamp
    }
}

struct ChatBubbleView: View, Equatable {
    let content: ChatBubbleContent
    var message: MessageEntity?
    var color: String?
    var onEdit: (() -> Void)?
    @Binding var searchText: String
    var currentSearchOccurrence: SearchOccurrence?
    var activitySnapshot: ChatActivitySnapshot? = nil

    @Environment(\.colorScheme) var colorScheme
    @Environment(\.managedObjectContext) private var viewContext
    private let outgoingBubbleColorLight = Color(red: 0.92, green: 0.92, blue: 0.92)
    private let outgoingBubbleColorDark = Color(red: 0.3, green: 0.3, blue: 0.3)
    private let incomingBubbleColorLight = Color(.white).opacity(0)
    private let incomingBubbleColorDark = Color(.white).opacity(0)
    private let incomingLabelColor = NSColor.labelColor
    @State private var isHovered = false
    @State private var isToolbarHovered = false
    @State private var showingDeleteConfirmation = false
    @State private var isCopied = false
    @AppStorage("chatFontSize") private var chatFontSize: Double = 15.0

    private var isActiveAssistantTurn: Bool {
        guard !content.own, content.isLatestMessage else { return false }
        return content.isStreaming || (content.waitingForResponse ?? false) || activitySnapshot?.phase.isActive == true
    }

    private var effectiveFontSize: Double {
        chatFontSize
    }

    static func == (lhs: ChatBubbleView, rhs: ChatBubbleView) -> Bool {
        lhs.content == rhs.content && lhs.currentSearchOccurrence == rhs.currentSearchOccurrence
            && lhs.activitySnapshot == rhs.activitySnapshot
    }

    var body: some View {
        let prefetchedElements = prefetchedElementsIfNeeded(from: content.message)
        let attachments = prefetchedElements.map(extractAttachments) ?? []
        let hasBodyContent = prefetchedElements.map(hasRenderableBodyContent) ?? true

        VStack {
            HStack {
                if content.own {
                    Color.clear
                        .frame(width: 80)
                    Spacer()
                }
                VStack(alignment: content.own ? .trailing : .leading, spacing: 6) {
                    if content.own,
                        !(content.waitingForResponse ?? false),
                        content.errorMessage == nil,
                        !attachments.isEmpty
                    {
                        attachmentRow(attachments: attachments)
                    }

                    if hasBodyContent || (content.waitingForResponse ?? false) || content.errorMessage != nil {
                        bubbleContent(prefetchedElements: prefetchedElements)
                            .frame(
                                maxWidth: content.own ? nil : ChatTypography.assistantContentMaxWidth,
                                alignment: content.own ? .trailing : .leading
                            )
                    }
                }

                if !content.own {
                    Spacer()
                }
            }

            if content.errorMessage == nil && !(content.waitingForResponse ?? false) && !isActiveAssistantTurn {
                HStack {
                    if content.own {
                        Spacer()
                        toolbarContent
                            .padding(.trailing, 6)
                            .onHover { hovering in
                                isToolbarHovered = hovering
                            }
                    }
                    else {
                        toolbarContent
                            .padding(.leading, 12)
                            .onHover { hovering in
                                isToolbarHovered = hovering
                            }
                        Spacer()
                    }
                }
                .frame(height: 24)
                .contentShape(Rectangle())
                .transition(.opacity)
                .opacity(isHovered || isToolbarHovered ? 1 : 0)
                .animation(.easeInOut(duration: 0.15), value: isHovered || isToolbarHovered)
            }
            else {
                Color.clear.frame(height: 12)
            }
        }
        .padding(.vertical, ChatTypography.messageVerticalPadding)
        .background(
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
        )
        .onHover { isHovered in
            self.isHovered = isHovered
        }
        .alert(isPresented: $showingDeleteConfirmation) {
            Alert(
                title: Text("Delete Message"),
                message: Text("Are you sure you want to delete this message?"),
                primaryButton: .destructive(Text("Delete")) {
                    deleteMessage()
                },
                secondaryButton: .cancel()
            )
        }
    }

    @ViewBuilder
    private func bubbleContent(prefetchedElements: [MessageElements]?) -> some View {
        Group {
            if content.waitingForResponse ?? false {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Waiting for model")
                            .font(.system(size: 13, weight: .semibold))
                        Text("The model is processing your request")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            else if let errorMessage = content.errorMessage {
                ErrorBubbleView(
                    error: errorMessage,
                    onRetry: {
                        NotificationCenter.default.post(
                            name: NSNotification.Name("RetryMessage"),
                            object: nil,
                            userInfo: ["chatId": message?.chat?.id as Any]
                        )
                    },
                    onIgnore: {
                        NotificationCenter.default.post(
                            name: NSNotification.Name("IgnoreError"),
                            object: nil
                        )
                    }
                )
            }
            else {
                VStack(alignment: .leading, spacing: 8) {
                    MessageContentView(
                        message: message,
                        content: content.message,
                        isStreaming: content.isStreaming,
                        own: content.own,
                        effectiveFontSize: effectiveFontSize,
                        colorScheme: colorScheme,
                        inlineAttachments: !content.own,
                        reasoningDuration: content.reasoningDuration,
                        isActiveReasoning: content.isActiveReasoning,
                        prefetchedElements: prefetchedElements,
                        searchText: $searchText,
                        currentSearchOccurrence: currentSearchOccurrence
                    )

                    if let activitySnapshot, activitySnapshot.phase.isActive, !content.own, content.isLatestMessage {
                        AssistantTurnActivityView(snapshot: activitySnapshot)
                    }

                    if isActiveAssistantTurn {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 5, height: 5)
                                .modifier(PulsatingCircle())
                            Text("More response is coming")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.top, 1)
                        .accessibilityLabel("Assistant response is still in progress")
                    }
                }
            }
        }
        .foregroundColor(Color(content.own ? incomingLabelColor : incomingLabelColor))
        .multilineTextAlignment(.leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            content.systemMessage
                ? (color != nil ? (Color(hex: color!) ?? Color(NSColor.systemGray)) : Color(NSColor.systemGray))
                    .opacity(0.6)
                : colorScheme == .dark
                    ? (content.own ? outgoingBubbleColorDark : incomingBubbleColorDark)
                    : (content.own ? outgoingBubbleColorLight : incomingBubbleColorLight)
        )
        .cornerRadius(16)
    }

    private func prefetchedElementsIfNeeded(from message: String) -> [MessageElements]? {
        guard content.own else { return nil }
        guard message.contains("<image-uuid>") || message.contains("<file-uuid>") else { return nil }
        let parser = MessageParser(colorScheme: colorScheme)
        return parser.parseMessageFromString(input: message)
    }

    private func extractAttachments(from elements: [MessageElements]) -> [MessageElements] {
        elements.compactMap { element in
            switch element {
            case .image, .file:
                return element
            default:
                return nil
            }
        }
    }

    private func hasRenderableBodyContent(_ elements: [MessageElements]) -> Bool {
        elements.contains { element in
            switch element {
            case .image, .file:
                return false
            case .text(let text):
                return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            default:
                return true
            }
        }
    }

    @ViewBuilder
    private func attachmentRow(attachments: [MessageElements]) -> some View {
        let tileSize: CGFloat = 160
        let spacing: CGFloat = 8
        let squareAttachments = attachments.filter { !isAudioAttachment($0) }
        let audioAttachments = attachments.filter(isAudioAttachment)
        let previewRequests = attachmentPreviewRequests(from: squareAttachments)
        let previewIndexById = previewRequests.enumerated().reduce(into: [UUID: Int]()) { result, entry in
            result[entry.element.id] = entry.offset
        }

        VStack(alignment: .trailing, spacing: spacing) {
            if !squareAttachments.isEmpty {
                TrailingAttachmentFlowLayout(
                    itemSize: CGSize(width: tileSize, height: tileSize),
                    spacing: spacing
                ) {
                    ForEach(squareAttachments.indices, id: \.self) { index in
                        attachmentTileView(
                            attachment: squareAttachments[index],
                            tileSize: tileSize,
                            previewIndexById: previewIndexById,
                            previewRequests: previewRequests
                        )
                    }
                }
            }

            ForEach(audioAttachments.indices, id: \.self) { index in
                if case .file(let fileInfo) = audioAttachments[index] {
                    AudioAttachmentPlayerView(id: fileInfo.id, filename: fileInfo.filename)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func isAudioAttachment(_ element: MessageElements) -> Bool {
        if case .file(let fileInfo) = element {
            return fileInfo.mimeType?.hasPrefix("audio/") == true
        }
        return false
    }

    @ViewBuilder
    private func attachmentTileView(
        attachment: MessageElements,
        tileSize: CGFloat,
        previewIndexById: [UUID: Int],
        previewRequests: [QuickLookPreviewer.PreviewItemRequest]
    ) -> some View {
        switch attachment {
        case .image(let image, let id):
            ImageAttachmentTileView(
                image: image,
                size: tileSize,
                onPreview: {
                    if let index = previewIndexById[id] {
                        QuickLookPreviewer.shared.preview(requests: previewRequests, selectedIndex: index)
                    }
                }
            )
        case .file(let fileInfo):
            if fileInfo.mimeType?.hasPrefix("audio/") == true {
                AudioAttachmentPlayerView(id: fileInfo.id, filename: fileInfo.filename, width: tileSize)
            } else {
                PDFAttachmentTileView(
                    fileInfo: fileInfo,
                    size: tileSize,
                    onPreview: {
                        if let index = previewIndexById[fileInfo.id] {
                            QuickLookPreviewer.shared.preview(requests: previewRequests, selectedIndex: index)
                        }
                    }
                )
            }
        default:
            EmptyView()
        }
    }

    private func attachmentPreviewRequests(from attachments: [MessageElements]) -> [QuickLookPreviewer
        .PreviewItemRequest]
    {
        attachments.map(makePreviewRequest)
    }

    private func makePreviewRequest(for element: MessageElements) -> QuickLookPreviewer.PreviewItemRequest {
        switch element {
        case .image(_, let id):
            if let cached = PreviewFileHelper.cachedPreviewURL(for: id) {
                return QuickLookPreviewer.PreviewItemRequest(
                    id: id,
                    title: cached.lastPathComponent,
                    url: cached
                )
            }
            return QuickLookPreviewer.PreviewItemRequest(id: id, title: "Image.jpg") { completion in
                PersistenceController.shared.container.performBackgroundTask { context in
                    let fetchRequest: NSFetchRequest<ImageEntity> = ImageEntity.fetchRequest()
                    fetchRequest.predicate = NSPredicate(format: "id == %@", id as CVarArg)
                    fetchRequest.fetchLimit = 1

                    guard let imageEntity = try? context.fetch(fetchRequest).first,
                        let imageData = imageEntity.image
                    else {
                        completion(nil)
                        return
                    }

                    let rawExtension =
                        (imageEntity.imageFormat?.isEmpty == false)
                        ? imageEntity.imageFormat!.lowercased()
                        : "jpg"
                    let fileExtension = (rawExtension == "jpeg") ? "jpg" : rawExtension
                    let filename = "Image.\(fileExtension)"
                    let url = PreviewFileHelper.previewURL(
                        for: id,
                        data: imageData,
                        filename: filename,
                        defaultExtension: fileExtension
                    )
                    completion(url)
                }
            }
        case .file(let fileInfo):
            let displayName = fileInfo.filename.isEmpty ? "Document.pdf" : fileInfo.filename
            if let cached = PreviewFileHelper.cachedPreviewURL(for: fileInfo.id) {
                return QuickLookPreviewer.PreviewItemRequest(
                    id: fileInfo.id,
                    title: displayName,
                    url: cached
                )
            }
            return QuickLookPreviewer.PreviewItemRequest(id: fileInfo.id, title: displayName) { completion in
                PersistenceController.shared.container.performBackgroundTask { context in
                    let fetchRequest: NSFetchRequest<DocumentEntity> = DocumentEntity.fetchRequest()
                    fetchRequest.predicate = NSPredicate(format: "id == %@", fileInfo.id as CVarArg)
                    fetchRequest.fetchLimit = 1

                    guard let documentEntity = try? context.fetch(fetchRequest).first,
                        let fileData = documentEntity.fileData
                    else {
                        completion(nil)
                        return
                    }

                    let suggestedName = fileInfo.filename.isEmpty ? "Document.pdf" : fileInfo.filename
                    let baseName = URL(fileURLWithPath: suggestedName).deletingPathExtension().lastPathComponent
                    let name = "\(baseName).pdf"
                    let url = PreviewFileHelper.previewURL(
                        for: fileInfo.id,
                        data: fileData,
                        filename: name,
                        defaultExtension: "pdf"
                    )
                    completion(url)
                }
            }
        default:
            return QuickLookPreviewer.PreviewItemRequest(id: UUID(), title: nil, url: nil)
        }
    }

    private func copyMessageToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        markCopied()
    }

    private func copyFirstImageToClipboard() {
        let imageIDs = AttachmentParser.extractImageUUIDs(from: content.message)
        guard let firstID = imageIDs.first,
            let image = loadImageFromCoreData(id: firstID)
        else {
            return
        }

        AttachmentActionHelper.copyImage(image)
        markCopied()
    }

    private func loadImageFromCoreData(id: UUID) -> NSImage? {
        let fetchRequest: NSFetchRequest<ImageEntity> = ImageEntity.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        fetchRequest.fetchLimit = 1

        guard let imageEntity = try? viewContext.fetch(fetchRequest).first,
            let imageData = imageEntity.image
        else {
            return nil
        }

        return NSImage(data: imageData)
    }

    private func markCopied() {
        withAnimation {
            isCopied = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            withAnimation {
                isCopied = false
            }
        }
    }

    private func deleteMessage() {
        guard let messageEntity = message else { return }
        viewContext.delete(messageEntity)
        do {
            try viewContext.save()
        }
        catch {
            print("Error deleting message: \(error)")
        }
    }

    private var toolbarContent: some View {
        HStack(spacing: 12) {
            let isImageOnlyMessage =
                AttachmentParser.stripAttachments(from: content.message).isEmpty
                && !AttachmentParser.extractImageUUIDs(from: content.message).isEmpty
                && AttachmentParser.extractFileUUIDs(from: content.message).isEmpty
            let copyIcon = isImageOnlyMessage ? "photo" : "doc.on.doc"
            if content.systemMessage {
                ToolbarButton(
                    icon: "pencil",
                    text: "Edit",
                    action: {
                        onEdit?()
                    }
                )
            }

            if content.isLatestMessage && !content.systemMessage {
                ToolbarButton(
                    icon: "arrow.clockwise",
                    text: "Retry",
                    action: {
                        NotificationCenter.default.post(
                            name: NSNotification.Name("RetryMessage"),
                            object: nil,
                            userInfo: ["chatId": message?.chat?.id as Any]
                        )
                    }
                )
            }

            ToolbarButton(
                icon: isCopied ? "checkmark" : copyIcon,
                text: "Copy",
                action: {
                    if isImageOnlyMessage {
                        copyFirstImageToClipboard()
                    }
                    else {
                        copyMessageToClipboard(content.message)
                    }
                }
            )

            if !content.systemMessage {
                ToolbarButton(
                    icon: "trash",
                    text: "",  // No text for delete button
                    action: {
                        showingDeleteConfirmation = true
                    }
                )
            }

            if let timestamp = message?.timestamp {
                Text(
                    timestamp,
                    format: .dateTime
                        .year().month(.twoDigits).day(.twoDigits)
                        .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)
                )
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .help(timestamp.formatted(date: .long, time: .standard))
                    .accessibilityLabel("Sent at \(timestamp.formatted(date: .long, time: .standard))")
            }
        }
    }
}

private struct TrailingAttachmentFlowLayout: Layout {
    var itemSize: CGSize
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }

        let availableWidth = proposal.width ?? idealWidth(for: subviews.count)
        let itemsPerRow = itemsPerRow(for: availableWidth, fallbackCount: subviews.count)
        let rowCount = Int(ceil(Double(subviews.count) / Double(itemsPerRow)))
        let height = CGFloat(rowCount) * itemSize.height + CGFloat(max(0, rowCount - 1)) * spacing

        if let proposedWidth = proposal.width {
            return CGSize(width: proposedWidth, height: height)
        }

        let maxItemsInRow = min(itemsPerRow, subviews.count)
        let width = CGFloat(maxItemsInRow) * itemSize.width + CGFloat(max(0, maxItemsInRow - 1)) * spacing
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }

        let availableWidth = bounds.width
        let itemsPerRow = itemsPerRow(for: availableWidth, fallbackCount: subviews.count)
        var rowStart = 0
        var y = bounds.minY

        while rowStart < subviews.count {
            let rowEnd = min(rowStart + itemsPerRow, subviews.count)
            let rowCount = rowEnd - rowStart
            let rowWidth = CGFloat(rowCount) * itemSize.width + CGFloat(max(0, rowCount - 1)) * spacing
            var x = bounds.maxX - rowWidth

            for index in rowStart..<rowEnd {
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(width: itemSize.width, height: itemSize.height)
                )
                x += itemSize.width + spacing
            }

            y += itemSize.height + spacing
            rowStart = rowEnd
        }
    }

    private func idealWidth(for count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        let totalSpacing = CGFloat(max(0, count - 1)) * spacing
        return CGFloat(count) * itemSize.width + totalSpacing
    }

    private func itemsPerRow(for availableWidth: CGFloat, fallbackCount: Int) -> Int {
        guard availableWidth.isFinite, availableWidth > 0, itemSize.width > 0 else {
            return max(1, fallbackCount)
        }
        let raw = (availableWidth + spacing) / (itemSize.width + spacing)
        guard raw.isFinite, raw > 0 else { return max(1, fallbackCount) }
        return max(1, Int(raw))
    }
}

struct PulsatingCircle: ViewModifier {
    @State private var isAnimating = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isAnimating ? 1.5 : 1.0)
            .opacity(isAnimating ? 0.5 : 1.0)
            .animation(
                Animation
                    .easeInOut(duration: 0.8)
                    .repeatForever(autoreverses: true),
                value: isAnimating
            )
            .onAppear {
                isAnimating = true
            }
    }
}
