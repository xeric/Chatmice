//
//  ImageEnabledMessageInputView.swift
//  Chatmice
//
//  Created by Renat Notfullinon 15.07.2024
//

import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

private func settingsShortcutButton(help: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: "gearshape")
            .font(.system(size: 11, weight: .medium))
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(Color.secondary)
    .background(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.primary.opacity(0.06))
    )
    .help(help)
}

private struct ToolSelectionPopover: View {
    let chat: ChatEntity

    private var chatID: UUID { chat.id }

    @AppStorage("chatmiceToolsEnabled") private var toolsEnabled = true
    @AppStorage("mcpServersJSON") private var mcpServersJSON = "[]"
    @AppStorage("chatmiceFileToolsEnabled") private var fileToolsEnabled = true
    @AppStorage("chatmiceBashEnabled") private var bashEnabled = true
    @AppStorage("chatmiceSkillsEnabled") private var skillsEnabled = true
    @AppStorage("chatmiceComputerEnabled") private var computerEnabled = false
    @State private var sources: [ToolSourceDescriptor] = []
    @State private var revision = 0
    @State private var skills: [SkillInfo] = []
    @State private var isShowingSkillPicker = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    private var chatUsesOverride: Bool {
        _ = revision
        return ToolSelectionStore.hasChatOverride(chatID)
    }

    private var visibleSources: [ToolSourceDescriptor] {
        internalSources + skillSources + mcpSources
    }

    private var toolListHeight: CGFloat {
        let sectionCount = [internalSources, skillSources, mcpSources].filter { !$0.isEmpty }.count
        return min(CGFloat(visibleSources.count) * 44 + CGFloat(sectionCount) * 24, 390)
    }

    private var internalSources: [ToolSourceDescriptor] {
        sources.filter { [.fileTool, .codeExecution, .computerUse].contains($0.kind) }
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
                settingsShortcutButton(
                    help: "Configure Agent Tools",
                    action: openToolsSettings
                )
            }

