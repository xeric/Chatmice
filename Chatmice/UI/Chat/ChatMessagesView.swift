//
//  ChatMessagesView.swift
//  Chatmice
//
//  Created by Renat Notfullin on 20.01.2025.
//

import CoreData
import SwiftUI

struct ChatMessagesView: View {
    @ObservedObject var chat: ChatEntity
    @ObservedObject var chatViewModel: ChatViewModel
    let inputBuffer: ChatInputBuffer
    @Binding var editSystemMessage: Bool
    @Binding var isStreaming: Bool
    @Binding var currentError: ErrorMessage?
    @Binding var userIsScrolling: Bool
    @Binding var searchText: String
    let reasoningDurations: [NSManagedObjectID: TimeInterval]
    let activeReasoningMessageID: NSManagedObjectID?
    @ObservedObject private var activityStore = ChatActivityStore.shared
    @ObservedObject private var streamingResponseStore = StreamingResponseStore.shared
    @State private var scrollPosition = ScrollPosition(edge: .bottom)


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
        ScrollView {
            LazyVStack {
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
                .padding(24)
                .onChange(of: chatViewModel.currentSearchOccurrence) { _, newOccurrence in
                    if let occurrence = newOccurrence {
                        userIsScrolling = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            let messageIDString = occurrence.messageID.uriRepresentation().absoluteString
                            let elementID = "\(messageIDString)_element_\(occurrence.elementIndex)"
                            scrollPosition.scrollTo(id: elementID, anchor: .center)
                        }
                    }
                }
        }
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .alignment)
        .defaultScrollAnchor(userIsScrolling ? nil : .bottom, for: .sizeChanges)
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentSize.height - geometry.visibleRect.maxY > 24
        } action: { _, isDetachedFromBottom in
            if userIsScrolling != isDetachedFromBottom {
                userIsScrolling = isDetachedFromBottom
            }
        }
        .padding(.bottom, 6)
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
