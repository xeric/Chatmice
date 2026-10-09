//
//  ContentView.swift
//  Chatmice
//
//  Created by Renat Notfullin on 11.03.2023.
//

import AppKit
import Combine
import CoreData
import Foundation
import SwiftUI

struct ContentView: View {
    private static var handledStartChatRequestIds = Set<String>()
    private static var handledResponseIds = Set<String>()

    @State private var window: NSWindow?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.managedObjectContext) private var viewContext

    @Environment(\.openWindow) private var openWindow
    @FetchRequest(
        entity: ChatEntity.entity(),
        sortDescriptors: [NSSortDescriptor(keyPath: \ChatEntity.updatedDate, ascending: false)]
    )
    private var chats: FetchedResults<ChatEntity>

    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \APIServiceEntity.addedDate, ascending: false)])
    private var apiServices: FetchedResults<APIServiceEntity>
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \PersonaEntity.order, ascending: true)])
    private var personas: FetchedResults<PersonaEntity>

    @State var selectedChat: ChatEntity?
    @State private var displayedChat: ChatEntity?
    @State private var headerChat: ChatEntity?
    @AppStorage("gptToken") var gptToken = ""
    @AppStorage("gptModel") var gptModel = AppConstants.defaultPrimaryModel
    @AppStorage("systemMessage") var systemMessage = AppConstants.chatGptSystemMessage
    @AppStorage("lastOpenedChatId") var lastOpenedChatId = ""
    @AppStorage("apiUrl") var apiUrl = AppConstants.apiUrlOpenAIResponses
    @AppStorage(SettingsIndicatorKeys.generalSeen) private var generalSettingsSeen: Bool = false
    @AppStorage("mainWindowBackgroundOpacity") private var mainWindowBackgroundOpacity: Double = 75
    @AppStorage("mainWindowBlurLevel") private var mainWindowBlurLevel: Double = 10
    @StateObject private var previewStateManager = PreviewStateManager()
    @StateObject private var activityStore = ChatActivityStore.shared

    @State private var windowRef: NSWindow?
    @AppStorage("isSidebarVisible") var isSidebarVisible = true
    @State private var lastChatCount: Int? = nil
    @State private var searchText = ""
    @State private var isSearchPresented = false
    @State private var isShowingModelPickerPopover = false
    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        NavigationSplitView(
            columnVisibility: Binding(
                get: { isSidebarVisible ? .all : .detailOnly },
                set: { isSidebarVisible = $0 != .detailOnly }
            )
        ) {
            VStack(spacing: 0) {
                sidebarHeader
                ChatListView(selectedChat: $selectedChat, searchText: $searchText)
                    .environmentObject(activityStore)

                Divider()

                // Sidebar bottom footer bar: Settings ⚙️ on left, New Chat 📝 on right
                HStack(spacing: 12) {
                    Button {
                        openWindow(id: "settings")
                    } label: {
                        settingsGearIcon
                    }
                    .buttonStyle(.plain)
                    .help("Settings (⌘,)")

                    Spacer()

                    Button(action: newChat) {
                        HStack(spacing: 4) {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 13, weight: .medium))
                            Text("New Chat")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.accentColor.opacity(0.15))
                        )
                        .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("New Chat (⌘N)")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.clear)
            }
            .background {
                MainGlassBackground(
                    opacity: mainWindowBackgroundOpacity,
                    blurLevel: mainWindowBlurLevel
                )
            }
            .navigationSplitViewColumnWidth(
                min: 180,
                ideal: 220,
                max: 400
            )
        } detail: {
            VStack(spacing: 0) {
                detailHeader
                HSplitView {
                    conversationDetail

                    if previewStateManager.isPreviewVisible {
                        PreviewPane(stateManager: previewStateManager)
                    }
                }
            }
            .background {
                MainGlassBackground(
                    opacity: mainWindowBackgroundOpacity,
                    blurLevel: mainWindowBlurLevel
                )
            }
            .onSubmit(of: .search) {
                // Handle Enter key in search field - go to next occurrence
                NotificationCenter.default.post(
                    name: NSNotification.Name("FindNext"),
                    object: nil
                )
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ActivateSearch"))) { _ in
                NSApp.keyWindow?.makeFirstResponder(nil)
                isSearchPresented = true
                isSearchFieldFocused = true
            }
            .onAppear {
                installLocalKeyMonitor()
            }
        }
        .onAppear(perform: {
            if chats.count == 0 { isSidebarVisible = false }
            lastChatCount = chats.count
            if let lastOpenedChatId = UUID(uuidString: lastOpenedChatId) {
                if let lastOpenedChat = chats.first(where: { $0.id == lastOpenedChatId }) {
                    selectedChat = lastOpenedChat
                }
            }
            activityStore.updatePresentationContext(
                focusedChatId: selectedChat?.id,
                applicationIsActive: scenePhase == .active && NSApp.isActive
            )
        })
        .onChange(of: chats.count) { _, newCount in
            if let prev = lastChatCount {
                updateSidebarVisibilityForChatCount(previousCount: prev, newCount: newCount)
            }
            lastChatCount = newCount
        }
        .background(WindowAccessor(window: $window))
        .onAppear {
            NotificationCenter.default.addObserver(
                forName: AppConstants.newChatNotification,
                object: nil,
                queue: .main
            ) { notification in
                let currentWindowId = window?.windowNumber
                let sourceWindowId = notification.userInfo?["windowId"] as? Int

                let shouldHandle: Bool
                if let sourceWindowId, sourceWindowId > 0 {
                    shouldHandle = sourceWindowId == currentWindowId
                }
                else {
                    shouldHandle = true
                }

                guard shouldHandle else { return }

                if let requestId = notification.userInfo?["requestId"] as? String {
                    if ContentView.handledStartChatRequestIds.contains(requestId) {
                        return
                    }
                    ContentView.handledStartChatRequestIds.insert(requestId)
                }

                if let uriString = notification.userInfo?["apiServiceURI"] as? String,
                    let service = apiService(fromURI: uriString)
                {
                    newChat(using: service)
                }
                else {
                    newChat()
                }
            }

            // Clear badge for selected chat when app becomes active
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    activityStore.updatePresentationContext(
                        focusedChatId: selectedChat?.id,
                        applicationIsActive: true
                    )
                }
            }
        }
        .navigationTitle("")
        .ignoresSafeArea(.container, edges: .top)
        .background {
            MainGlassBackground(
                opacity: mainWindowBackgroundOpacity,
                blurLevel: mainWindowBlurLevel
            )
                .ignoresSafeArea()
        }

        .onChange(of: scenePhase) { _, phase in
            activityStore.updatePresentationContext(
                focusedChatId: selectedChat?.id,
                applicationIsActive: phase == .active && NSApp.isActive
            )
        }
        .onChange(of: selectedChat) { _, newValue in
            handleSelectedChatChange(newValue)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ChatResponseCompleted"))) {
            notification in
            if let responseId = notification.userInfo?["responseId"] as? String {
                if ContentView.handledResponseIds.contains(responseId) {
                    return
                }
                ContentView.handledResponseIds.insert(responseId)
            }

            guard let chatId = notification.userInfo?["chatId"] as? UUID else { return }
            let isKeyWindow = window?.isKeyWindow ?? false
            let isActiveChat = selectedChat?.id == chatId
            let appIsActive = scenePhase == .active && NSApp.isActive

            if appIsActive && !isKeyWindow {
                return
            }

            if !isActiveChat || !appIsActive {
                let chatName = chatDisplayName(
                    for: chatId,
                    fallback: notification.userInfo?["chatName"] as? String
                )
                let message = notification.userInfo?["message"] as? String ?? ""
                let body = notificationBody(from: message)
                NotificationPresenter.shared.scheduleNotification(
                    identifier: "chat-response-\(chatId.uuidString)-\(Date().timeIntervalSince1970)",
                    title: chatName,
                    body: body
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ClearChat"))) { _ in
            if selectedChat != nil {
                clearSelectedChat()
            }
        }
        .environmentObject(previewStateManager)
    }

    private var sidebarHeader: some View {
        Color.clear
            .frame(height: 38)
    }

    private var detailHeader: some View {
        HStack(spacing: 12) {
            if !isSidebarVisible {
                // Reserve only the traffic-light and sidebar-toggle area.
                Color.clear.frame(width: 132)
            }

            Text(headerChat.map { $0.name.isEmpty ? ($0.persona?.name ?? "Chatmice") : $0.name } ?? "")
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)

            Spacer(minLength: 24)

            modelPickerButton

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search in chat…", text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($isSearchFieldFocused)
                    .onSubmit {
                        NotificationCenter.default.post(name: NSNotification.Name("FindNext"), object: nil)
                    }
            }
            .padding(.horizontal, 11)
            .frame(minWidth: 180, idealWidth: 320, maxWidth: 320, minHeight: 36, maxHeight: 36)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                    )
            )
            .onChange(of: isSearchFieldFocused) { _, focused in
                isSearchPresented = focused
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .frame(height: 52)
        .background(Color.clear)
    }

    @ViewBuilder
    private var modelPickerButton: some View {
        if let headerChat {
            Button(action: { isShowingModelPickerPopover.toggle() }) {
                HStack(spacing: 6) {
                    ProviderBrandIcon(
                        name: headerChat.apiService?.name ?? "",
                        type: headerChat.apiService?.type ?? ""
                    )
                    .frame(width: 14, height: 14)

                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 3) {
                            Text(
                                headerChat.gptModel.isEmpty
                                    ? (headerChat.apiService?.model ?? "Select Model") : headerChat.gptModel
                            )
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                        Text(headerChat.apiService?.name ?? "Select Provider")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.primary.opacity(0.045))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isShowingModelPickerPopover, arrowEdge: .bottom) {
                ModelPickerPopoverView(
                    apiServices: Array(apiServices),
                    selectedChat: headerChat,
                    onSelect: { service, model in
                        handleServiceChange(headerChat, service, selectedModel: model)
                        isShowingModelPickerPopover = false
                    }
                )
            }
        }
    }

    @ViewBuilder
    private var conversationDetail: some View {
        Group {
            if let displayedChat {
                ChatView(
                    viewContext: viewContext,
                    chat: displayedChat,
                    searchText: $searchText,
                    window: window
                )
                .id(displayedChat.objectID)
                .frame(minWidth: 400)
            }
            else {
                WelcomeScreen(
                    chatsCount: chats.count,
                    apiServiceIsPresent: apiServices.count > 0,
                    customUrl: apiUrl != AppConstants.apiUrlOpenAIResponses,
                    openPreferencesView: openPreferencesView,
                    newChat: newChat
                )
            }
        }
        .frame(minWidth: 400)
    }

    private var settingsGearIcon: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: "gear")
            if SettingsIndicatorState.needsAttention(generalSeen: generalSettingsSeen) {
                SettingsIndicatorDot()
                    .offset(x: 1, y: -1)
            }
        }
    }

    func newChat() {
        newChat(using: nil)
    }

    private func newChat(using preferredService: APIServiceEntity?) {
        let uuid = UUID()
        let newChat = ChatEntity(context: viewContext)

        newChat.id = uuid
        newChat.newChat = true
        newChat.temperature = 1
        newChat.top_p = 1.0
        newChat.behavior = "default"
        newChat.draftMessage = ""
        newChat.createdDate = Date()
        newChat.updatedDate = Date()
        newChat.systemMessage = systemMessage
        newChat.lastSequence = 0

        // 1. If explicit preferredService passed, use it
        if let service = preferredService {
            newChat.apiService = service
            newChat.gptModel = service.model ?? AppConstants.defaultModel(for: service.type)
        }
        // 2. Otherwise inherit from Global Model (the model chosen in previous chats)
        else if let globalModel = UserDefaults.standard.string(forKey: "global_selected_model"),
            !globalModel.isEmpty,
            let globalServiceID = UserDefaults.standard.string(forKey: "global_selected_service_id"),
            let matchedService = apiServices.first(where: { $0.id?.uuidString == globalServiceID })
        {
            newChat.apiService = matchedService
            newChat.gptModel = globalModel
        }
        // 3. Fallback: inherit from the most recent chat if available
        else if let lastChat = chats.first, let lastService = lastChat.apiService, !lastChat.gptModel.isEmpty {
            newChat.apiService = lastService
            newChat.gptModel = lastChat.gptModel
        }
        // 4. Otherwise: leave empty! User will be prompted to select a model
        else {
            newChat.apiService = nil
            newChat.gptModel = ""
        }

        let defaultPersona =
            personas.first {
                $0.name == AppConstants.PersonaPresets.defaultAssistant.name
            } ?? newChat.apiService?.defaultPersona
        newChat.persona = defaultPersona
        newChat.systemMessage = defaultPersona?.systemMessage ?? AppConstants.chatGptSystemMessage
        do {
            try viewContext.save()
            selectedChat = newChat
        }
        catch {
            print("Error saving new chat: \(error.localizedDescription)")
            viewContext.rollback()
        }
    }

    private func apiService(fromURI uriString: String) -> APIServiceEntity? {
        guard let url = URL(string: uriString),
            let objectID = viewContext.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: url)
        else {
            return nil
        }

        do {
            return try viewContext.existingObject(with: objectID) as? APIServiceEntity
        }
        catch {
            print("Failed to locate API service for URI \(uriString): \(error)")
            return nil
        }
    }

    private func resolveDefaultAPIService() -> APIServiceEntity? {
        if let service = apiServices.first(where: { $0.isDefault }) {
            return service
        }

        if let defaultServiceIDString = UserDefaults.standard.string(forKey: "defaultApiService"),
            let url = URL(string: defaultServiceIDString),
            let objectID = viewContext.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: url),
            let service = try? viewContext.existingObject(with: objectID) as? APIServiceEntity
        {
            service.isDefault = true
            viewContext.saveWithRetry(attempts: 1)
            UserDefaults.standard.removeObject(forKey: "defaultApiService")
            return service
        }

        return nil
    }

    func openPreferencesView() {
        openWindow(id: "settings")
    }

    func clearSelectedChat() {
        guard let chat = selectedChat else { return }
        let alert = NSAlert()
        alert.messageText = "Clear chat \(chat.name)?"
        alert.informativeText =
            "Are you sure you want to delete all messages from this chat? Chat parameters will not be deleted. This action cannot be undone."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: NSApp.keyWindow!) { response in
            if response == .alertFirstButtonReturn {
                chat.clearMessages()
                do {
                    try viewContext.save()
                }
                catch {
                    print("Error clearing chat: \(error.localizedDescription)")
                }
            }
        }
    }

    private func getIndex(for chat: ChatEntity) -> Int {
        if let index = chats.firstIndex(where: { $0.id == chat.id }) {
            return index
        }
        else {
            fatalError("Chat not found in array")
        }
    }

    private func handleServiceChange(_ chat: ChatEntity, _ newService: APIServiceEntity, selectedModel: String? = nil) {

        chat.apiService = newService
        if let model = selectedModel, !model.isEmpty {
            chat.gptModel = model
        }
        else if chat.gptModel.isEmpty {
            chat.gptModel = newService.model ?? AppConstants.defaultModel(for: newService.type)
        }

        // Record as Global Model for subsequent new chats
        if !chat.gptModel.isEmpty {
            UserDefaults.standard.set(chat.gptModel, forKey: "global_selected_model")
        }
        if let serviceID = newService.id?.uuidString {
            UserDefaults.standard.set(serviceID, forKey: "global_selected_service_id")
        }
        chat.objectWillChange.send()
        try? viewContext.save()

        NotificationCenter.default.post(
            name: NSNotification.Name("RecreateMessageManager"),
            object: nil,
            userInfo: ["chatId": chat.id]
        )
    }

    private func installLocalKeyMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let isShiftReturn = event.keyCode == 36 && event.modifierFlags.contains(.shift)
            if isShiftReturn && isSearchPresented && !searchText.isEmpty,
                let firstResponder = NSApp.keyWindow?.firstResponder as? NSView,
                String(describing: type(of: firstResponder)).contains("Search")
            {
                NotificationCenter.default.post(name: NSNotification.Name("FindPrevious"), object: nil)
                return nil
            }

            let isClearShortcut =
                event.keyCode == 51
                && event.modifierFlags.contains(.command)
                && event.modifierFlags.contains(.shift)
            if isClearShortcut && selectedChat != nil {
                clearSelectedChat()
                return nil
            }
            return event
        }
    }

    private func handleSelectedChatChange(_ chat: ChatEntity?) {
        previewStateManager.hidePreview()
        if let chatID = chat?.id {
            activityStore.clear(chatID)
        }
        activityStore.updatePresentationContext(
            focusedChatId: chat?.id,
            applicationIsActive: scenePhase == .active && NSApp.isActive
        )

        guard let chat, !chat.isDeleted else {
            displayedChat = nil
            headerChat = nil
            return
        }

        displayedChat = chat
        headerChat = chat
    }

    private func updateSidebarVisibilityForChatCount(previousCount: Int, newCount: Int) {
        if newCount == 0 {
            isSidebarVisible = false
            return
        }

        if previousCount == 0 && newCount > 0 {
            isSidebarVisible = true
        }
    }
}