            if !toolsEnabled {
                Label("Tools are turned off for this chat", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            if visibleSources.isEmpty {
                Text("No tools are enabled in Settings")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
            else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        sourceSection(title: "Agent Tools", sources: internalSources)
                        skillSourceSection()
                        sourceSection(title: "MCP", sources: mcpSources)
                    }
                }
                .frame(height: toolListHeight)
                .disabled(!toolsEnabled)
            }
        }
        .foregroundStyle(Color.primary)
        .padding(12)
        .frame(width: 320)
        .task { await reloadSources() }
        .onChange(of: mcpServersJSON) { _, _ in reloadSourcesLater() }
        .onChange(of: toolsEnabled) { _, _ in reloadSourcesLater() }
        .onChange(of: fileToolsEnabled) { _, _ in reloadSourcesLater() }
        .onChange(of: bashEnabled) { _, _ in reloadSourcesLater() }
        .onChange(of: skillsEnabled) { _, _ in reloadSourcesLater() }
        .onChange(of: computerEnabled) { _, _ in reloadSourcesLater() }
    }

    private func reloadSourcesLater() {
        Task { await reloadSources() }
    }

    @MainActor
    private func reloadSources() async {
        async let loadedSources = ToolSourceCatalog.load(
            fileToolsEnabled: fileToolsEnabled,
            bashEnabled: bashEnabled,
            skillsEnabled: skillsEnabled,
            computerEnabled: computerEnabled
        )
        async let loadedSkills = SkillStore().allSkills()
        sources = await loadedSources
        skills = await loadedSkills
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
                        Image(
                            systemName: source.isAvailable ? source.kind.systemImage : "exclamationmark.triangle.fill"
                        )
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
                        }
                        else {
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

    @ViewBuilder
    private func skillSourceSection() -> some View {
        if let source = skillSources.first {
            let globallyEnabledSkills = skills.filter {
                SkillEnablementStore.isEnabled($0.directory.lastPathComponent)
            }
            let disabledIDs = ToolSelectionStore.disabledSourceIDs(for: chatID)
            let selectedCount = globallyEnabledSkills.filter {
                !disabledIDs.contains(ToolSourceID.skill($0.directory.lastPathComponent))
            }.count

            VStack(alignment: .leading, spacing: 2) {
                Text("SKILLS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                    .padding(.horizontal, 4)
                    .padding(.top, 2)

                HStack(spacing: 8) {
                    Image(systemName: source.isAvailable ? source.kind.systemImage : "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(source.isAvailable ? Color.accentColor : Color.orange)
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(source.name)
                            .font(.system(size: 12, weight: .medium))
                        Text(
                            skillSummary(
                                source: source,
                                selectedCount: selectedCount,
                                installedCount: skills.count
                            )
                        )
                        .font(.caption2)
                        .foregroundStyle(source.isAvailable ? Color.secondary : Color.orange)
                        .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard source.isAvailable, !skills.isEmpty else { return }
                        isShowingSkillPicker = true
                    }

                    Spacer(minLength: 4)

                    if source.isAvailable {
                        Button {
                            isShowingSkillPicker = true
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 18, height: 22)
                        }
                        .buttonStyle(.plain)
                        .disabled(skills.isEmpty)
                        .help(skills.isEmpty ? "No skills are installed" : "Choose skills for this chat")
                        .popover(isPresented: $isShowingSkillPicker, arrowEdge: .trailing) {
                            ChatSkillSelectionPopover(
                                chatID: chatID,
                                skills: skills,
                                onSelectionChanged: { revision += 1 }
                            )
                        }

                        Toggle("", isOn: sourceBinding(source))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                    }
                    else {
                        Text("Disabled")
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

    private func skillSummary(
        source: ToolSourceDescriptor,
        selectedCount: Int,
        installedCount: Int
    ) -> String {
        guard source.isAvailable else { return "Disabled globally" }
        guard installedCount > 0 else { return "No skills installed" }
        return "\(selectedCount) of \(installedCount) enabled"
    }

    private func sourceBinding(_ source: ToolSourceDescriptor) -> Binding<Bool> {
        Binding(
            get: {
                _ = revision
                return !ToolSelectionStore.disabledSourceIDs(for: chatID).contains(source.id)
            },
            set: { enabled in
                ToolSelectionStore.setSourceEnabled(enabled, sourceID: source.id, for: chatID)
                revision += 1
            }
        )
    }

    private func openToolsSettings() {
        UserDefaults.standard.set(SettingsPage.tools.rawValue, forKey: "requestedSettingsPage")
        openWindow(id: "settings")
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: NSNotification.Name("OpenSettingsPage"),
                object: SettingsPage.tools.rawValue
            )
        }
        dismiss()
    }

    private func unavailableHelp(for source: ToolSourceDescriptor) -> String {
        if source.kind == .mcp {
            return
                "This MCP server cannot be selected for this chat because it is not connected. Open Settings → MCP Servers to reconnect it or correct its configuration."
        }
        return "This tool is disabled globally. Enable it in Settings before selecting it for this chat."
    }
}

private struct ChatSkillSelectionPopover: View {
    let chatID: UUID
    let skills: [SkillInfo]
    let onSelectionChanged: () -> Void

    @State private var searchText = ""
    @State private var revision = 0

    private var filteredSkills: [SkillInfo] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return selectableSkills }
        return selectableSkills.filter { skill in
            skill.name.localizedCaseInsensitiveContains(query)
                || skill.description.localizedCaseInsensitiveContains(query)
                || skill.directory.lastPathComponent.localizedCaseInsensitiveContains(query)
        }
    }

    private var selectableSkills: [SkillInfo] {
        skills.filter { SkillEnablementStore.isEnabled($0.directory.lastPathComponent) }
    }

    private var selectedCount: Int {
        _ = revision
        let disabled = ToolSelectionStore.disabledSourceIDs(for: chatID)
        return selectableSkills.filter {
            !disabled.contains(ToolSourceID.skill($0.directory.lastPathComponent))
        }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Skills for This Chat")
                        .font(.system(size: 13, weight: .semibold))
                    Text("\(selectedCount) of \(selectableSkills.count) available skills enabled")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Defaults") { resetToDefaults() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Restore the global Skill selection for this chat")
            }

            TextField("Search skills", text: $searchText)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                Button("Enable All") { setAllEnabled(true) }
                    .controlSize(.small)
                Button("Disable All") { setAllEnabled(false) }
                    .controlSize(.small)
                Spacer()
            }

            Divider()

            if filteredSkills.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? "No Skills Available" : "No Matching Skills",
                    systemImage: searchText.isEmpty ? "books.vertical" : "magnifyingglass",
                    description: Text(
                        searchText.isEmpty
                            ? "Enable Skills in Settings to make them available here."
                            : "Try a different name or description."
                    )
                )
                .frame(maxWidth: .infinity, minHeight: 140)
            }
            else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(filteredSkills) { skill in
                            skillRow(skill)
                        }
                    }
                }
                .frame(minHeight: 120, maxHeight: 330)
            }
        }
        .padding(12)
        .frame(width: 360)
    }

    @ViewBuilder
    private func skillRow(_ skill: SkillInfo) -> some View {
        let identifier = skill.directory.lastPathComponent

        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "book.closed")
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
                .frame(width: 16, height: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(skill.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(skill.description.isEmpty ? identifier : skill.description)
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(2)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                let binding = skillBinding(identifier)
                binding.wrappedValue.toggle()
            }

            Spacer(minLength: 8)

            Toggle("", isOn: skillBinding(identifier))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
    }

    private func skillBinding(_ identifier: String) -> Binding<Bool> {
        Binding(
            get: {
                _ = revision
                return !ToolSelectionStore.disabledSourceIDs(for: chatID)
                    .contains(ToolSourceID.skill(identifier))
            },
            set: { enabled in
                ToolSelectionStore.setSourceEnabled(
                    enabled,
                    sourceID: ToolSourceID.skill(identifier),
                    for: chatID
                )
                didChangeSelection()
            }
        )
    }

    private func setAllEnabled(_ enabled: Bool) {
        ToolSelectionStore.setSourcesEnabled(
            enabled,
            sourceIDs: selectableSkills.map { ToolSourceID.skill($0.directory.lastPathComponent) },
            for: chatID
        )
        didChangeSelection()
    }

    private func resetToDefaults() {
        ToolSelectionStore.resetSourcesToDefaults(
            skills.map { ToolSourceID.skill($0.directory.lastPathComponent) },
            for: chatID
        )
        didChangeSelection()
    }

    private func didChangeSelection() {
        revision += 1
        onSelectionChanged()
    }
}

