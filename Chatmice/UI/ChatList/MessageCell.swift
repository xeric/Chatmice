//
//  MessageCell.swift
//  Chatmice
//
//  Created by Renat Notfullin on 25.03.2023.
//

import CoreData
import SwiftUI

struct MessageCell: View, Equatable {
    static func assistantDisplayName(personaName: String?, showAssistantNameInSidebar: Bool) -> String? {
        guard showAssistantNameInSidebar else {
            return nil
        }
        return personaName ?? "No assistant selected"
    }

    static func == (lhs: MessageCell, rhs: MessageCell) -> Bool {
        lhs.chatObjectID == rhs.chatObjectID &&
        lhs.timestamp == rhs.timestamp &&
        lhs.message == rhs.message &&
        lhs.showsAttentionIndicator == rhs.showsAttentionIndicator &&
        lhs.activitySnapshot == rhs.activitySnapshot &&
        lhs.$isActive.wrappedValue == rhs.$isActive.wrappedValue &&
        lhs.isPinned == rhs.isPinned &&
        lhs.searchText == rhs.searchText &&
        lhs.showAssistantNameInSidebar == rhs.showAssistantNameInSidebar
    }

    let chatObjectID: NSManagedObjectID
    let personaName: String?
    let chatName: String
    @State var timestamp: Date
    var message: String
    let showsAttentionIndicator: Bool
    let activitySnapshot: ChatActivitySnapshot?
    let isPinned: Bool
    @Binding var isActive: Bool
    let searchText: String
    @AppStorage("showAssistantNameInSidebar") private var showAssistantNameInSidebar: Bool = true
    @State private var isHovered = false
    @Environment(\.colorScheme) var colorScheme


    
    private var filteredMessage: String {
        let withoutToolActivity = ToolActivityRecord.removingMarkers(in: message)
        let withoutThinking = withoutToolActivity.replacingOccurrences(
            of: "<think>.*?</think>",
            with: "",
            options: .regularExpression
        )
        return withoutThinking
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Button {
            isActive = true
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    if let assistantDisplayName = MessageCell.assistantDisplayName(
                        personaName: personaName,
                        showAssistantNameInSidebar: showAssistantNameInSidebar
                    ) {
                        HighlightedText(assistantDisplayName, highlight: searchText, elementType: "chatlist")
                            .font(.caption)
                            .lineLimit(1)
                    }

                    if chatName != "" {
                        HighlightedText(chatName, highlight: searchText, elementType: "chatlist")
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    if filteredMessage != "" {
                        if message.starts(with: "<image-uuid>") {
                            Text("🖼️ Image")
                                .lineLimit(1)
                                .truncationMode(.tail)
                        } else {
                            HighlightedText(filteredMessage, highlight: searchText, elementType: "chatlist")
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
                .padding(8)
                Spacer()
                
                HStack(spacing: 6) {
                    if let activitySnapshot, activitySnapshot.phase.isActive {
                        SidebarActivityBadge(phase: activitySnapshot.phase)
                    } else if showsAttentionIndicator && !isActive {
                        ChatCompletionBadge()
                    }
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .foregroundColor(self.isActive ? .white : .gray)
                            .font(.caption)
                    }
                }
                .padding(.trailing, 8)
            }
            .frame(maxWidth: .infinity)
            .foregroundColor(self.isActive ? .white : .primary)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        self.isActive
                            ? Color.accentColor
                            : self.isHovered
                                ? (colorScheme == .dark ? Color(hex: "#666666")! : Color(hex: "#CCCCCC")!) : Color.clear
                    )
            )
            .onHover { hovering in
                isHovered = hovering
            }
        }
        .buttonStyle(.borderless)
        .background(Color.clear)
    }
}

struct MessageCell_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            previewCell(
                name: "Regular Chat",
                message: "Hello, how are you?",
                showsAttentionIndicator: false,
                isActive: false,
                isPinned: false
            )

            previewCell(
                name: "Selected Chat",
                message: "This is a selected chat preview",
                showsAttentionIndicator: false,
                isActive: true,
                isPinned: true
            )

            previewCell(
                name: "Long Message",
                message: "This is a very long message that should be truncated when displayed in the preview cell of our chat application",
                showsAttentionIndicator: true,
                isActive: false,
                isPinned: false
            )
        }
        .previewLayout(.fixed(width: 300, height: 100))
    }

    static func previewCell(
        name: String,
        message: String,
        showsAttentionIndicator: Bool,
        isActive: Bool,
        isPinned: Bool
    ) -> some View {
        let chat = createPreviewChat(name: name, isPinned: isPinned)
        return MessageCell(
            chatObjectID: chat.objectID,
            personaName: chat.persona?.name,
            chatName: chat.name,
            timestamp: Date(),
            message: message,
            showsAttentionIndicator: showsAttentionIndicator,
            activitySnapshot: nil,
            isPinned: isPinned,
            isActive: .constant(isActive),
            searchText: ""
        )
    }

    static func createPreviewChat(name: String, isPinned: Bool) -> ChatEntity {
        let context = PersistenceController.preview.container.viewContext
        let chat = ChatEntity(context: context)
        chat.id = UUID()
        chat.name = name
        chat.isPinned = isPinned
        chat.createdDate = Date()
        chat.updatedDate = Date()
        chat.systemMessage = AppConstants.chatGptSystemMessage
        chat.gptModel = AppConstants.defaultPrimaryModel
        chat.lastSequence = 0
        return chat
    }
}

private struct ChatCompletionBadge: View {
    var body: some View {
        Label("Done", systemImage: "checkmark")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.green)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.green.opacity(0.14), in: Capsule())
            .accessibilityLabel("New response completed")
    }
}

private struct SidebarActivityBadge: View {
    let phase: ChatActivityPhase

    var body: some View {
        HStack(spacing: 4) {
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.62)
                .frame(width: 10, height: 10)
            Text(phase.compactTitle)
                .lineLimit(1)
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.secondary.opacity(0.12), in: Capsule())
        .accessibilityLabel(phase.title)
    }
}
