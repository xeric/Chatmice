//
//  ImageEnabledMessageInputView.swift
//  Chatmice
//
//  Created by Renat Notfullinon 15.07.2024
//

import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

private struct ToolSelectionPopover: View {
    let chat: ChatEntity

    private var chatID: UUID { chat.id }

    @AppStorage("chatmiceToolsEnabled") private var toolsEnabled = true
    @AppStorage("mcpServersJSON") private var mcpServersJSON = "[]"
    @State private var sources: [ToolSourceDescriptor] = []
    @State private var revision = 0

    private var chatUsesOverride: Bool {
        _ = revision
        return ToolSelectionStore.hasChatOverride(chatID)
    }

    private var toolListHeight: CGFloat {
        let sectionCount = [internalSources, skillSources, mcpSources].filter { !$0.isEmpty }.count
        return min(CGFloat(sources.count) * 44 + CGFloat(sectionCount) * 24, 390)
    }

    private var internalSources: [ToolSourceDescriptor] {
        sources.filter { [.fileTool, .codeExecution, .computerUse, .webSearch].contains($0.kind) }
    }

    private var skillSources: [ToolSourceDescriptor] {
        sources.filter { $0.kind == .skills }
    }

    private var mcpSources: [ToolSourceDescriptor] {
        sources.filter { $0.kind == .mcp }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Tools for This Chat")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.primary)
                    Text(chatUsesOverride ? "Custom selection" : "Using global settings")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if chatUsesOverride {
                    Button {
                        ToolSelectionStore.resetChatToDefaults(chatID)
                        revision += 1
                    } label: {
                        Label("Reset", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Reset this chat to the global tool list")
                }
            }

            if !toolsEnabled {
                Label("Tools are currently turned off", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            if sources.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 64)
            }
            else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        sourceSection(title: "Internal Tools", sources: internalSources)
                        sourceSection(title: "Skills", sources: skillSources)
                        sourceSection(title: "MCP", sources: mcpSources)
                    }
                }
                .frame(height: toolListHeight)
            }
        }
        .foregroundStyle(Color.primary)
        .padding(12)
        .frame(width: 320)
        .task { sources = await ToolSourceCatalog.load() }
        .onChange(of: mcpServersJSON) { _, _ in
            Task { sources = await ToolSourceCatalog.load() }
        }
    }

    @ViewBuilder
    private func sourceSection(title: String, sources: [ToolSourceDescriptor]) -> some View {
        if !sources.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                    .padding(.horizontal, 4)
                    .padding(.top, 2)

                ForEach(sources) { source in
                    HStack(spacing: 8) {
                        Image(systemName: source.isAvailable ? source.kind.systemImage : "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(source.isAvailable ? Color.accentColor : Color.orange)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(source.name)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.primary)
                            Text(source.detail)
                                .font(.caption2)
                                .foregroundStyle(source.isAvailable ? Color.secondary : Color.orange)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        if source.isAvailable {
                            Toggle("", isOn: sourceBinding(source))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                        } else {
                            Text(source.kind == .mcp ? "Offline" : "Disabled")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color.orange)
                                .help(unavailableHelp(for: source))
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 5)
                }
            }
        }
    }

    private func sourceBinding(_ source: ToolSourceDescriptor) -> Binding<Bool> {
        Binding(
            get: {
                _ = revision
                if source.id == ToolSourceID.webSearch {
                    return SearchModeStore.mode(for: chatID) == .web
                }
                return !ToolSelectionStore.disabledSourceIDs(for: chatID).contains(source.id)
            },
            set: { enabled in
                if source.id == ToolSourceID.webSearch {
                    SearchModeStore.setMode(enabled ? .web : .off, for: chatID)
                }
                ToolSelectionStore.setSourceEnabled(enabled, sourceID: source.id, for: chatID)
                revision += 1
            }
        )
    }

    private func unavailableHelp(for source: ToolSourceDescriptor) -> String {
        if source.kind == .mcp {
            return "This MCP server cannot be selected for this chat because it is not connected. Open Settings → MCP Servers to reconnect it or correct its configuration."
        }
        return "This tool is disabled globally. Enable it in Settings before selecting it for this chat."
    }
}

struct MessageInputView: View {
    @Environment(\.managedObjectContext) private var viewContext
    let chat: ChatEntity?
    @Binding var text: String
    @Binding var attachedImages: [ImageAttachment]
    @Binding var attachedFiles: [DocumentAttachment]
    let isInferenceInProgress: Bool
    let isEditingSystemMessage: Bool
    var imageUploadsAllowed: Bool
    var pdfUploadsAllowed: Bool
    var imageGenerationSupported: Bool
    var onEnter: () -> Void
    var onAddImage: () -> Void
    var onAddFile: () -> Void
    var onStopInference: () -> Void
    var onCancelEdit: () -> Void
    var onTextSettled: () -> Void

