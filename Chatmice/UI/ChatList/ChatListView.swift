//
//  ChatListView.swift
//  Chatmice
//
//  Created by Renat on 17.11.2024.
//

import CoreData
import SwiftUI
import UniformTypeIdentifiers

struct ChatListView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @EnvironmentObject private var activityStore: ChatActivityStore
    @State private var scrollOffset: CGFloat = 0
    @State private var previousOffset: CGFloat = 0
    @State private var debouncedSearchText: String = ""
    @State private var debounceTimer: Timer?
    @State private var expandedWorkspaceIDs = Set<UUID>()
    @State private var draggedWorkspaceID: UUID?
    @State private var workspaceDropTarget: (id: UUID, before: Bool)?
    @State private var editingWorkspace: WorkspaceEntity?
    @State private var deletingWorkspace: WorkspaceEntity?
    @State private var workspaceError: String?

    @FetchRequest(
        entity: WorkspaceEntity.entity(),
        sortDescriptors: [
            NSSortDescriptor(keyPath: \WorkspaceEntity.sortOrder, ascending: true)
        ],
        animation: .default
    )
    private var workspaces: FetchedResults<WorkspaceEntity>

    @FetchRequest(
        entity: ChatEntity.entity(),
        sortDescriptors: [
            NSSortDescriptor(keyPath: \ChatEntity.isPinned, ascending: false),
            NSSortDescriptor(keyPath: \ChatEntity.updatedDate, ascending: false)
        ],
        animation: .default
    )
    private var chats: FetchedResults<ChatEntity>

    @Binding var selectedChat: ChatEntity?
    @Binding var searchText: String
    let onNewChat: (WorkspaceEntity) -> Void

    private var filteredChats: [ChatEntity] {
        if debouncedSearchText.isEmpty {
            return Array(chats)
        } else {
            return chats.filter { chat in
                // Check chat name first (most likely match)
                if chat.name.localizedCaseInsensitiveContains(debouncedSearchText) {
                    return true
                }
                
                // Check persona name
                if let personaName = chat.persona?.name,
                   personaName.localizedCaseInsensitiveContains(debouncedSearchText) {
                    return true
                }
                
                // Use a Core Data fetch with predicate for message search
                // This is more efficient than iterating through messagesArray
                // because Core Data can use indexes and limit results
                guard let context = chat.managedObjectContext else {
                    return false
                }
                
                let fetchRequest = NSFetchRequest<MessageEntity>(entityName: "MessageEntity")
                fetchRequest.predicate = NSPredicate(
                    format: "chat == %@ AND body CONTAINS[cd] %@",
                    chat, debouncedSearchText
                )
                
                let count = (try? context.count(for: fetchRequest)) ?? 0
                return count > 0
            }.sorted { first, second in
                if first.isPinned != second.isPinned {
                    return first.isPinned && !second.isPinned
                }
                return (first.updatedDate ?? .distantPast) > (second.updatedDate ?? .distantPast)
            }
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(workspaces, id: \.objectID) { workspace in
                        workspaceSection(workspace)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 12)
            }
            .contentMargins(.top, -8, for: .scrollIndicators)
        }
        .onChange(of: searchText) { _, newValue in
            debounceTimer?.invalidate()

            debounceTimer = Timer.scheduledTimer(withTimeInterval: AppConstants.searchDebounceTime, repeats: false) {
                _ in
                debouncedSearchText = newValue
            }
        }
        .onChange(of: workspaces.count) {
            expandedWorkspaceIDs.formUnion(workspaces.map(\.id))
        }
        .onChange(of: selectedChat?.id) {
            if let workspaceID = selectedChat?.workspace?.id {
                expandedWorkspaceIDs.insert(workspaceID)
            }
        }
        .onAppear {
            debouncedSearchText = searchText
            expandedWorkspaceIDs.formUnion(workspaces.map(\.id))
        }
        .onDisappear {
            debounceTimer?.invalidate()
            draggedWorkspaceID = nil
            workspaceDropTarget = nil
        }
        .sheet(item: $editingWorkspace) { workspace in
            WorkspaceCreationView(workspace: workspace) { _ in }
        }
        .confirmationDialog(
            "Delete Workspace?",
            isPresented: Binding(get: { deletingWorkspace != nil }, set: { if !$0 { deletingWorkspace = nil } }),
            titleVisibility: .visible,
            presenting: deletingWorkspace
        ) { workspace in
            Button("Delete Workspace and Chats", role: .destructive) {
                do {
                    let clearsSelection = selectedChat?.workspace == workspace
                    let deletedChatIDs = (workspace.chats as? Set<ChatEntity> ?? []).map(\.id)
                    let temporary = try WorkspaceManager.remove(workspace, in: viewContext)
                    if clearsSelection {
                        selectedChat = nil
                    }
                    for chatID in deletedChatIDs {
                        activityStore.clear(chatID)
                    }
                    expandedWorkspaceIDs.insert(temporary.id)
                } catch {
                    workspaceError = error.localizedDescription
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { workspace in
            Text("Delete \"\(workspace.name)\" and all chats in it? Files and folders on disk will not be deleted.")
        }
        .alert("Workspace Error", isPresented: Binding(
            get: { workspaceError != nil },
            set: { if !$0 { workspaceError = nil } }
        )) {
            Button("OK", role: .cancel) { workspaceError = nil }
        } message: {
            Text(workspaceError ?? "")
        }
    }

    private func workspaceDragLabel(_ workspace: WorkspaceEntity) -> some View {
        HStack(spacing: 7) {
            Image(systemName: expandedWorkspaceIDs.contains(workspace.id) ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 10)
            Image(systemName: workspace.isTemporary ? "clock" : "folder")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(workspace.name)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func workspaceSection(_ workspace: WorkspaceEntity) -> some View {
        let workspaceChats = filteredChats.filter { $0.workspace?.objectID == workspace.objectID }
        VStack(alignment: .leading, spacing: 5) {
            if workspaceDropTarget?.id == workspace.id, workspaceDropTarget?.before == true {
                ReorderDropPlaceholder()
            }
            HStack(spacing: 7) {
                Button {
                    toggleWorkspace(workspace)
                } label: {
                    workspaceDragLabel(workspace)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Toggle \(workspace.name)")
                .overlay {
                    ReorderDragSource(
                        payload: { workspace.id.uuidString },
                        preview: workspaceDragLabel(workspace),
                        onStarted: { draggedWorkspaceID = workspace.id },
                        onEnded: {
                            if draggedWorkspaceID == workspace.id {
                                draggedWorkspaceID = nil
                                workspaceDropTarget = nil
                            }
                        },
                        onClick: { _ in toggleWorkspace(workspace) }
                    )
                }

                Spacer(minLength: 4)

                Button {
                    onNewChat(workspace)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("New Chat in \(workspace.name)")
                .accessibilityLabel("New Chat in \(workspace.name)")

                if !workspace.isTemporary {
                    Menu {
                        Button("Edit…", systemImage: "pencil") { editingWorkspace = workspace }
                        Button("Delete…", systemImage: "trash", role: .destructive) { deletingWorkspace = workspace }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Edit or delete \(workspace.name)")
                    .accessibilityLabel("Workspace options for \(workspace.name)")
                }
            }
            .contentShape(Rectangle())
            .help(workspace.path)

            if expandedWorkspaceIDs.contains(workspace.id) {
                if workspaceChats.isEmpty {
                    Text(debouncedSearchText.isEmpty ? "No chats" : "No matches")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 30)
                        .padding(.vertical, 4)
                } else {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(workspaceChats, id: \.objectID) { chat in
                            ChatListRow(
                                chat: chat,
                                showsAttentionIndicator: activityStore.contains(chat.id),
                                activitySnapshot: activityStore.snapshot(for: chat.id),
                                selectedChat: $selectedChat,
                                viewContext: viewContext,
                                searchText: debouncedSearchText
                            )
                            .id(chat.objectID)
                            .accessibilityIdentifier("chat.\(chat.id.uuidString)")
                        }
                    }
                    .padding(.leading, 15)
                }
            }
            if workspaceDropTarget?.id == workspace.id, workspaceDropTarget?.before == false {
                ReorderDropPlaceholder()
            }
        }
        .opacity(draggedWorkspaceID == workspace.id ? 0.6 : 1)
        .contentShape(Rectangle())
        .dropDestination(for: String.self, action: { draggedIDs, _ in
            defer {
                draggedWorkspaceID = nil
                workspaceDropTarget = nil
            }
            guard let value = draggedIDs.first, let sourceID = UUID(uuidString: value) else { return false }
            return moveWorkspace(withID: sourceID, onto: workspace.id)
        }, isTargeted: { targeted in
            if targeted,
               let sourceIndex = workspaces.firstIndex(where: { $0.id == draggedWorkspaceID }),
               let targetIndex = workspaces.firstIndex(where: { $0.id == workspace.id }),
               sourceIndex != targetIndex {
                workspaceDropTarget = (workspace.id, sourceIndex > targetIndex)
            } else if workspaceDropTarget?.id == workspace.id {
                workspaceDropTarget = nil
            }
        })
    }

    private func toggleWorkspace(_ workspace: WorkspaceEntity) {
        if expandedWorkspaceIDs.contains(workspace.id) {
            expandedWorkspaceIDs.remove(workspace.id)
        } else {
            expandedWorkspaceIDs.insert(workspace.id)
        }
    }

    private func moveWorkspace(withID workspaceID: UUID, onto targetWorkspaceID: UUID) -> Bool {
        guard
            let sourceIndex = workspaces.firstIndex(where: { $0.id == workspaceID }),
            let targetIndex = workspaces.firstIndex(where: { $0.id == targetWorkspaceID }),
            sourceIndex != targetIndex
        else {
            return false
        }

        var reorderedWorkspaces = Array(workspaces)
        let destination = sourceIndex < targetIndex ? targetIndex + 1 : targetIndex
        reorderedWorkspaces.move(fromOffsets: IndexSet(integer: sourceIndex), toOffset: destination)
        do {
            try WorkspaceManager.reorder(reorderedWorkspaces, in: viewContext)
            return true
        } catch {
            workspaceError = error.localizedDescription
            return false
        }
    }
}

