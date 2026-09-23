//
//  MessageContentView.swift
//  macai
//
//  Created by Renat on 03.04.2025.
//

import AppKit
import AttributedText
import CoreData
import SwiftUI

struct MessageContentView: View {
    var message: MessageEntity?
    let content: String
    let isStreaming: Bool
    let own: Bool
    let effectiveFontSize: Double
    let colorScheme: ColorScheme
    let inlineAttachments: Bool
    let reasoningDuration: TimeInterval?
    let isActiveReasoning: Bool
    let prefetchedElements: [MessageElements]?
    @Binding var searchText: String
    var currentSearchOccurrence: SearchOccurrence?

    @State private var showFullMessage = false
    @State private var isParsingFullMessage = false
    @State private var expandedReasoningElements: Set<String> = []
    @State private var expandedToolElements: Set<String> = []

    private let largeMessageSymbolsThreshold = AppConstants.largeMessageSymbolsThreshold

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Check if message contains image data or JSON with image_url before applying truncation
            if content.count > largeMessageSymbolsThreshold && !showFullMessage && !containsImageData(content) {
                renderPartialContent()
            }
            else {
                renderFullContent()
            }
        }
    }

    private func containsImageData(_ message: String) -> Bool {
        if message.contains("<image-uuid>") || message.contains("<file-uuid>") || message.contains(ToolActivityRecord.openingTag) {
            return true
        }
        return false
    }

    @ViewBuilder
    private func renderPartialContent() -> some View {
        let truncatedMessage = String(content.prefix(largeMessageSymbolsThreshold))
        let parser = MessageParser(colorScheme: colorScheme)
        let parsedElements = content.count <= largeMessageSymbolsThreshold
            ? (prefetchedElements ?? parser.parseMessageFromString(input: truncatedMessage))
            : parser.parseMessageFromString(input: truncatedMessage)

        let elementsToRender = filterInlineAttachments(parsedElements)
        let attachmentElements = extractAttachmentElements(from: elementsToRender)
        let attachmentIndexMap = buildAttachmentIndexMap(for: elementsToRender)

        VStack(alignment: .leading, spacing: 8) {
            ForEach(elementsToRender.indices, id: \.self) {
                index in
                renderElement(
                    elementsToRender[index],
                    elementIndex: index,
                    attachmentElements: attachmentElements,
                    attachmentIndexMap: attachmentIndexMap
                )
            }

            HStack(spacing: 8) {
                Button(action: {
                    isParsingFullMessage = true
                    // Parse the full message in background: very long messages may take long time to parse (and even cause app crash)
                    DispatchQueue.global(qos: .userInitiated).async {
                        let parser = MessageParser(colorScheme: colorScheme)
                        _ = parser.parseMessageFromString(input: content)

                        DispatchQueue.main.async {
                            showFullMessage = true
                            isParsingFullMessage = false
                        }
                    }
                }) {
                    Text("Show Full Message")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 12)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(16)
                }
                .buttonStyle(PlainButtonStyle())

                if isParsingFullMessage {
                    ProgressView()
                        .scaleEffect(0.4)
                        .frame(width: 12, height: 12)
                }
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func renderFullContent() -> some View {
        let parser = MessageParser(colorScheme: colorScheme)
        let parsedElements = prefetchedElements ?? parser.parseMessageFromString(input: content)
        let elementsToRender = filterInlineAttachments(parsedElements)
        let attachmentElements = extractAttachmentElements(from: elementsToRender)
        let attachmentIndexMap = buildAttachmentIndexMap(for: elementsToRender)

        ForEach(elementsToRender.indices, id: \.self) {
            index in
            renderElement(
                elementsToRender[index],
                elementIndex: index,
                attachmentElements: attachmentElements,
                attachmentIndexMap: attachmentIndexMap
            )
                .id(generateElementID(elementIndex: index))
        }
    }
    
    private func generateElementID(elementIndex: Int) -> String {
        guard let messageID = message?.objectID else {
            return "element_\(elementIndex)"
        }
        let messageIDString = messageID.uriRepresentation().absoluteString
        return "\(messageIDString)_element_\(elementIndex)"
    }

    private func reasoningElementKey(for elementIndex: Int) -> String {
        guard let messageID = message?.objectID else {
            return "thinking_\(elementIndex)"
        }
        let messageIDString = messageID.uriRepresentation().absoluteString
        return "\(messageIDString)_thinking_\(elementIndex)"
    }

    private func reasoningExpansionBinding(for elementIndex: Int) -> Binding<Bool> {
        let key = reasoningElementKey(for: elementIndex)
        return Binding(
            get: { expandedReasoningElements.contains(key) },
            set: { isExpanded in
                if isExpanded {
                    expandedReasoningElements.insert(key)
                } else {
                    expandedReasoningElements.remove(key)
                }
            }
        )
    }
    private func toolElementKey(for elementIndex: Int) -> String {
        guard let messageID = message?.objectID else {
            return "tool_\(elementIndex)"
        }
        return "\(messageID.uriRepresentation().absoluteString)_tool_\(elementIndex)"
    }

    private func toolExpansionBinding(for elementIndex: Int) -> Binding<Bool> {
        let key = toolElementKey(for: elementIndex)
        return Binding(
            get: { expandedToolElements.contains(key) },
            set: { isExpanded in
                if isExpanded {
                    expandedToolElements.insert(key)
                } else {
                    expandedToolElements.remove(key)
                }
            }
        )
    }


    @ViewBuilder
    private func renderElement(
        _ element: MessageElements,
        elementIndex: Int,
        attachmentElements: [MessageElements],
        attachmentIndexMap: [Int?]
    ) -> some View {
        switch element {
        case .thinking(let content, _):
            ThinkingProcessView(
                content: content,
                duration: reasoningDuration,
                isActive: isActiveReasoning,
                isExpanded: reasoningExpansionBinding(for: elementIndex)
            )
                .padding(.vertical, 4)

        case .toolActivity(let activity):
            ToolActivityView(
                activity: activity,
                isExpanded: toolExpansionBinding(for: elementIndex)
            )
            .padding(.vertical, 3)

        case .text(let text):
            renderText(text, elementIndex: elementIndex)

        case .table(let header, let data):
            TableView(header: header, tableData: data, searchText: $searchText, message: message, currentSearchOccurrence: currentSearchOccurrence, elementIndex: elementIndex)
                .padding(.bottom, 12)

        case .code(let code, let lang, let indent):
            renderCode(code: code, lang: lang, indent: indent, isStreaming: isStreaming, elementIndex: elementIndex)

        case .formula(let formula):
            if isStreaming {
                Text(formula).textSelection(.enabled)
            }
            else {
                AdaptiveMathView(equation: formula, fontSize: NSFont.systemFontSize + CGFloat(2))
                    .padding(.vertical, 16)
            }

        case .image(let image, let imageID):
            if inlineAttachments {
                renderImage(
                    image,
                    imageID: imageID,
                    elementIndex: elementIndex,
                    attachmentElements: attachmentElements,
                    attachmentIndexMap: attachmentIndexMap,
                    isOwn: own
                )
            }

        case .file(let fileInfo):
            if inlineAttachments {
                renderFile(
                    fileInfo,
                    elementIndex: elementIndex,
                    attachmentElements: attachmentElements,
                    attachmentIndexMap: attachmentIndexMap
                )
            }
        }
    }

    @ViewBuilder
    private func renderText(_ text: String, elementIndex: Int = 0) -> some View {
        let attributedString: NSAttributedString = {
            let options = AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
            let initialAttributedString =
                (try? NSAttributedString(markdown: text, options: options))
                ?? NSAttributedString(string: text)

            let mutableAttributedString = NSMutableAttributedString(
                attributedString: initialAttributedString
            )
            let fullRange = NSRange(location: 0, length: mutableAttributedString.length)
            let systemFont = NSFont.systemFont(ofSize: effectiveFontSize)

            mutableAttributedString.addAttribute(.font, value: systemFont, range: fullRange)
            mutableAttributedString.addAttribute(
                .foregroundColor,
                value: own ? NSColor.textColor : NSColor.textColor,
                range: fullRange
            )

            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineHeightMultiple = own ? 1.14 : 1.22
            paragraphStyle.lineSpacing = own ? 0.5 : 1
            paragraphStyle.paragraphSpacing = own ? 3 : 5
            paragraphStyle.lineBreakMode = .byWordWrapping
            mutableAttributedString.addAttribute(.paragraphStyle, value: paragraphStyle, range: fullRange)

            // Handle headers
            guard let headerRegex = try? NSRegularExpression(pattern: "^(#{1,6})\\s+(.*)", options: .anchorsMatchLines) else { return mutableAttributedString }
            let headerMatches = headerRegex.matches(in: mutableAttributedString.string, options: [], range: NSRange(location: 0, length: mutableAttributedString.string.utf16.count))

            for match in headerMatches.reversed() {
                let fullMatchRange = match.range(at: 0)
                let prefixHashesRange = match.range(at: 1)
                let contentTextRange = match.range(at: 2)

                let level = prefixHashesRange.length
                let fontSize = max(effectiveFontSize + 10 - pow(CGFloat(level), 1.5), 6)
                let font = NSFont.boldSystemFont(ofSize: fontSize)

                mutableAttributedString.addAttribute(.font, value: font, range: contentTextRange)
                let headingStyle = paragraphStyle.mutableCopy() as? NSMutableParagraphStyle
                headingStyle?.paragraphSpacingBefore = level <= 2 ? 8 : 5
                headingStyle?.paragraphSpacing = 6
                if let headingStyle {
                    mutableAttributedString.addAttribute(.paragraphStyle, value: headingStyle, range: fullMatchRange)
                }
                
                let prefixToDeleteRange = NSRange(location: fullMatchRange.location, length: contentTextRange.location - fullMatchRange.location)
                mutableAttributedString.deleteCharacters(in: prefixToDeleteRange)
            }
            
            // Handle quote blocks
            guard let quoteRegex = try? NSRegularExpression(pattern: "^\\s*>\\s*(.*)", options: .anchorsMatchLines) else { return mutableAttributedString }
            let quoteMatches = quoteRegex.matches(in: mutableAttributedString.string, options: [], range: NSRange(location: 0, length: mutableAttributedString.string.utf16.count))
            
            for match in quoteMatches.reversed() {
                let fullMatchRange = match.range(at: 0)
                let contentTextRange = match.range(at: 1)
                
                let fontDescriptor = NSFont.systemFont(ofSize: effectiveFontSize).fontDescriptor
                let italicDescriptor = fontDescriptor.withSymbolicTraits(.italic)
                let italicFont = NSFont(descriptor: italicDescriptor, size: effectiveFontSize) ?? NSFont.systemFont(ofSize: effectiveFontSize)
                mutableAttributedString.addAttribute(.font, value: italicFont, range: contentTextRange)
                
                let quoteColor = colorScheme == .dark ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor
                mutableAttributedString.addAttribute(.foregroundColor, value: quoteColor, range: contentTextRange)
                
                let prefixToDeleteRange = NSRange(location: fullMatchRange.location, length: contentTextRange.location - fullMatchRange.location)
                mutableAttributedString.deleteCharacters(in: prefixToDeleteRange)
            }

            // Keep wrapped list lines aligned with their content instead of the marker.
            if let listRegex = try? NSRegularExpression(
                pattern: "^\\s*(?:[-*+] |\\d+[.)] )",
                options: .anchorsMatchLines
            ) {
                let listMatches = listRegex.matches(
                    in: mutableAttributedString.string,
                    range: NSRange(location: 0, length: mutableAttributedString.length)
                )
                let source = mutableAttributedString.string as NSString
                for match in listMatches {
                    let listStyle = paragraphStyle.mutableCopy() as? NSMutableParagraphStyle
                    listStyle?.firstLineHeadIndent = 0
                    listStyle?.headIndent = CGFloat(effectiveFontSize * 1.8)
                    if let listStyle {
                        mutableAttributedString.addAttribute(
                            .paragraphStyle,
                            value: listStyle,
                            range: source.paragraphRange(for: match.range)
                        )
                    }
                }
            }

            // Apply search highlighting if searchText is not empty
            if !searchText.isEmpty, let messageId = message?.objectID {
                let body = mutableAttributedString.string
                let originalBody = text
                var searchStartIndex = body.startIndex
                var originalSearchStartIndex = originalBody.startIndex
                
                while let range = body.range(of: searchText, options: .caseInsensitive, range: searchStartIndex..<body.endIndex),
                      let originalRange = originalBody.range(of: searchText, options: .caseInsensitive, range: originalSearchStartIndex..<originalBody.endIndex) {
                    let nsRange = NSRange(range, in: body)
                    let originalNSRange = NSRange(originalRange, in: originalBody)
                    let occurrence = SearchOccurrence(messageID: messageId, range: originalNSRange, elementIndex: elementIndex, elementType: "text")
                    let isCurrent = occurrence == self.currentSearchOccurrence
                    let color = isCurrent 
                         ? NSColor(Color(hex: AppConstants.currentHighlightColor) ?? Color.yellow) 
                         : NSColor(Color(hex: AppConstants.defaultHighlightColor) ?? Color.gray).withAlphaComponent(0.3)
                    mutableAttributedString.addAttribute(.backgroundColor, value: color, range: nsRange)
                    searchStartIndex = range.upperBound
                    originalSearchStartIndex = originalRange.upperBound
                }
            }

            return mutableAttributedString
        }()

        if text.count > AppConstants.longStringCount {
            AttributedText(attributedString)
                .textSelection(.enabled)
        } else {
            Text(.init(attributedString))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func renderCode(code: String, lang: String, indent: Int, isStreaming: Bool, elementIndex: Int) -> some View {
        CodeView(code: code, lang: lang, isStreaming: isStreaming, message: message, searchText: $searchText, currentSearchOccurrence: currentSearchOccurrence, elementIndex: elementIndex)
            .padding(.bottom, 8)
            .padding(.leading, CGFloat(indent) * 4)
            .onAppear {
                NotificationCenter.default.post(name: NSNotification.Name("CodeBlockRendered"), object: nil)
            }
    }

    @ViewBuilder
    private func renderImage(
        _ image: NSImage,
        imageID _: UUID,
        elementIndex: Int,
        attachmentElements: [MessageElements],
        attachmentIndexMap: [Int?],
        isOwn: Bool
    ) -> some View {
        let previewSize: CGFloat = isOwn ? 160 : 300
        let cornerRadius: CGFloat = 8

        let imageView = Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .cornerRadius(cornerRadius)
            .padding(.bottom, 3)
            .onTapGesture {
                if elementIndex < attachmentIndexMap.count,
                   let attachmentIndex = attachmentIndexMap[elementIndex] {
                    openAttachmentPreview(
                        attachmentElements: attachmentElements,
                        selectedAttachmentIndex: attachmentIndex
                    )
                } else {
                    QuickLookPreviewer.shared.preview(image: image, filename: "Image.jpg")
                }
            }
            .contextMenu {
                Button("Copy") {
                    AttachmentActionHelper.copyImage(image)
                }
                Button("Save") {
                    AttachmentActionHelper.saveImage(image, suggestedName: "Image.jpg")
                }
            }

        if isOwn {
            imageView
                .frame(width: previewSize, height: previewSize)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            let aspectRatio = image.size.width / image.size.height
            let displayHeight = previewSize / aspectRatio

            imageView
                .frame(maxWidth: previewSize, maxHeight: displayHeight)
        }
    }

    @ViewBuilder
    private func renderFile(
        _ fileInfo: FileAttachmentInfo,
        elementIndex: Int,
        attachmentElements: [MessageElements],
        attachmentIndexMap: [Int?]
    ) -> some View {
        let displayName = fileInfo.filename.isEmpty ? "Document.pdf" : fileInfo.filename
        HStack(spacing: 10) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.system(size: effectiveFontSize, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("PDF document")
                    .font(.system(size: max(10, effectiveFontSize - 2)))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        .cornerRadius(10)
        .frame(maxWidth: 320, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Copy") {
                withDocumentData(fileInfo) { data in
                    AttachmentActionHelper.copyPDF(id: fileInfo.id, filename: displayName, data: data)
                }
            }
            Button("Save") {
                withDocumentData(fileInfo) { data in
                    AttachmentActionHelper.savePDF(filename: displayName, data: data)
                }
            }
        }
        .onTapGesture {
            if elementIndex < attachmentIndexMap.count,
               let attachmentIndex = attachmentIndexMap[elementIndex] {
                openAttachmentPreview(
                    attachmentElements: attachmentElements,
                    selectedAttachmentIndex: attachmentIndex
                )
            } else {
                previewFile(fileInfo)
            }
        }
    }

    private func previewFile(_ fileInfo: FileAttachmentInfo) {
        let request = makePreviewRequest(for: .file(fileInfo))
        QuickLookPreviewer.shared.preview(requests: [request], selectedIndex: 0)
    }

    private func withDocumentData(_ fileInfo: FileAttachmentInfo, completion: @escaping (Data) -> Void) {
        PersistenceController.shared.container.performBackgroundTask { context in
            let fetchRequest: NSFetchRequest<DocumentEntity> = DocumentEntity.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "id == %@", fileInfo.id as CVarArg)
            fetchRequest.fetchLimit = 1

            guard let documentEntity = try? context.fetch(fetchRequest).first,
                  let fileData = documentEntity.fileData else {
                return
            }

            DispatchQueue.main.async {
                completion(fileData)
            }
        }
    }

    private func openAttachmentPreview(
        attachmentElements: [MessageElements],
        selectedAttachmentIndex: Int
    ) {
        guard !attachmentElements.isEmpty else { return }
        let requests = attachmentElements.map(makePreviewRequest)
        let clampedIndex = max(0, min(selectedAttachmentIndex, requests.count - 1))
        QuickLookPreviewer.shared.preview(requests: requests, selectedIndex: clampedIndex)
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
                          let imageData = imageEntity.image else {
                        completion(nil)
                        return
                    }

                    let rawExtension = (imageEntity.imageFormat?.isEmpty == false)
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
                          let fileData = documentEntity.fileData else {
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

    private func extractAttachmentElements(from elements: [MessageElements]) -> [MessageElements] {
        elements.compactMap { element in
            switch element {
            case .image, .file:
                return element
            default:
                return nil
            }
        }
    }

    private func buildAttachmentIndexMap(for elements: [MessageElements]) -> [Int?] {
        var index = 0
        return elements.map { element in
            switch element {
            case .image, .file:
                defer { index += 1 }
                return index
            default:
                return nil
            }
        }
    }


    private func filterInlineAttachments(_ elements: [MessageElements]) -> [MessageElements] {
        guard !inlineAttachments else { return elements }

        var result: [MessageElements] = []
        var previousWasAttachment = false

        for element in elements {
            switch element {
            case .image, .file:
                previousWasAttachment = true
                continue
            case .text(let text):
                if previousWasAttachment,
                   text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    previousWasAttachment = false
                    continue
                }
                previousWasAttachment = false
                result.append(.text(text))
            default:
                previousWasAttachment = false
                result.append(element)
            }
        }

        return result
    }
}

enum ToolActivityPresentationState: Equatable {
    case awaitingApproval
    case running
    case completed
    case failed

    var accentColor: Color {
        switch self {
        case .awaitingApproval: return .orange
        case .running: return .purple
        case .completed: return .green
        case .failed: return .red
        }
    }

    var badge: String {
        switch self {
        case .awaitingApproval: return "Approval"
        case .running: return "Running"
        case .completed: return "Completed"
        case .failed: return "Failed"
        }
    }

    var symbolName: String {
        switch self {
        case .awaitingApproval: return "hand.raised.fill"
        case .running, .completed: return "terminal.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    var canExpand: Bool {
        switch self {
        case .completed, .failed: return true
        case .awaitingApproval, .running: return false
        }
    }

    var showsProgress: Bool { self == .running }

    func title(for toolName: String) -> String {
        switch self {
        case .awaitingApproval: return "Waiting to run \(toolName)"
        case .running: return "Running \(toolName)"
        case .completed: return "Ran \(toolName)"
        case .failed: return "Failed \(toolName)"
        }
    }
}

struct ToolActivityView: View {
    let activity: ToolActivityRecord
    let state: ToolActivityPresentationState
    @Binding var isExpanded: Bool
    @State private var copied = false

    init(activity: ToolActivityRecord, isExpanded: Binding<Bool>) {
        self.activity = activity
        self.state = activity.isError ? .failed : .completed
        self._isExpanded = isExpanded
    }

    init(name: String, input: String, state: ToolActivityPresentationState) {
        self.activity = ToolActivityRecord(name: name, input: input, output: "", isError: false)
        self.state = state
        self._isExpanded = .constant(false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard state.canExpand else { return }
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(state.accentColor.opacity(0.14))
                        if state.showsProgress {
                            ProgressView()
                                .controlSize(.small)
                                .tint(state.accentColor)
                        } else {
                            Image(systemName: state.symbolName)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(state.accentColor)
                        }
                    }
                    .frame(width: 28, height: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.title(for: activity.name))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(activity.input)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 8)

                    Text(state.badge)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(state.accentColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(state.accentColor.opacity(0.12), in: Capsule())

                    if state.canExpand {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .allowsHitTesting(state.canExpand)

            if isExpanded && state.canExpand {
                Divider()
                    .opacity(0.6)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("OUTPUT")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(activity.output, forType: .string)
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                copied = false
                            }
                        } label: {
                            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }

                    ScrollView(.vertical) {
                        Text(activity.output)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.primary.opacity(0.88))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                }
                .padding(10)
                .background(Color.black.opacity(0.08))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.78))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(state.accentColor.opacity(0.24), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