    private let frontReturnKeyType: ChatmiceTextField.ReturnKeyType = .next
    @State var isFocused: Focus?
    private let inputPlaceholderText: String
    private let cornerRadius: Double
    @State private var isHoveringDropZone = false
    @State private var attachmentOrder: [AttachmentKey] = []
    @State private var draggingAttachment: AttachmentKey?
    @State private var isShowingPhotosPicker = false
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var isShowingToolsPopover = false
    @State private var isShowingSearchPopover = false
    @AppStorage("chatmiceToolsEnabled") private var toolsEnabled = true
    @State private var toolSelectionRevision = 0
    @State private var reasoningSelectionRevision = 0

    private let maxInputHeight = 160.0
    private let initialInputSize = 16.0
    private let inputPadding = 8.0
    private let lineWidthOnBlur = 2.0
    private let lineWidthOnFocus = 3.0
    private let lineColorOnBlur = Color.gray.opacity(0.5)
    private let lineColorOnFocus = Color.blue.opacity(0.8)
    @AppStorage("chatFontSize") private var chatFontSize: Double = 15.0

    private var effectiveFontSize: Double {
        chatFontSize
    }

    private var effectivePlaceholderText: String {
        if imageGenerationSupported {
            return "Ask anything or describe an image to generate"
        }
        return inputPlaceholderText
    }

    private var defaultInputHeight: CGFloat {
        CGFloat(initialInputSize + inputPadding * 2)
    }
    private var inputBorderColor: Color {
        if isHoveringDropZone { return Color.green.opacity(0.8) }
        if isFocused == .focused { return Color.blue.opacity(0.6) }
        return Color.primary.opacity(0.12)
    }

    private var inputBorderWidth: CGFloat {
        isHoveringDropZone ? 2 : 1
    }

    private var toolbarControlForegroundColor: Color {
        .secondary
    }

    private var toolbarControlBackgroundColor: Color {
        Color.primary.opacity(0.06)
    }

    private var activeToolbarControlForegroundColor: Color {
        Color.accentColor
    }

    private var activeToolbarControlBackgroundColor: Color {
        Color.accentColor.opacity(0.14)
    }

