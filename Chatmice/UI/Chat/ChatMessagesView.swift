//
//  ChatMessagesView.swift
//  Chatmice
//
//  Created by Renat Notfullin on 20.01.2025.
//

import CoreData
import SwiftUI

struct ChatScrollFollowState {
    private(set) var followsBottom = true

    mutating func followLatest() { followsBottom = true }
    mutating func detach() { followsBottom = false }

    mutating func phaseChanged(from oldPhase: ScrollPhase, to newPhase: ScrollPhase, distanceFromBottom: CGFloat) {
        switch newPhase {
        case .tracking, .interacting, .decelerating:
            followsBottom = false
        case .idle:
            if oldPhase == .tracking || oldPhase == .interacting || oldPhase == .decelerating {
                followsBottom = distanceFromBottom <= 24
            }
        case .animating:
            break
        @unknown default:
            break
        }
    }
}

// Scroll state changes must not reconstruct every historical message at the start of a wheel gesture.
private struct ChatMessageScrollView<Content: View>: View {
    let chatID: UUID
    let waitingForResponse: Bool
    let searchOccurrence: SearchOccurrence?
    let content: Content
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    @State private var scrollFollow = ChatScrollFollowState()

    private struct ScrollExtent: Equatable {
        let contentSize: CGSize
        let containerSize: CGSize
    }

    init(chatID: UUID, waitingForResponse: Bool, searchOccurrence: SearchOccurrence?, @ViewBuilder content: () -> Content) {
        self.chatID = chatID
        self.waitingForResponse = waitingForResponse
        self.searchOccurrence = searchOccurrence
        self.content = content()
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView { content }
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.bottom, for: .alignment)
                // Changing this trait on a wheel gesture invalidates the entire content layout.
                // Follow measured size changes instead; neither offsets nor wheel events trigger this callback.
                .defaultScrollAnchor(nil, for: .sizeChanges)
                .scrollPosition($scrollPosition)
                .onScrollGeometryChange(for: ScrollExtent.self, of: {
                    ScrollExtent(contentSize: $0.contentSize, containerSize: $0.containerSize)
                }) { _, _ in
                    if scrollFollow.followsBottom { scrollPosition.scrollTo(edge: .bottom) }
                }
                .onScrollPhaseChange { oldPhase, newPhase, context in
                    var intent = scrollFollow
                    intent.phaseChanged(
                        from: oldPhase, to: newPhase,
                        distanceFromBottom: context.geometry.contentSize.height - context.geometry.visibleRect.maxY
                    )
                    if intent.followsBottom != scrollFollow.followsBottom { scrollFollow = intent }
                }
                .onChange(of: searchOccurrence) { _, occurrence in
                    guard let occurrence else { return }
                    scrollFollow.detach()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        let messageID = occurrence.messageID.uriRepresentation().absoluteString
                        proxy.scrollTo("\(messageID)_element_\(occurrence.elementIndex)", anchor: .center)
                    }
                }
                .onChange(of: waitingForResponse) { _, waiting in
                    if waiting {
                        scrollFollow.followLatest()
                        scrollPosition.scrollTo(edge: .bottom)
                    }
                }
                .onChange(of: chatID) {
                    scrollFollow.followLatest()
                    scrollPosition.scrollTo(edge: .bottom)
                }
        }
        .padding(.bottom, 6)
    }
}

struct ChatMessagesView: View {
    @ObservedObject var chat: ChatEntity
    @ObservedObject var chatViewModel: ChatViewModel
    let inputBuffer: ChatInputBuffer
    @Binding var editSystemMessage: Bool
    @Binding var isStreaming: Bool
    @Binding var currentError: ErrorMessage?
    @Binding var searchText: String
    let reasoningDurations: [NSManagedObjectID: TimeInterval]
    let activeReasoningMessageID: NSManagedObjectID?
    @ObservedObject private var activityStore = ChatActivityStore.shared
    @ObservedObject private var streamingResponseStore = StreamingResponseStore.shared


    private var liveResponse: String? {
        streamingResponseStore.responses[chat.id]
    }

    private var activitySnapshot: ChatActivitySnapshot? {
        activityStore.activeSnapshot(for: chat.id)
    }

