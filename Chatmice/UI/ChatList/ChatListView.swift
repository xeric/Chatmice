//
//  ChatListView.swift
//  Chatmice
//
//  Created by Renat on 17.11.2024.
//

import AppKit
import Combine
import CoreData
import SwiftUI
import UniformTypeIdentifiers


/// Presentation and query ownership survives removal of the sidebar's scroll/row graph.
@MainActor
final class SidebarPresentation: ObservableObject {
    @Published private(set) var workspaces: [WorkspaceEntity] = []
    @Published private(set) var expandedWorkspaceIDs = Set<UUID>()
    @Published private(set) var searchText = ""
    @Published private(set) var isVisible = false
    @Published private(set) var queries: [UUID: SidebarWorkspaceChats] = [:]
    var scrollOffset = NSPoint.zero
    private var knownWorkspaceIDs = Set<UUID>()
    private var context: NSManagedObjectContext?
    private weak var selectedChat: ChatEntity?
    private var selectionID: NSManagedObjectID?
    private var observation: AnyCancellable?
    private var refreshTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var requestedSearch = ""
    private var workspacesDirty = true

    deinit { refreshTask?.cancel(); searchTask?.cancel() }

    func configure(context: NSManagedObjectContext, search: String, selectedChat: ChatEntity?, visible: Bool) {
        if self.context == nil {
            self.context = context
            observation = NotificationCenter.default.publisher(for: .NSManagedObjectContextObjectsDidChange, object: context)
                .sink { [weak self] notification in
                    guard let self else { return }
                    guard self.isVisible else { self.workspacesDirty = true; return }
                    let keys = [NSInsertedObjectsKey, NSDeletedObjectsKey, NSUpdatedObjectsKey, NSRefreshedObjectsKey, NSInvalidatedObjectsKey]
                    if notification.userInfo?[NSInvalidatedAllObjectsKey] != nil || keys.contains(where: { key in
                        (notification.userInfo?[key] as? Set<NSManagedObject> ?? []).contains { $0 is WorkspaceEntity }
                    }) {
                        self.workspacesDirty = true
                        self.scheduleRefresh()
                    }
                }
        }
        self.selectedChat = selectedChat
        selectionID = selectedChat?.objectID
        searchText = search
        requestedSearch = search
        setVisible(visible)
    }

    func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
        if visible {
            searchText = requestedSearch
            refreshWorkspaces()
            synchronizeQueries()
        } else {
            searchTask?.cancel(); searchTask = nil
            refreshTask?.cancel(); refreshTask = nil
            for query in queries.values { query.setActive(false) }
        }
    }

    func setSearch(_ value: String) {
        searchTask?.cancel()
        requestedSearch = value
        guard isVisible else { searchText = value; return }
        searchTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(AppConstants.searchDebounceTime)) } catch { return }
            guard let self, self.isVisible else { return }
            self.searchTask = nil
            self.searchText = value
            self.synchronizeQueries()
        }
    }

    func select(_ chat: ChatEntity?) {
        let changed = selectionID != chat?.objectID
        selectedChat = chat
        selectionID = chat?.objectID
        if changed, let id = chat?.workspace?.id { expandedWorkspaceIDs.insert(id) }
        if isVisible { synchronizeQueries() }
    }

    func setWorkspaceExpanded(_ expanded: Bool, id: UUID) {
        if expanded { expandedWorkspaceIDs.insert(id) } else { expandedWorkspaceIDs.remove(id) }
        if isVisible { synchronizeQueries() }
    }

    private func refreshWorkspaces() {
        guard workspacesDirty, let context else { return }
        let request = NSFetchRequest<WorkspaceEntity>(entityName: "WorkspaceEntity")
        request.sortDescriptors = [NSSortDescriptor(keyPath: \WorkspaceEntity.sortOrder, ascending: true)]
        do {
            workspaces = try context.fetch(request)
            let ids = Set(workspaces.map(\.id))
            expandedWorkspaceIDs.formUnion(ids.subtracting(knownWorkspaceIDs))
            expandedWorkspaceIDs.formIntersection(ids)
            knownWorkspaceIDs = ids
            for id in queries.keys where !ids.contains(id) {
                queries[id]?.setActive(false)
                queries[id] = nil
            }
            workspacesDirty = false
        } catch { NSLog("Sidebar workspace fetch failed: %@", error.localizedDescription) }
    }

    private func synchronizeQueries() {
        guard let context else { return }
        for workspace in workspaces {
            let active = isVisible && (expandedWorkspaceIDs.contains(workspace.id) || !searchText.isEmpty)
            guard active else { queries[workspace.id]?.setActive(false); continue }
            let query: SidebarWorkspaceChats
            if let existing = queries[workspace.id] { query = existing }
            else {
                query = SidebarWorkspaceChats(workspace: workspace, context: context)
                query.setActive(false)
                queries[workspace.id] = query
            }
            query.select(selectedChat)
            query.configure(search: searchText)
            query.setActive(true)
        }
    }

    private func scheduleRefresh() {
        guard isVisible, refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self, self.isVisible else { return }
            self.refreshTask = nil
            self.refreshWorkspaces()
            self.synchronizeQueries()
        }
    }
}