    private var isSendDisabled: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachedImages.isEmpty && attachedFiles.isEmpty
    }

    private var stopButtonTransition: AnyTransition {
        .asymmetric(
            insertion: .scale(scale: 0.2, anchor: .trailing)
                .combined(with: .opacity)
                .combined(with: .offset(x: -8, y: 6)),
            removal: .scale(scale: 0.6, anchor: .trailing)
                .combined(with: .opacity)
        )
    }

    private var stopButtonAnimation: Animation {
        .interpolatingSpring(stiffness: 240, damping: 14)
    }

    private var shouldShowAccessoryButton: Bool {
        isInferenceInProgress || isEditingSystemMessage
    }

    private var attachmentButtonIcon: String? {
        switch (imageUploadsAllowed, pdfUploadsAllowed) {
        case (true, true):
            return "paperclip"
        case (true, false):
            return "photo.badge.plus"
        case (false, true):
            return "doc.badge.plus"
        case (false, false):
            return nil
        }
    }

    private var accessoryButtonConfig:
        (systemName: String, foregroundColor: Color, backgroundColor: Color, helpText: String, action: () -> Void)
    {
        if isInferenceInProgress {
            return ("stop.fill", .blue, Color.blue.opacity(0.15), "Stop generating", onStopInference)
        }
        return ("xmark", .blue, Color.blue.opacity(0.15), "Cancel editing", onCancelEdit)
    }

    enum Focus {
        case focused, notFocused
    }

    init(
        chat: ChatEntity? = nil,
        text: Binding<String>,
        attachedImages: Binding<[ImageAttachment]>,
        attachedFiles: Binding<[DocumentAttachment]>,
        isInferenceInProgress: Bool,
        isEditingSystemMessage: Bool = false,
        imageUploadsAllowed: Bool,
        pdfUploadsAllowed: Bool,
        imageGenerationSupported: Bool,
        onEnter: @escaping () -> Void,
        onAddImage: @escaping () -> Void,
        onAddFile: @escaping () -> Void,
        onStopInference: @escaping () -> Void,
        onCancelEdit: @escaping () -> Void = {},
        onTextSettled: @escaping () -> Void = {},
        inputPlaceholderText: String = "Type your prompt here",
        cornerRadius: Double = 20.0
    ) {
        self.chat = chat
        self._text = text
        self._attachedImages = attachedImages
        self._attachedFiles = attachedFiles
        self.isInferenceInProgress = isInferenceInProgress
        self.isEditingSystemMessage = isEditingSystemMessage
        self.imageUploadsAllowed = imageUploadsAllowed
        self.pdfUploadsAllowed = pdfUploadsAllowed
        self.imageGenerationSupported = imageGenerationSupported
        self.onEnter = onEnter
        self.onAddImage = onAddImage
        self.onAddFile = onAddFile
        self.onStopInference = onStopInference
        self.onCancelEdit = onCancelEdit
        self.onTextSettled = onTextSettled
        self.inputPlaceholderText = inputPlaceholderText
        self.cornerRadius = cornerRadius
    }

    private var inputToolbar: some View {
        HStack(spacing: 8) {
            attachmentButton
            if chat != nil {
                webSearchButton
            }
            reasoningChip
            if chat != nil {
                toolsButton
            }
            Spacer()
            micButton
            sendOrStopButton
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var attachmentButton: some View {
        Menu {
            if pdfUploadsAllowed { Button("Add Document / PDF", action: onAddFile) }
            if imageUploadsAllowed {
                Button("Add Image from File", action: onAddImage)
                Button("Add Image from Photos") { isShowingPhotosPicker = true }
            }
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(toolbarControlForegroundColor)
                .frame(width: 24, height: 24)
                .background(Circle().fill(toolbarControlBackgroundColor))
        }
        .menuStyle(.borderlessButton)
        .help("Attach file or image")
    }

    private var isWebSearchConfigured: Bool {
        WebSearchSettings.load().enabled
    }


    private var searchMode: SearchMode {
        _ = toolSelectionRevision
        guard let chat else { return .off }
        let storedMode = SearchModeStore.mode(for: chat.id)
        return isSonarModel && storedMode == .web ? .native : storedMode
    }

    private var isSonarModel: Bool {
        chat?.gptModel.lowercased().contains("sonar") == true
    }

    private var isSearchActive: Bool {
        switch searchMode {
        case .native: return true
        case .web: return toolsEnabled && isWebSearchConfigured
        case .off: return false
        }
    }

    private var webSearchButton: some View {
        Button { isShowingSearchPopover.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: "globe").font(.system(size: 10))
                Text("Search").font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(isSearchActive ? activeToolbarControlBackgroundColor : toolbarControlBackgroundColor)
                    .overlay(
                        Capsule().stroke(isSearchActive ? Color.accentColor : Color.clear, lineWidth: 1)
                    )
            )
            .foregroundStyle(isSearchActive ? activeToolbarControlForegroundColor : toolbarControlForegroundColor)
        }
        .buttonStyle(.plain)
        .help("Choose search mode for this chat")
        .popover(isPresented: $isShowingSearchPopover, arrowEdge: .bottom) {
            searchModePopover
        }
    }

    private var searchModePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Search for This Chat")
                        .font(.system(size: 13, weight: .semibold))
                    Text(searchMode == .off ? "Search is off" : "Using \(searchModeTitle)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: searchEnabledBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }

            HStack(spacing: 8) {
                searchModeOption(
                    mode: .native,
                    title: "Native Search",
                    symbol: "sparkles",
                    available: true
                )
                searchModeOption(
                    mode: .web,
                    title: "Web Search",
                    symbol: "globe",
                    available: isWebSearchConfigured && !isSonarModel
                )
            }

            Divider()

            VStack(alignment: .leading, spacing: 5) {
                Label(searchModeDescription, systemImage: searchMode == .native ? "cpu" : "network")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !isWebSearchConfigured {
                    Text("Configure a third-party provider in Settings › Web Search.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .foregroundStyle(Color.primary)
        .padding(14)
        .frame(width: 360)
    }

    private func searchModeOption(
        mode: SearchMode,
        title: String,
        symbol: String,
        available: Bool
    ) -> some View {
        Button {
            setSearchMode(mode)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(title).fontWeight(.medium)
            }
            .font(.system(size: 12))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(searchMode == mode ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(searchMode == mode ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: 1)
            )
            .foregroundStyle(available ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
        .disabled(!available)
    }

    private var searchEnabledBinding: Binding<Bool> {
        Binding(
            get: { searchMode != .off },
            set: { enabled in
                if !enabled { setSearchMode(.off) }
                else { setSearchMode(.native) }
            }
        )
    }

    private var searchModeTitle: String {
        switch searchMode {
        case .native: return "model-native search"
        case .web: return "Chatmice Web Search"
        case .off: return "no search"
        }
    }

    private var searchModeDescription: String {
        switch searchMode {
        case .native:
            if isSonarModel {
                return "Sonar performs web search natively; no function tools are sent to the endpoint."
            }
            return "Search is delegated to the selected model API; unsupported endpoints may return an API error."
        case .web:
            return "Chatmice calls \(WebSearchSettings.load().defaultSearchProvider.name) and returns results to the model."
        case .off:
            return "Select how this chat should access current web information."
        }
    }

    private func setSearchMode(_ mode: SearchMode) {
        guard let chat else { return }
        SearchModeStore.setMode(mode, for: chat.id)
        let externalEnabled = mode == .web
        if externalEnabled { toolsEnabled = true }
        ToolSelectionStore.setSourceEnabled(externalEnabled, sourceID: ToolSourceID.webSearch, for: chat.id)
        toolSelectionRevision += 1
    }

    private var reasoningProfile: ModelReasoningProfile {
        _ = reasoningSelectionRevision
        guard let chat, let service = chat.apiService else {
            return ModelReasoningRegistry.resolve(modelID: "", serviceType: "")
        }
        return ModelReasoningRegistry.resolve(
            modelID: chat.gptModel,
            serviceType: service.type ?? service.name ?? ""
        )
    }

    private var reasoningSelection: ReasoningEffort {
        _ = reasoningSelectionRevision
        guard let chat else { return .default }
        return ReasoningPreferenceStore.selection(for: chat.gptModel)
    }

    private var reasoningChip: some View {
        Menu {
            ForEach(reasoningProfile.supportedEfforts) { effort in
                Button {
                    guard let chat else { return }
                    ReasoningPreferenceStore.set(effort, for: chat.gptModel)
                    reasoningSelectionRevision += 1
                } label: {
                    if reasoningSelection == effort {
                        Label(effort.title, systemImage: "checkmark")
                    } else {
                        Text(effort.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "brain.head.profile").font(.system(size: 9))
                Text(reasoningSelection.title).font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 7))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(toolbarControlBackgroundColor))
            .foregroundStyle(toolbarControlForegroundColor)
        }
        .menuStyle(.borderlessButton)
        .disabled(!reasoningProfile.supportsReasoning)
        .help(reasoningProfile.supportsReasoning ? "Reasoning effort for this model" : "This model has no known reasoning controls")
    }

    private var toolsButton: some View {
        HStack(spacing: 0) {
            Button(action: { toolsEnabled.toggle() }) {
                HStack(spacing: 4) {
                    Image(systemName: "wrench.and.screwdriver.fill")
                        .font(.system(size: 10))
                    Text("Tools")
                        .font(.system(size: 11, weight: .medium))
                }
                .padding(.leading, 9)
                .padding(.trailing, 7)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(toolsEnabled ? "Disable Agent Tools" : "Enable Agent Tools")

            Rectangle()
                .fill(Color.primary.opacity(0.3))
                .frame(width: 1, height: 14)

            Button(action: { isShowingToolsPopover.toggle() }) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Choose tools for this chat")
            .popover(isPresented: $isShowingToolsPopover, arrowEdge: .bottom) {
                if let chat {
                    ToolSelectionPopover(chat: chat)
                }
            }
        }
        .foregroundStyle(
            toolsEnabled
                ? activeToolbarControlForegroundColor
                : toolbarControlForegroundColor
        )
        .background(
            Capsule()
                .fill(toolsEnabled ? activeToolbarControlBackgroundColor : toolbarControlBackgroundColor)
                .overlay(Capsule().stroke(toolsEnabled ? Color.accentColor : Color.clear, lineWidth: 1))
        )
        .clipShape(Capsule())
    }


    private var micButton: some View {
        Button(action: {}) {
            Image(systemName: "mic.fill")
                .font(.system(size: 12))
                .foregroundStyle(toolbarControlForegroundColor)
                .frame(width: 24, height: 24)
                .background(Circle().fill(toolbarControlBackgroundColor))
        }
        .buttonStyle(.plain)
        .help("Voice input")
    }

    private var sendOrStopButton: some View {
        Group {
            if isInferenceInProgress {
                Button(action: onStopInference) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.red)
                }
                .buttonStyle(.plain)
                .help("Stop generating")
            }
            else {
                Button(action: onEnter) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(isSendDisabled ? Color.secondary.opacity(0.35) : Color.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(isSendDisabled)
                .help("Send message")
            }
        }
    }

    var body: some View {
        let orderedAttachments = orderedAttachmentItems()
        let previewRequests = attachmentPreviewRequests(from: orderedAttachments)
        let previewIndexById = previewRequests.enumerated().reduce(into: [UUID: Int]()) { result, entry in
            result[entry.element.id] = entry.offset
        }

        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(orderedAttachments) { attachment in
                        switch attachment {
                        case .image(let imageAttachment):
                            ImagePreviewView(
                                attachment: imageAttachment,
                                onPreview: {
                                    if let index = previewIndexById[imageAttachment.id] {
                                        QuickLookPreviewer.shared.preview(
                                            requests: previewRequests,
                                            selectedIndex: index
                                        )
                                    }
                                }
                            ) { _ in
                                if let index = attachedImages.firstIndex(where: { $0.id == imageAttachment.id }) {
                                    _ = withAnimation {
                                        attachedImages.remove(at: index)
                                    }
                                }
                            }
                            .onDrag {
                                draggingAttachment = .image(imageAttachment.id)
                                return NSItemProvider(object: attachment.dragIdentifier as NSString)
                            }
                            .onDrop(
                                of: [.text],
                                delegate: AttachmentDropDelegate(
                                    item: .image(imageAttachment.id),
                                    order: $attachmentOrder,
                                    dragging: $draggingAttachment,
                                    onMove: applyAttachmentOrder
                                )
                            )
                        case .file(let fileAttachment):
                            FilePreviewView(
                                attachment: fileAttachment,
                                onPreview: {
                                    if let index = previewIndexById[fileAttachment.id] {
                                        QuickLookPreviewer.shared.preview(
                                            requests: previewRequests,
                                            selectedIndex: index
                                        )
                                    }
                                }
                            ) { _ in
                                if let index = attachedFiles.firstIndex(where: { $0.id == fileAttachment.id }) {
                                    _ = withAnimation {
                                        attachedFiles.remove(at: index)
                                    }
                                }
                            }
                            .onDrag {
                                draggingAttachment = .file(fileAttachment.id)
                                return NSItemProvider(object: attachment.dragIdentifier as NSString)
                            }
                            .onDrop(
                                of: [.text],
                                delegate: AttachmentDropDelegate(
                                    item: .file(fileAttachment.id),
                                    order: $attachmentOrder,
                                    dragging: $draggingAttachment,
                                    onMove: applyAttachmentOrder
                                )
                            )
                        }
                    }
                }
                .padding(.horizontal, 0)
                .padding(.bottom, 8)
            }
            .frame(height: (attachedImages.isEmpty && attachedFiles.isEmpty) ? 0 : 100)

            VStack(alignment: .leading, spacing: 0) {
                ChatmiceTextField(
                    "Enter a message here, press ↩ to send",
                    text: $text,
                    isFocused: $isFocused.equalTo(.focused),
                    returnKeyType: frontReturnKeyType,
                    fontSize: effectiveFontSize,
                    minHeight: 28,
                    maxHeight: maxInputHeight,
                    onEscape: isEditingSystemMessage ? onCancelEdit : nil,
                    onTextSettled: onTextSettled,
                    onCommit: {
                        guard !isInferenceInProgress else { return }
                        onEnter()
                    }
                )
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 6)
                .onTapGesture {
                    isFocused = .focused
                }

                inputToolbar
            }
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(inputBorderColor, lineWidth: inputBorderWidth)
                    )
            )
            .padding(.horizontal, 6)
        }
        .scaleEffect(isHoveringDropZone ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isHoveringDropZone)
        .onDrop(of: [.image, .pdf, .fileURL], isTargeted: $isHoveringDropZone) { providers in
            guard imageUploadsAllowed || pdfUploadsAllowed else { return false }
            return handleDrop(providers: providers)
        }
        .onAppear {
            syncAttachmentOrder()
        }
        .onChange(of: attachedImages.map { $0.id }) {
            syncAttachmentOrder()
        }
        .onChange(of: attachedFiles.map { $0.id }) {
            syncAttachmentOrder()
        }
        .onAppear {
            DispatchQueue.main.async {
                isFocused = .focused
            }
        }
        .photosPicker(
            isPresented: $isShowingPhotosPicker,
            selection: $photoPickerItems,
            matching: .images,
            photoLibrary: .shared()
        )
        .onChange(of: photoPickerItems) { _, newItems in
            guard imageUploadsAllowed, !newItems.isEmpty else { return }
            Task {
                var newAttachments: [ImageAttachment] = []
                for item in newItems {
                    if let data = try? await item.loadTransferable(type: Data.self),
                        let image = NSImage(data: data)
                    {
                        let attachment = ImageAttachment(image: image)
                        attachment.saveToEntity(image: image, context: self.viewContext)
                        newAttachments.append(attachment)
                    }
                }
                if !newAttachments.isEmpty {
                    await MainActor.run {
                        withAnimation {
                            attachedImages.append(contentsOf: newAttachments)
                        }
                    }
                }
                await MainActor.run {
                    photoPickerItems = []
                }
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var didHandleDrop = false

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                didHandleDrop = didHandleDrop || imageUploadsAllowed || pdfUploadsAllowed
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { (data, _) in
                    if let urlData = data as? Data,
                        let url = URL(dataRepresentation: urlData, relativeTo: nil),
                        isValidImageFile(url: url) || isValidPDFFile(url: url)
                    {
                        DispatchQueue.main.async {
                            if isValidPDFFile(url: url) {
                                guard pdfUploadsAllowed else { return }
                                let attachment = DocumentAttachment(url: url, context: self.viewContext)
                                withAnimation {
                                    attachedFiles.append(attachment)
                                }
                            }
                            else {
                                guard imageUploadsAllowed else { return }
                                let attachment = ImageAttachment(url: url, context: self.viewContext)
                                withAnimation {
                                    attachedImages.append(attachment)
                                }
                            }
                        }
                    }
                }
                continue
            }

            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                guard imageUploadsAllowed else { continue }
                didHandleDrop = true
                provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { (item, _) in
                    let attachment: ImageAttachment?

                    if let url = item as? URL {
                        attachment = ImageAttachment(url: url, context: self.viewContext)
                    }
                    else if let image = item as? NSImage {
                        let newAttachment = ImageAttachment(image: image)
                        newAttachment.saveToEntity(image: image, context: self.viewContext)
                        attachment = newAttachment
                    }
                    else if let data = item as? Data, let image = NSImage(data: data) {
                        let newAttachment = ImageAttachment(image: image)
                        newAttachment.saveToEntity(image: image, context: self.viewContext)
                        attachment = newAttachment
                    }
                    else {
                        attachment = nil
                    }

                    guard let attachment else { return }

                    DispatchQueue.main.async {
                        withAnimation {
                            attachedImages.append(attachment)
                        }
                    }
                }
                continue
            }

            if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
                guard pdfUploadsAllowed else { continue }
                didHandleDrop = true
                provider.loadItem(forTypeIdentifier: UTType.pdf.identifier, options: nil) { (item, _) in
                    if let url = item as? URL {
                        DispatchQueue.main.async {
                            let attachment = DocumentAttachment(url: url, context: self.viewContext)
                            withAnimation {
                                attachedFiles.append(attachment)
                            }
                        }
                        return
                    }

                    if let data = item as? Data,
                        let url = PreviewFileHelper.writeTemporaryFile(
                            data: data,
                            filename: (provider.suggestedName ?? "Document.pdf"),
                            defaultExtension: "pdf",
                            id: UUID()
                        )
                    {
                        DispatchQueue.main.async {
                            let attachment = DocumentAttachment(url: url, context: self.viewContext)
                            withAnimation {
                                attachedFiles.append(attachment)
                            }
                        }
                    }
                }
            }
        }

        return didHandleDrop
    }

    private func isValidImageFile(url: URL) -> Bool {
        let validExtensions = ["jpg", "jpeg", "png", "webp", "heic", "heif"]
        return validExtensions.contains(url.pathExtension.lowercased())
    }

    private func isValidPDFFile(url: URL) -> Bool {
        return url.pathExtension.lowercased() == "pdf"
    }

    private func attachmentPreviewRequests(
        from attachments: [AttachmentItem]
    ) -> [QuickLookPreviewer.PreviewItemRequest] {
        var requests: [QuickLookPreviewer.PreviewItemRequest] = []

        for attachment in attachments {
            switch attachment {
            case .image(let imageAttachment):
                if let url = imageAttachment.previewURL() {
                    requests.append(
                        QuickLookPreviewer.PreviewItemRequest(
                            id: imageAttachment.id,
                            title: url.lastPathComponent,
                            url: url
                        )
                    )
                }
                else {
                    let title = imageAttachment.url?.lastPathComponent ?? "Image.jpg"
                    requests.append(
                        QuickLookPreviewer.PreviewItemRequest(
                            id: imageAttachment.id,
                            title: title
                        ) { completion in
                            imageAttachment.fetchPreviewURL(completion: completion)
                        }
                    )
                }
            case .file(let fileAttachment):
                let title = fileAttachment.filename.isEmpty ? "Document.pdf" : fileAttachment.filename
                if let url = fileAttachment.previewURL() {
                    requests.append(
                        QuickLookPreviewer.PreviewItemRequest(
                            id: fileAttachment.id,
                            title: title,
                            url: url
                        )
                    )
                }
                else {
                    requests.append(
                        QuickLookPreviewer.PreviewItemRequest(
                            id: fileAttachment.id,
                            title: title
                        ) { completion in
                            fileAttachment.fetchPreviewURL(completion: completion)
                        }
                    )
                }
            }
        }

        return requests
    }

    private func orderedAttachmentItems() -> [AttachmentItem] {
        let imageMap = Dictionary(uniqueKeysWithValues: attachedImages.map { ($0.id, $0) })
        let fileMap = Dictionary(uniqueKeysWithValues: attachedFiles.map { ($0.id, $0) })

        return attachmentOrder.compactMap { key in
            switch key {
            case .image(let id):
                if let attachment = imageMap[id] {
                    return .image(attachment)
                }
            case .file(let id):
                if let attachment = fileMap[id] {
                    return .file(attachment)
                }
            }
            return nil
        }
    }

    private func syncAttachmentOrder() {
        let currentKeys =
            attachedImages.map { AttachmentKey.image($0.id) }
            + attachedFiles.map { AttachmentKey.file($0.id) }

        if attachmentOrder.isEmpty {
            attachmentOrder = currentKeys
            return
        }

        let currentSet = Set(currentKeys)
        attachmentOrder.removeAll { !currentSet.contains($0) }

        let existingSet = Set(attachmentOrder)
        let newKeys = currentKeys.filter { !existingSet.contains($0) }
        attachmentOrder.append(contentsOf: newKeys)
    }

    private func applyAttachmentOrder(_ order: [AttachmentKey]) {
        let imageMap = Dictionary(uniqueKeysWithValues: attachedImages.map { ($0.id, $0) })
        let fileMap = Dictionary(uniqueKeysWithValues: attachedFiles.map { ($0.id, $0) })

        var newImages: [ImageAttachment] = []
        var newFiles: [DocumentAttachment] = []

        for key in order {
            switch key {
            case .image(let id):
                if let attachment = imageMap[id] {
                    newImages.append(attachment)
                }
            case .file(let id):
                if let attachment = fileMap[id] {
                    newFiles.append(attachment)
                }
            }
        }

        attachedImages = newImages
        attachedFiles = newFiles
    }

    private enum AttachmentKey: Hashable {
        case image(UUID)
        case file(UUID)
    }

    private enum AttachmentItem: Identifiable {
        case image(ImageAttachment)
        case file(DocumentAttachment)

        var id: AttachmentKey {
            switch self {
            case .image(let attachment):
                return .image(attachment.id)
            case .file(let attachment):
                return .file(attachment.id)
            }
        }

        var dragIdentifier: String {
            switch self {
            case .image(let attachment):
                return "image:\(attachment.id.uuidString)"
            case .file(let attachment):
                return "file:\(attachment.id.uuidString)"
            }
        }
    }

    private struct AttachmentDropDelegate: DropDelegate {
        let item: AttachmentKey
        @Binding var order: [AttachmentKey]
        @Binding var dragging: AttachmentKey?
        let onMove: ([AttachmentKey]) -> Void

        func dropEntered(info: DropInfo) {
            guard let dragging, dragging != item else { return }
            guard let fromIndex = order.firstIndex(of: dragging),
                let toIndex = order.firstIndex(of: item)
            else {
                return
            }

            if order[toIndex] != dragging {
                let updated = move(order, fromOffsets: IndexSet(integer: fromIndex), toOffset: toIndex)
                order = updated
                onMove(updated)
            }
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            DropProposal(operation: .move)
        }

        func performDrop(info: DropInfo) -> Bool {
            dragging = nil
            return true
        }

        private func move(_ values: [AttachmentKey], fromOffsets: IndexSet, toOffset: Int) -> [AttachmentKey] {
            var updated = values
            updated.move(fromOffsets: fromOffsets, toOffset: toOffset)
            return updated
        }
    }
}

