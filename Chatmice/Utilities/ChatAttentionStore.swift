//
//  ChatAttentionStore.swift
//  Chatmice
//
//  Event-driven chat activity and completion attention state.
//

import AppKit
import Combine
import Foundation

enum ChatActivityPhase: Equatable, Sendable {
    case preparing
    case waitingForModel
    case awaitingApproval(tool: String, detail: String)
    case runningTool(tool: String, detail: String)
    case processingToolResult(tool: String)
    case streamingResponse
    case completed
    case failed(message: String)

    var isActive: Bool {
        switch self {
        case .preparing, .waitingForModel, .awaitingApproval, .runningTool, .processingToolResult, .streamingResponse:
            return true
        case .completed, .failed:
            return false
        }
    }

    var title: String {
        switch self {
        case .preparing: return "Preparing request"
        case .waitingForModel: return "Waiting for model"
        case .awaitingApproval(let tool, _): return "Waiting to run \(tool)"
        case .runningTool(let tool, _): return "Running \(tool)"
        case .processingToolResult: return "Reviewing tool result"
        case .streamingResponse: return "Writing response"
        case .completed: return "Response complete"
        case .failed: return "Response failed"
        }
    }

    var compactTitle: String {
        switch self {
        case .preparing: return "Preparing"
        case .waitingForModel: return "Thinking"
        case .awaitingApproval: return "Approval"
        case .runningTool(let tool, _): return tool
        case .processingToolResult: return "Reviewing"
        case .streamingResponse: return "Writing"
        case .completed: return "Done"
        case .failed: return "Failed"
        }
    }

    var detail: String? {
        switch self {
        case .awaitingApproval(_, let detail), .runningTool(_, let detail):
            return detail
        case .processingToolResult(let tool):
            return "Using the output from \(tool)"
        case .preparing:
            return "Collecting conversation context"
        case .waitingForModel:
            return "The model is processing your request"
        case .streamingResponse:
            return "Receiving the answer"
        case .failed(let message):
            return message
        case .completed:
            return nil
        }
    }

    var symbolName: String {
        switch self {
        case .preparing: return "slider.horizontal.3"
        case .waitingForModel: return "brain.head.profile"
        case .awaitingApproval: return "hand.raised.fill"
        case .runningTool: return "terminal.fill"
        case .processingToolResult: return "arrow.triangle.2.circlepath"
        case .streamingResponse: return "text.append"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }
}

struct ChatActivitySnapshot: Equatable, Sendable, Identifiable {
    let chatId: UUID
    var phase: ChatActivityPhase
    let startedAt: Date
    var updatedAt: Date

    var id: UUID { chatId }
}

enum ChatActivityEventKind: Equatable, Sendable {
    case started
    case waitingForModel
    case awaitingApproval(tool: String, detail: String)
    case runningTool(tool: String, detail: String)
    case processingToolResult(tool: String)
    case streamingResponse
    case completed
    case failed(message: String)
    case cancelled
}

struct ChatActivityEvent: Equatable, Sendable {
    let chatId: UUID
    let kind: ChatActivityEventKind
    let timestamp: Date

    init(chatId: UUID, kind: ChatActivityEventKind, timestamp: Date = Date()) {
        self.chatId = chatId
        self.kind = kind
        self.timestamp = timestamp
    }
}

enum ChatActivityEvents {
    static let notification = Notification.Name("ChatActivityEvent")

    static func post(_ event: ChatActivityEvent) {
        NotificationCenter.default.post(name: notification, object: event)
    }
}

@MainActor
final class ChatActivityStore: ObservableObject {
    static let shared = ChatActivityStore()

    @Published private(set) var snapshots: [UUID: ChatActivitySnapshot] = [:]
    @Published private(set) var attentionChatIds: Set<UUID> = []

    private let storageKey = "ChatAttentionStore.chatIds"
    private var focusedChatId: UUID?
    private var applicationIsActive = true
    private var eventObserver: NSObjectProtocol?

    private init() {
        loadAttention()
        eventObserver = NotificationCenter.default.addObserver(
            forName: ChatActivityEvents.notification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let event = notification.object as? ChatActivityEvent else { return }
            Task { @MainActor in
                self?.apply(event)
            }
        }
    }

    func snapshot(for chatId: UUID) -> ChatActivitySnapshot? {
        snapshots[chatId]
    }

    func activeSnapshot(for chatId: UUID) -> ChatActivitySnapshot? {
        guard let snapshot = snapshots[chatId], snapshot.phase.isActive else { return nil }
        return snapshot
    }

    func contains(_ chatId: UUID) -> Bool {
        attentionChatIds.contains(chatId)
    }

    func updatePresentationContext(focusedChatId: UUID?, applicationIsActive: Bool) {
        self.focusedChatId = focusedChatId
        self.applicationIsActive = applicationIsActive
        if applicationIsActive, let focusedChatId {
            clear(focusedChatId)
        }
    }

    func clear(_ chatId: UUID) {
        guard attentionChatIds.remove(chatId) != nil else { return }
        persistAttention()
        updateDockBadge()
    }

    private func apply(_ event: ChatActivityEvent) {
        guard let phase = phase(for: event.kind) else {
            snapshots[event.chatId] = nil
            return
        }

        let startedAt = event.kind == .started
            ? event.timestamp
            : (snapshots[event.chatId]?.startedAt ?? event.timestamp)
        snapshots[event.chatId] = ChatActivitySnapshot(
            chatId: event.chatId,
            phase: phase,
            startedAt: startedAt,
            updatedAt: event.timestamp
        )

        switch event.kind {
        case .completed, .failed:
            if applicationIsActive, focusedChatId == event.chatId {
                clear(event.chatId)
            } else {
                markForAttention(event.chatId)
            }
        default:
            break
        }
    }

    private func phase(for kind: ChatActivityEventKind) -> ChatActivityPhase? {
        switch kind {
        case .started: return .preparing
        case .waitingForModel: return .waitingForModel
        case .awaitingApproval(let tool, let detail): return .awaitingApproval(tool: tool, detail: detail)
        case .runningTool(let tool, let detail): return .runningTool(tool: tool, detail: detail)
        case .processingToolResult(let tool): return .processingToolResult(tool: tool)
        case .streamingResponse: return .streamingResponse
        case .completed: return .completed
        case .failed(let message): return .failed(message: message)
        case .cancelled: return nil
        }
    }

    private func markForAttention(_ chatId: UUID) {
        guard attentionChatIds.insert(chatId).inserted else { return }
        persistAttention()
        updateDockBadge()
    }

    private func loadAttention() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let ids = try? JSONDecoder().decode([UUID].self, from: data)
        else { return }
        attentionChatIds = Set(ids)
        updateDockBadge()
    }

    private func persistAttention() {
        guard let data = try? JSONEncoder().encode(Array(attentionChatIds)) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private func updateDockBadge() {
        let badge = attentionChatIds.isEmpty ? nil : "\(attentionChatIds.count)"
        NSApplication.shared.dockTile.showsApplicationBadge = true
        NSApplication.shared.dockTile.badgeLabel = badge
        NSApplication.shared.dockTile.display()
    }
}