struct ChatListView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @EnvironmentObject private var activityStore: ChatActivityStore
    @StateObject private var presentation: SidebarPresentation
    @State private var draggedWorkspaceID: UUID?
    @State private var workspaceDropTarget: (id: UUID, before: Bool)?
    @State private var editingWorkspace: WorkspaceEntity?
    @State private var deletingWorkspace: WorkspaceEntity?
    @State private var workspaceError: String?

    private var workspaces: [WorkspaceEntity] { presentation.workspaces }
    private var expandedWorkspaceIDs: Set<UUID> { presentation.expandedWorkspaceIDs }


    @Binding var selectedChat: ChatEntity?
    @Binding var searchText: String
    let onNewChat: (WorkspaceEntity) -> Void
    let isVisible: Bool

    init(selectedChat: Binding<ChatEntity?>, searchText: Binding<String>, onNewChat: @escaping (WorkspaceEntity) -> Void,
         isVisible: Bool = true, presentation: SidebarPresentation? = nil) {
        self._selectedChat = selectedChat
        self._searchText = searchText
        self.onNewChat = onNewChat
        self.isVisible = isVisible
        self._presentation = StateObject(wrappedValue: presentation ?? SidebarPresentation())
    }


    var body: some View {
        Group {
            if isVisible {
                ScrollView {
                    // Keep workspace containers stable; their conversation rows remain lazy.
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(workspaces, id: \.objectID) { workspace in workspaceSection(workspace) }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 12)
                    .background(ThinScrollbarConfiguration().allowsHitTesting(false))
                    .background(SidebarScrollRestoration(presentation: presentation))
                }
                .contentMargins(.top, -8, for: .scrollIndicators)
            } else {
                Color.clear
            }
        }
        .onChange(of: searchText) { _, value in presentation.setSearch(value) }
        .onChange(of: selectedChat?.objectID) { presentation.select(selectedChat) }
        .onChange(of: isVisible) { presentation.setVisible(isVisible) }
        .onAppear {
            presentation.configure(context: viewContext, search: searchText, selectedChat: selectedChat, visible: isVisible)
        }
        .onDisappear {
            presentation.setVisible(false)
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
                    presentation.setWorkspaceExpanded(true, id: temporary.id)
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
                    presentation.setWorkspaceExpanded(true, id: workspace.id)
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
            .help(workspace.isTemporary ? workspace.name : workspace.path)
            if (expandedWorkspaceIDs.contains(workspace.id) || !presentation.searchText.isEmpty),
               let data = presentation.queries[workspace.id] {
                WorkspaceChatRows(workspace: workspace, context: viewContext, selectedChat: $selectedChat,
                                  searchText: presentation.searchText, data: data)
                    .padding(.leading, 15)
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
        presentation.setWorkspaceExpanded(!expandedWorkspaceIDs.contains(workspace.id), id: workspace.id)
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

/// A mount-scoped native anchor bridge; no window-wide traversal or polling survives hidden rows.
private struct SidebarScrollRestoration: NSViewRepresentable {
    let presentation: SidebarPresentation

    func makeCoordinator() -> Coordinator { Coordinator(presentation) }
    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.attach = { [weak coordinator = context.coordinator] view in coordinator?.attach(view) }
        return probe
    }
    func updateNSView(_ probe: Probe, context: Context) { context.coordinator.attach(probe) }
    static func dismantleNSView(_ probe: Probe, coordinator: Coordinator) { coordinator.detach() }

    final class Probe: NSView {
        var attach: ((NSView) -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attach?(self) }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); attach?(self) }
    }

    @MainActor
    final class Coordinator {
        private let presentation: SidebarPresentation
        private weak var scroll: NSScrollView?
        private var observation: NSObjectProtocol?
        private var attachmentTask: Task<Void, Never>?

        init(_ presentation: SidebarPresentation) { self.presentation = presentation }
        deinit {
            attachmentTask?.cancel()
            if let observation { NotificationCenter.default.removeObserver(observation) }
        }

        func attach(_ probe: NSView) {
            guard probe.window != nil, scroll == nil, attachmentTask == nil else { return }
            attachmentTask = Task { [weak self, weak probe] in
                await Task.yield()
                guard !Task.isCancelled, let self else { return }
                self.attachmentTask = nil
                guard let probe, let scroll = probe.enclosingScrollView else { return }
                self.scroll = scroll
                scroll.contentView.scroll(to: self.presentation.scrollOffset)
                scroll.reflectScrolledClipView(scroll.contentView)
                scroll.contentView.postsBoundsChangedNotifications = true
                self.observation = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                    object: scroll.contentView, queue: .main) { [weak self, weak scroll] _ in
                        MainActor.assumeIsolated {
                            guard let self, let scroll, self.presentation.isVisible,
                                  !scroll.isHiddenOrHasHiddenAncestor else { return }
                            self.presentation.scrollOffset = scroll.contentView.bounds.origin
                        }
                    }
            }
        }

        func detach() {
            attachmentTask?.cancel(); attachmentTask = nil
            if let observation { NotificationCenter.default.removeObserver(observation) }
            observation = nil
            scroll = nil
        }
    }
}