private struct InputAccessoryButton: View {
    let systemName: String
    let size: CGFloat
    let foregroundColor: Color
    let backgroundColor: Color
    let helpText: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundColor(foregroundColor)
                .frame(width: size, height: size)
                .background(Circle().fill(backgroundColor))
                .overlay(
                    Circle()
                        .stroke(foregroundColor.opacity(0.4), lineWidth: 1)
                )
        }
        .buttonStyle(PlainButtonStyle())
        .help(helpText)
        .accessibilityLabel(Text(helpText))
    }
}

struct ImagePreviewView: View {
    @ObservedObject var attachment: ImageAttachment
    var onPreview: () -> Void
    var onRemove: (Int) -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: {
                onPreview()
            }) {
                Group {
                    if attachment.isLoading {
                        ProgressView()
                            .frame(width: 80, height: 80)
                            .background(Color.gray.opacity(0.1))
                            .cornerRadius(8)
                    }
                    else if let thumbnail = attachment.thumbnail ?? attachment.image {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 80, height: 80)
                            .clipped()
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.gray.opacity(0.5), lineWidth: 1)
                            )
                    }
                    else if let error = attachment.error {
                        VStack {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundColor(.red)
                            Text("Error")
                                .font(.caption)
                        }
                        .frame(width: 80, height: 80)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(8)
                        .help(error.localizedDescription)
                    }
                }
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(attachment.isLoading || attachment.error != nil)

            if attachment.isPreparingPreview {
                ProgressView()
                    .scaleEffect(0.7)
                    .padding(6)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
                    .padding(6)
            }

            Button(action: {
                onRemove(0)
            }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.white)
                    .background(Circle().fill(Color.black.opacity(0.6)))
                    .padding(4)
            }
            .buttonStyle(PlainButtonStyle())
        }
    }
}