struct MessageInputView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.openWindow) private var openWindow
    let chat: ChatEntity?
    @Binding var text: String
    @Binding var attachedImages: [ImageAttachment]
    @Binding var attachedFiles: [DocumentAttachment]
    @Binding var attachedAudio: DocumentAttachment?
    let isInferenceInProgress: Bool
    let isEditingSystemMessage: Bool
    var imageUploadsAllowed: Bool
    var pdfUploadsAllowed: Bool
    var imageGenerationSupported: Bool
    var audioInputAllowed: Bool
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
    @AppStorage(WebSearchSettings.storageKey) private var webSearchSettingsData = Data()
    @State private var toolSelectionRevision = 0
    @State private var reasoningSelectionRevision = 0
    @StateObject private var voiceRecorder = VoiceRecordingController()
    @State private var voiceRecordingError: String?

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
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && attachedImages.isEmpty && attachedFiles.isEmpty && attachedAudio == nil
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
        attachedAudio: Binding<DocumentAttachment?> = .constant(nil),
        isInferenceInProgress: Bool,
        isEditingSystemMessage: Bool = false,
        imageUploadsAllowed: Bool,
        pdfUploadsAllowed: Bool,
        imageGenerationSupported: Bool,
        audioInputAllowed: Bool = false,
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
        self._attachedAudio = attachedAudio
        self.imageUploadsAllowed = imageUploadsAllowed
        self.pdfUploadsAllowed = pdfUploadsAllowed
        self.imageGenerationSupported = imageGenerationSupported
        self.audioInputAllowed = audioInputAllowed
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
        _ = webSearchSettingsData
        return WebSearchSettings.load().enabled
    }

    private var searchMode: SearchMode {
        _ = toolSelectionRevision
        guard let chat else { return .off }
        return ChatmiceEngine.effectiveSearchMode(
            searchEnabled: isWebSearchConfigured,
            storedMode: SearchModeStore.mode(for: chat.id),
            isSonarModel: isSonarModel
        )
    }

    private var isSonarModel: Bool {
        chat?.gptModel.lowercased().contains("sonar") == true
    }

    private var isSearchActive: Bool {
        switch searchMode {
        case .native: return true
        case .web: return isWebSearchConfigured
        case .off: return false
        }
    }

    private var webSearchButton: some View {
        Button {
            isShowingSearchPopover.toggle()
        } label: {
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
                    .disabled(!isWebSearchConfigured)
                settingsShortcutButton(
                    help: "Configure Web Search",
                    action: openWebSearchSettings
                )
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
                if !enabled {
                    setSearchMode(.off)
                }
                else {
                    setSearchMode(.native)
                }
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
            if let provider = WebSearchSettings.load().defaultSearchProvider {
                return "Chatmice calls \(provider.name) and returns results to the model."
            }
            return "Chatmice exposes web_fetch without enabling a web search provider."
        case .off:
            return "Select how this chat should access current web information."
        }
    }

    private func openWebSearchSettings() {
        UserDefaults.standard.set(SettingsPage.webSearch.rawValue, forKey: "requestedSettingsPage")
        isShowingSearchPopover = false
        openWindow(id: "settings")
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: NSNotification.Name("OpenSettingsPage"),
                object: SettingsPage.webSearch.rawValue
            )
        }
    }

    private func setSearchMode(_ mode: SearchMode) {
        guard let chat else { return }
        SearchModeStore.setMode(isWebSearchConfigured ? mode : .off, for: chat.id)
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
                    }
                    else {
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
        .help(
            reasoningProfile.supportsReasoning
                ? "Reasoning effort for this model" : "This model has no known reasoning controls"
        )
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
            .help(toolsEnabled ? "Disable Tools" : "Enable Tools")

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
        Button(action: toggleVoiceRecording) {
            HStack(spacing: 4) {
                if voiceRecorder.isStarting {
                    ProgressView().controlSize(.mini)
                }
                else {
                    Image(systemName: voiceRecorder.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 12))
                }
                if voiceRecorder.isRecording {
                    Text(formatDuration(voiceRecorder.duration))
                        .font(.system(size: 10, design: .monospaced))
                }
            }
            .foregroundStyle(voiceRecorder.isRecording ? Color.white : toolbarControlForegroundColor)
            .padding(.horizontal, voiceRecorder.isRecording ? 8 : 0)
            .frame(minWidth: 24, minHeight: 24)
            .background(Capsule().fill(voiceRecorder.isRecording ? Color.red : toolbarControlBackgroundColor))
        }
        .buttonStyle(.plain)
        .disabled(isInferenceInProgress || voiceRecorder.isStarting)
        .help(
            voiceRecorder.isStarting
                ? "Requesting microphone access…"
                : (voiceRecorder.isRecording ? "Stop and attach WAV recording" : "Record WAV voice input")
        )
    }

    private func toggleVoiceRecording() {
        voiceRecorder.toggle { result in
            switch result {
            case .success(let url):
                attachedAudio = DocumentAttachment(url: url, context: viewContext)
            case .failure(let error):
                voiceRecordingError = error.localizedDescription
            }
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        String(format: "%d:%02d", Int(duration) / 60, Int(duration) % 60)
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
                    if let audio = attachedAudio {
                        AudioRecordingPreview(attachment: audio) {
                            attachedAudio = nil
                        }
                    }
                }
                .padding(.horizontal, 0)
                .padding(.bottom, 8)
            }
            .frame(height: (attachedImages.isEmpty && attachedFiles.isEmpty && attachedAudio == nil) ? 0 : 100)

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
                    onPasteImage: addPastedImage,
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
        .onDrop(of: [.image, .pdf, .audio, .fileURL], isTargeted: $isHoveringDropZone) { providers in
            guard imageUploadsAllowed || pdfUploadsAllowed || audioInputAllowed || !isInferenceInProgress else {
                return false
            }
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
        .alert(
            "Voice Recording Failed",
            isPresented: Binding(
                get: { voiceRecordingError != nil },
                set: { if !$0 { voiceRecordingError = nil } }
            )
        ) {
            Button("Open Microphone Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("OK", role: .cancel) { voiceRecordingError = nil }
        } message: {
            Text(voiceRecordingError ?? "Unknown recording error")
        }
    }

    private func addPastedImage(_ image: NSImage) {
        guard imageUploadsAllowed else { return }
        let attachment = ImageAttachment(image: image)
        attachment.saveToEntity(image: image, context: viewContext)
        withAnimation {
            attachedImages.append(attachment)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var didHandleDrop = false

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                didHandleDrop = didHandleDrop || imageUploadsAllowed || pdfUploadsAllowed || !isInferenceInProgress
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { (data, _) in
                    guard let urlData = data as? Data,
                        let url = URL(dataRepresentation: urlData, relativeTo: nil)
                    else { return }
                    DispatchQueue.main.async {
                        if isValidPDFFile(url: url) {
                            guard pdfUploadsAllowed else { return }
                            attachedFiles.append(DocumentAttachment(url: url, context: viewContext))
                        }
                        else if isValidAudioFile(url: url) {
                            guard !isInferenceInProgress else { return }
                            do {
                                let normalizedURL = try AudioAttachmentConverter.normalizeForUpload(url)
                                attachedAudio = DocumentAttachment(url: normalizedURL, context: viewContext)
                            }
                            catch {
                                return
                            }
                        }
                        else if isValidImageFile(url: url) {
                            guard imageUploadsAllowed else { return }
                            attachedImages.append(ImageAttachment(url: url, context: viewContext))
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

    private func isValidAudioFile(url: URL) -> Bool {
        let validExtensions = ["mp3", "m4a", "aac", "wav"]
        return validExtensions.contains(url.pathExtension.lowercased())
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

private struct AudioRecordingPreview: View {
    @ObservedObject var attachment: DocumentAttachment
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            AudioAttachmentPlayerView(
                id: attachment.id,
                filename: attachment.filename,
                localURL: attachment.url
            )

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.white)
                    .background(Circle().fill(Color.black.opacity(0.6)))
                    .padding(4)
            }
            .buttonStyle(.plain)
        }
    }
}