extension ContentView {
    fileprivate func chatDisplayName(for chatId: UUID, fallback: String?) -> String {
        if let chat = chats.first(where: { $0.id == chatId }) {
            if !chat.name.isEmpty {
                return chat.name
            }
            if let persona = chat.persona?.name, !persona.isEmpty {
                return persona
            }
        }
        if let fallback, !fallback.isEmpty {
            return fallback
        }
        return "Chat"
    }

    fileprivate func notificationBody(from message: String) -> String {
        if message.isEmpty {
            return "Response finished"
        }

        let messageWithoutNewlines = ToolActivityRecord.removingMarkers(in: message)
            .replacingOccurrences(of: "\n", with: " ")
        let messageWithoutThinking = messageWithoutNewlines.replacingOccurrences(
            of: "<think>.*?</think>",
            with: "",
            options: .regularExpression
        )
        let trimmed = messageWithoutThinking.trimmingCharacters(in: .whitespacesAndNewlines)
        let maxLength = 160
        if trimmed.count > maxLength {
            let index = trimmed.index(trimmed.startIndex, offsetBy: maxLength)
            return String(trimmed[..<index]) + "…"
        }
        return trimmed
    }

}

struct PreviewPane: View {
    @ObservedObject var stateManager: PreviewStateManager
    @State private var isResizing = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("HTML Preview")
                    .font(.headline)
                Spacer()
                Button(action: { stateManager.hidePreview() }) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .frame(minWidth: 300)