    private var displayedError: ErrorMessage? {
        if let currentError { return currentError }
        guard let snapshot = activityStore.snapshot(for: chat.id),
            case .failed(let message) = snapshot.phase
        else { return nil }
        return ErrorMessage(type: .serverError(message), timestamp: snapshot.updatedAt)
    }

    private var activityAnchorID: String {
        "chat-activity-\(chat.id.uuidString)"
    }

    private var errorAnchorID: String {
        "chat-error-\(chat.id.uuidString)"
    }

    var body: some View {
        ChatMessageScrollView(chatID: chat.id, waitingForResponse: chat.waitingForResponse,
                              searchOccurrence: chatViewModel.currentSearchOccurrence) {
            VStack {
                    SystemMessageBubbleView(
                        message: chat.systemMessage,
                        color: chat.persona?.color,
                        inputBuffer: inputBuffer,
                        editSystemMessage: $editSystemMessage,
                        searchText: $searchText
                    )
                    .id("system_message")

                    if !chatViewModel.sortedMessages.isEmpty {
                        ForEach(chatViewModel.sortedMessages, id: \.objectID) { messageEntity in
                            let isLatest = messageEntity.objectID == chatViewModel.sortedMessages.last?.objectID
                            let isActiveAssistant = isLatest && !messageEntity.own && activitySnapshot != nil
                            let storedDuration =
                                messageEntity.reasoningDuration > 0 ? messageEntity.reasoningDuration : nil
                            let displayedMessage =
                                isLatest && !messageEntity.own
                                ? (liveResponse ?? messageEntity.body)
                                : messageEntity.body
                            let bubbleContent = ChatBubbleContent(
                                message: displayedMessage,
                                own: messageEntity.own,
                                waitingForResponse: messageEntity.waitingForResponse,
                                errorMessage: nil,
                                systemMessage: false,
                                isStreaming: isStreaming && isLatest && !messageEntity.own,
                                isLatestMessage: isLatest,
                                reasoningDuration: reasoningDurations[messageEntity.objectID] ?? storedDuration,
                                isActiveReasoning: messageEntity.objectID == activeReasoningMessageID
                            )
                            ChatBubbleView(
                                content: bubbleContent,
                                message: messageEntity,
                                searchText: $searchText,
                                currentSearchOccurrence: chatViewModel.currentSearchOccurrence,
                                activitySnapshot: isActiveAssistant ? activitySnapshot : nil
                            )
                            .id(messageEntity.objectID)
                        }
                    }

                    if chatViewModel.sortedMessages.last?.own != false, let activitySnapshot {
                        AssistantTurnActivityView(snapshot: activitySnapshot)
                            .id(activityAnchorID)
                    }
                    if let error = displayedError {
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

                        ChatBubbleView(
                            content: bubbleContent,
                            retryChatID: chat.id,
                            searchText: $searchText
                        )
                        .id(errorAnchorID)
                    }

                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
                .background(ThinScrollbarConfiguration().allowsHitTesting(false))
        }
    }



}


struct AssistantTurnActivityView: View {
    let snapshot: ChatActivitySnapshot

    @ViewBuilder
    var body: some View {
        switch snapshot.phase {
        case .awaitingApproval(let tool, let detail):
            ToolActivityView(name: tool, input: detail, state: .awaitingApproval)
        case .runningTool(let tool, let detail):
            ToolActivityView(name: tool, input: detail, state: .running)
        default:
            ChatActivityIndicatorView(snapshot: snapshot)
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
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            Canvas { graphics, size in
                let time = context.date.timeIntervalSinceReferenceDate
                let barWidth: CGFloat = 2
                let spacing: CGFloat = 2
                let totalWidth = barWidth * 3 + spacing * 2
                let startX = (size.width - totalWidth) / 2

                for index in 0..<3 {
                    let wave = (sin(time * 4.5 + Double(index) * 1.1) + 1) / 2
                    let height = 5 + CGFloat(wave) * 9
                    let rect = CGRect(
                        x: startX + CGFloat(index) * (barWidth + spacing),
                        y: (size.height - height) / 2,
                        width: barWidth,
                        height: height
                    )
                    graphics.fill(
                        Path(roundedRect: rect, cornerRadius: barWidth / 2),
                        with: .color(color.opacity(0.82))
                    )
                }
            }
            .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
    }
}
