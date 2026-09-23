//
//  ChatMessagesView.swift
//  macai
//
//  Created by Renat Notfullin on 20.01.2025.
//

import CoreData
import SwiftUI

struct ChatMessagesView: View {
    @ObservedObject var chat: ChatEntity
    @ObservedObject var chatViewModel: ChatViewModel
    @Binding var newMessage: String
    @Binding var editSystemMessage: Bool
    @Binding var isStreaming: Bool
    @Binding var currentError: ErrorMessage?
    @Binding var userIsScrolling: Bool
    @Binding var searchText: String
    let reasoningDurations: [NSManagedObjectID: TimeInterval]
    let activeReasoningMessageID: NSManagedObjectID?
    @State private var scrollDebounceWorkItem: DispatchWorkItem?
    @State private var codeBlocksRendered = false
    @State private var pendingCodeBlocks = 0
    @State private var isInitialLoad = true
    @ObservedObject private var activityStore = ChatActivityStore.shared
    

    private var activitySnapshot: ChatActivitySnapshot? {
        activityStore.activeSnapshot(for: chat.id)
    }

    private var activeActivity: ChatActivitySnapshot? {
        guard let snapshot = activitySnapshot, snapshot.phase.showsInlineIndicator else { return nil }
        return snapshot
    }

    private var activeToolActivity: ChatActivitySnapshot? {
        guard let snapshot = activitySnapshot, snapshot.phase.showsStandaloneToolCard else { return nil }
        return snapshot
    }

    private var activityAnchorID: String {
        "chat-activity-\(chat.id.uuidString)"
    }
    
    var body: some View {
        ScrollView {
            ScrollViewReader { scrollView in
                VStack {
                    SystemMessageBubbleView(
                        message: chat.systemMessage,
                        color: chat.persona?.color,
                        newMessage: $newMessage,
                        editSystemMessage: $editSystemMessage,
                        searchText: $searchText
                    )
                    .id("system_message")

                    if !chatViewModel.sortedMessages.isEmpty {
                        ForEach(chatViewModel.sortedMessages, id: \.objectID) { messageEntity in
                            let storedDuration = messageEntity.reasoningDuration > 0 ? messageEntity.reasoningDuration : nil
                            let bubbleContent = ChatBubbleContent(
                                message: messageEntity.body,
                                own: messageEntity.own,
                                waitingForResponse: messageEntity.waitingForResponse,
                                errorMessage: nil,
                                systemMessage: false,
                                isStreaming: isStreaming,
                                isLatestMessage: messageEntity.objectID == chatViewModel.sortedMessages.last?.objectID,
                                reasoningDuration: reasoningDurations[messageEntity.objectID] ?? storedDuration,
                                isActiveReasoning: messageEntity.objectID == activeReasoningMessageID
                            )
                            ChatBubbleView(content: bubbleContent, message: messageEntity, searchText: $searchText, currentSearchOccurrence: chatViewModel.currentSearchOccurrence)
                                .id(messageEntity.objectID)
                        }
                    }

                    if let activeToolActivity {
                        ActiveToolActivityView(snapshot: activeToolActivity)
                            .id(activityAnchorID)
                    }
                    else if let activeActivity {
                        ChatActivityIndicatorView(snapshot: activeActivity)
                            .id(activityAnchorID)
                    }
                    else if let error = currentError {
                        let bubbleContent = ChatBubbleContent(
                            message: "",
                            own: false,
                            waitingForResponse: false,
                            errorMessage: error,
                            systemMessage: false,
                            isStreaming: isStreaming,
                            isLatestMessage: true,
                            reasoningDuration: nil,
                            isActiveReasoning: false
                        )

                        ChatBubbleView(content: bubbleContent, searchText: $searchText)
                            .id(-2)
                    }
                }
                .padding(24)
                .onAppear {
                    pendingCodeBlocks = chatViewModel.sortedMessages.reduce(0) { count, message in
                        count + (message.body.components(separatedBy: "```").count - 1) / 2
                    }
                    isInitialLoad = true

                    if pendingCodeBlocks == 0 {
                        codeBlocksRendered = true
                        isInitialLoad = false
                    }
                }
                .onSwipe { event in
                    switch event.direction {
                    case .up:
                        userIsScrolling = true
                    case .none, .down, .left, .right:
                        break
                    }
                }
                .onChange(of: chat.lastMessage?.body) { _ in
                    if isStreaming && !userIsScrolling {
                        scrollDebounceWorkItem?.cancel()

                        let workItem = DispatchWorkItem {
                            withAnimation(.easeOut(duration: 0.22)) {
                                if activitySnapshot != nil {
                                    scrollView.scrollTo(activityAnchorID, anchor: .bottom)
                                } else if let lastMessage = chatViewModel.sortedMessages.last {
                                    scrollView.scrollTo(lastMessage.objectID, anchor: .bottom)
                                }
                            }
                        }

                        scrollDebounceWorkItem = workItem
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
                    }
                }
                .onChange(of: activitySnapshot?.phase) { phase in
                    guard phase != nil, !userIsScrolling else { return }
                    withAnimation(.easeOut(duration: 0.22)) {
                        scrollView.scrollTo(activityAnchorID, anchor: .bottom)
                    }
                }
                .onChange(of: chatViewModel.sortedMessages.count) { _ in
                    if activitySnapshot != nil {
                        withAnimation {
                            scrollView.scrollTo(activityAnchorID, anchor: .bottom)
                        }
                    } else if currentError != nil {
                        withAnimation {
                            scrollView.scrollTo(-2, anchor: .bottom)
                        }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("NonStreamingMessageCompleted"))) { notification in
                    if let notificationChat = notification.object as? ChatEntity, notificationChat == chat {
                        DispatchQueue.main.async {
                            if !isStreaming && !userIsScrolling {
                                let sortedMessages = chatViewModel.sortedMessages
                                if let lastMessage = sortedMessages.last {
                                    withAnimation(.easeOut(duration: 0.5)) {
                                        scrollView.scrollTo(lastMessage.objectID, anchor: .bottom)
                                    }
                                }
                            }
                        }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CodeBlockRendered"))) { _ in
                    if pendingCodeBlocks > 0 {
                        pendingCodeBlocks -= 1
                        if pendingCodeBlocks == 0 {
                            codeBlocksRendered = true
                            if isInitialLoad {
                                isInitialLoad = false
                                if let lastMessage = chatViewModel.sortedMessages.last {
                                    DispatchQueue.main.async {
                                        scrollView.scrollTo(lastMessage.objectID, anchor: .bottom)
                                    }
                                }
                            }
                        }
                    }
                }
                .onChange(of: chatViewModel.currentSearchOccurrence) { newOccurrence in
                    if let occurrence = newOccurrence {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            // Generate element ID for the occurrence
                            let messageIDString = occurrence.messageID.uriRepresentation().absoluteString
                            let elementID = "\(messageIDString)_element_\(occurrence.elementIndex)"
                            scrollView.scrollTo(elementID, anchor: .center)
                        }
                    }
                }
            }
            .id("chatContainer")
        }
        .defaultScrollAnchor(.bottom)
        .padding(.bottom, 6)
    }
}

