//
//  ChatListRow.swift
//  Chatmice
//
//  Created by Renat on 17.11.2024.
//

import CoreData
import Foundation
import SwiftUI

struct SidebarConversationPresentation: Equatable {
    static let untitledName = "Untitled"
    static let untitledColor = "#007AFF"
    static let untitledSymbol = "bubble.left.fill"

    let title: String
    let color: String?
    let symbolName: String?
    let overlaySymbolName: String?
    let timestamp: Date
    let preview: String
    let isImagePreview: Bool
    let isPinned: Bool

    init(
        chatName: String,
        personaColor: String?,
        personaSymbolName: String?,
        personaOverlaySymbolName: String?,
        timestamp: Date = .distantPast,
        preview: String = "",
        isImagePreview: Bool = false,
        isPinned: Bool = false
    ) {
        self.timestamp = timestamp
        self.preview = preview
        self.isImagePreview = isImagePreview
        self.isPinned = isPinned
        let trimmedName = chatName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty {
            title = Self.untitledName
            color = Self.untitledColor
            symbolName = Self.untitledSymbol
            overlaySymbolName = nil
        }
        else {
            title = trimmedName
            color = personaColor
            symbolName = PersonaAppearance.validatedSymbol(personaSymbolName, fallback: PersonaAppearance.defaultSymbol)
            overlaySymbolName = personaOverlaySymbolName.flatMap {
                let normalized = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                return PersonaAppearance.isValidSymbol(normalized) ? normalized : nil
            }
        }
    }
}

struct ChatListRow: View {
    let chat: ChatEntity
    let presentation: SidebarConversationPresentation
    let showsAttentionIndicator: Bool
    let activitySnapshot: ChatActivitySnapshot?
    @Binding var selectedChat: ChatEntity?
    let viewContext: NSManagedObjectContext
    let searchText: String
    @StateObject private var chatViewModel: ChatViewModel

    init(
        chat: ChatEntity,
        presentation: SidebarConversationPresentation,
        showsAttentionIndicator: Bool,
        activitySnapshot: ChatActivitySnapshot?,
        selectedChat: Binding<ChatEntity?>,
        viewContext: NSManagedObjectContext,
        searchText: String
    ) {
        self.chat = chat
        self.presentation = presentation
        self.showsAttentionIndicator = showsAttentionIndicator
        self.activitySnapshot = activitySnapshot
        self._selectedChat = selectedChat
        self.viewContext = viewContext
        self.searchText = searchText
        self._chatViewModel = StateObject(
            wrappedValue: ChatViewModel(chat: chat, viewContext: viewContext, loadsMessages: false)
        )
    }


    var body: some View {
        MessageCell(
            chatObjectID: chat.objectID,
            presentation: presentation,
            showsAttentionIndicator: showsAttentionIndicator,
            activitySnapshot: activitySnapshot,
            isActive: selectedChat?.objectID == chat.objectID,
            searchText: searchText,
            onSelect: { selectedChat = chat }
        )
        .equatable()
        .contextMenu {
            Button(action: { 
                togglePinChat(chat)
            }) {
                Label(presentation.isPinned ? "Unpin" : "Pin", systemImage: presentation.isPinned ? "pin.slash" : "pin")
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            
            Button(action: { renameChat(chat) }) {
                Label("Rename", systemImage: "pencil")
            }
            .keyboardShortcut(.return, modifiers: [])
            if chat.apiService?.generateChatNames ?? false {
                Button(action: {
                    chatViewModel.regenerateChatName()
                }) {
                    Label("Regenerate Name", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
            Button(action: { clearChat(chat) }) {
                Label("Clear Chat", systemImage: "eraser")
            }
            .keyboardShortcut(.delete, modifiers: [.command, .shift])
            Divider()
            Button(action: { deleteChat(chat) }) {
                Label("Delete", systemImage: "trash")
            }
            .keyboardShortcut(.delete, modifiers: [.command])
        }
    }

    func deleteChat(_ chat: ChatEntity) {
        guard !chat.isDeleted else { return }
        let alert = NSAlert()
        alert.messageText = "Delete chat \(chat.name)?"
        alert.informativeText = "Are you sure you want to delete this chat?"
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: NSApp.keyWindow!) { response in
            if response == .alertFirstButtonReturn {
                // Clear selectedChat to prevent accessing deleted item
                if selectedChat?.objectID == chat.objectID {
                    selectedChat = nil
                }
                viewContext.delete(chat)
                DispatchQueue.main.async {
                    do {
                        try viewContext.save()
                    }
                    catch {
                        print("Error deleting chat: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    func renameChat(_ chat: ChatEntity) {
        let alert = NSAlert()
        alert.messageText = "Rename chat"
        alert.informativeText = "Enter new name for this chat"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .informational
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        textField.stringValue = chat.name
        alert.accessoryView = textField
        alert.beginSheetModal(for: NSApp.keyWindow!) { response in
            if response == .alertFirstButtonReturn {
                chat.name = textField.stringValue
                do {
                    try viewContext.save()
                }

                catch {
                    print("Error renaming chat: \(error.localizedDescription)")
                }
            }
        }
    }
    
    func clearChat(_ chat: ChatEntity) {
        let alert = NSAlert()
        alert.messageText = "Clear chat \(chat.name)?"
        alert.informativeText = "Are you sure you want to delete all messages from this chat? Chat parameters will not be deleted. This action cannot be undone."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: NSApp.keyWindow!) { response in
            if response == .alertFirstButtonReturn {
                chat.clearMessages()
                do {
                    try viewContext.save()
                } catch {
                    print("Error clearing chat: \(error.localizedDescription)")
                }
            }
        }
    }
    
    func togglePinChat(_ chat: ChatEntity) {
        chat.isPinned.toggle()
        do {
            try viewContext.save()
        } catch {
            print("Error toggling pin status: \(error.localizedDescription)")
        }
    }
}