            Divider()

            HTMLPreviewView(htmlContent: stateManager.previewContent)
        }
        .background(Color.clear)
        .gesture(
            DragGesture()
                .onChanged { gesture in
                    if !isResizing {
                        isResizing = true
                    }
                    let newWidth = max(300, stateManager.previewPaneWidth - gesture.translation.width)
                    stateManager.previewPaneWidth = min(800, newWidth)
                }
                .onEnded { _ in
                    isResizing = false
                }
        )
    }

}

private struct MainGlassBackground: View {
    let opacity: Double
    let blurLevel: Double

    var body: some View {
        ZStack {
            WindowVisualEffectView(
                material: .fullScreenUI,
                blendingMode: .behindWindow
            )
            .opacity(blurLevel / 10)

            Color(NSColor.windowBackgroundColor)
                .opacity(opacity / 100)
        }
    }
}

private struct WindowVisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        configure(view)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        configure(view)
    }

    private func configure(_ view: NSVisualEffectView) {
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
    }
}

struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            configure(window)
            self.window = window
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        configure(window)
        if self.window !== window {
            DispatchQueue.main.async { self.window = window }
        }
    }

    private func configure(_ window: NSWindow) {
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        window.isMovableByWindowBackground = false
        window.titleVisibility = .hidden
        window.contentView?.additionalSafeAreaInsets = NSEdgeInsets(top: -52, left: 0, bottom: 0, right: 0)
        window.titlebarSeparatorStyle = .none
        window.toolbar?.showsBaselineSeparator = false
    }
}