struct FilePreviewView: View {
    @ObservedObject var attachment: DocumentAttachment
    var onPreview: () -> Void
    var onRemove: (Int) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let previewSize: CGFloat = 80
        let overlayHeight: CGFloat = previewSize * 0.45

        ZStack(alignment: .topTrailing) {
            Button(action: {
                onPreview()
            }) {
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.1))
                        .frame(width: previewSize, height: previewSize)

                    if attachment.isLoading {
                        ProgressView()
                            .frame(width: previewSize, height: previewSize)
                    }
                    else if let error = attachment.error {
                        VStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundColor(.red)
                            Text("Error")
                                .font(.caption)
                        }
                        .frame(width: previewSize, height: previewSize)
                        .help(error.localizedDescription)
                    }
                    else {
                        let displayName = attachment.filename.isEmpty ? "Document.pdf" : attachment.filename
                        let hasThumbnail = (attachment.thumbnail != nil)

                        if let thumbnail = attachment.thumbnail {
                            Image(nsImage: thumbnail)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: previewSize, height: previewSize)
                        }

                        if hasThumbnail {
                            Rectangle()
                                .fill(.ultraThinMaterial)
                                .mask(
                                    LinearGradient(
                                        colors: [.clear, .black],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .overlay(
                                    LinearGradient(
                                        colors: gradientColors,
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                    .opacity(0.85)
                                )
                                .frame(height: overlayHeight)
                                .frame(maxWidth: previewSize)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            if attachment.previewUnavailable && !hasThumbnail {
                                Text("Preview unavailable")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundColor(secondaryTextColor)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            Text(displayName)
                                .font(.caption2.weight(.semibold))
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .foregroundColor(primaryTextColor)
                                .shadow(color: shadowColor, radius: 1, x: 0, y: 1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 6)
                        .frame(width: previewSize, height: previewSize, alignment: .bottomLeading)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(borderColor, lineWidth: 1)
                )
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(attachment.isLoading || attachment.error != nil)

            if attachment.isPreparingPreview {
                ProgressView()
                    .scaleEffect(0.7)
                    .padding(6)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
                    .padding(6)
            }

            Button(action: {
                onRemove(0)
            }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.white)
                    .background(Circle().fill(Color.black.opacity(0.6)))
                    .padding(4)
            }
            .buttonStyle(PlainButtonStyle())
        }
    }

    private var gradientColors: [Color] {
        if colorScheme == .dark {
            return [
                Color.black.opacity(0.0),
                Color.black.opacity(0.6),
                Color.black.opacity(0.85),
            ]
        }
        return [
            Color.white.opacity(0.0),
            Color.white.opacity(0.7),
            Color.white.opacity(0.92),
        ]
    }

    private var primaryTextColor: Color {
        colorScheme == .dark ? .white : .black
    }

    private var secondaryTextColor: Color {
        colorScheme == .dark ? .white.opacity(0.85) : .black.opacity(0.65)
    }

    private var shadowColor: Color {
        colorScheme == .dark ? .black.opacity(0.55) : .white.opacity(0.6)
    }

    private var borderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08)
    }
}