private extension ChatActivityPhase {
    var showsInlineIndicator: Bool {
        !showsStandaloneToolCard
    }

    var showsStandaloneToolCard: Bool {
        switch self {
        case .awaitingApproval, .runningTool:
            return true
        default:
            return false
        }
    }
}

private struct ActiveToolActivityView: View {
    let snapshot: ChatActivitySnapshot

    @ViewBuilder
    var body: some View {
        switch snapshot.phase {
        case .awaitingApproval(let tool, let detail):
            ToolActivityView(name: tool, input: detail, state: .awaitingApproval)
        case .runningTool(let tool, let detail):
            ToolActivityView(name: tool, input: detail, state: .running)
        default:
            EmptyView()
        }
    }
}


private struct ChatActivityIndicatorView: View {
    let snapshot: ChatActivitySnapshot

    private var accent: Color {
        switch snapshot.phase {
        case .awaitingApproval:
            return .orange
        case .runningTool:
            return .purple
        case .processingToolResult:
            return .cyan
        case .failed:
            return .red
        default:
            return .accentColor
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 7) {
            ActivityWave(color: accent)
                .frame(width: 22, height: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(snapshot.phase.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)

                if let detail = snapshot.phase.detail, !detail.isEmpty {
                    Text(cleanDetail(detail))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 6)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(elapsedText(at: context.date))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(maxWidth: 360, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(accent.opacity(0.24), lineWidth: 0.75)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.15), value: snapshot.phase)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(snapshot.phase.title)
    }

    private func cleanDetail(_ detail: String) -> String {
        detail
            .replacingOccurrences(of: "Execute command:\n", with: "")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private func elapsedText(at date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(snapshot.startedAt)))
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }
}

private struct ActivityWave: View {
    let color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.22)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<3, id: \.self) { index in
                    let wave = (sin(time * 4.5 + Double(index) * 1.1) + 1) / 2
                    Capsule()
                        .fill(color.opacity(0.82))
                        .frame(width: 2, height: 5 + wave * 9)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
    }
}
