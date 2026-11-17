import Combine
import Dispatch
import CoreData
import SwiftUI


/// Exclusive, rolling calendar boundaries; a missing update date uses the creation date.
struct SidebarChatDates {
    enum Bucket: CaseIterable { case recent, week, month, older }
    let week: Date
    let month: Date
    let twoMonths: Date

    init(now: Date, calendar: Calendar = .current) {
        week = calendar.date(byAdding: .day, value: -7, to: now)!
        month = calendar.date(byAdding: .month, value: -1, to: now)!
        twoMonths = calendar.date(byAdding: .month, value: -2, to: now)!
    }

    func bucket(for date: Date?) -> Bucket {
        let date = date ?? .distantPast
        if date >= week { return .recent }
        if date >= month { return .week }
        if date >= twoMonths { return .month }
        return .older
    }

    func predicate(for bucket: Bucket) -> NSPredicate {
        func interval(_ key: String) -> NSPredicate {
            switch bucket {
            case .recent: return NSPredicate(format: "%K >= %@", key, week as NSDate)
            case .week: return NSPredicate(format: "%K >= %@ AND %K < %@", key, month as NSDate, key, week as NSDate)
            case .month: return NSPredicate(format: "%K >= %@ AND %K < %@", key, twoMonths as NSDate, key, month as NSDate)
            case .older: return NSPredicate(format: "%K < %@ OR %K == nil", key, twoMonths as NSDate, key)
            }
        }
        return NSCompoundPredicate(orPredicateWithSubpredicates: [
            NSCompoundPredicate(andPredicateWithSubpredicates: [NSPredicate(format: "updatedDate != nil"), interval("updatedDate")]),
            NSCompoundPredicate(andPredicateWithSubpredicates: [NSPredicate(format: "updatedDate == nil"), interval("createdDate")])
        ])
    }
}

/// Main-window metadata never needs a fetched-results collection of the entire chat history.
@MainActor
enum SidebarChatLookup {
    static func count(in context: NSManagedObjectContext) throws -> Int {
        try context.count(for: NSFetchRequest<ChatEntity>(entityName: "ChatEntity"))
    }

    static func chat(id: UUID, in context: NSManagedObjectContext) throws -> ChatEntity? {
        let request = NSFetchRequest<ChatEntity>(entityName: "ChatEntity")
        request.predicate = NSPredicate(format: "id == %@", id as NSUUID)
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    static func latest(excluding id: UUID, in context: NSManagedObjectContext) throws -> ChatEntity? {
        let request = NSFetchRequest<ChatEntity>(entityName: "ChatEntity")
        request.predicate = NSPredicate(format: "id != %@", id as NSUUID)
        request.sortDescriptors = [NSSortDescriptor(key: "updatedDate", ascending: false)]
        request.fetchLimit = 1
        return try context.fetch(request).first
    }
}

/// Only visible, expanded workspaces execute queries. Historical rows are never queried while More is closed.
@MainActor
final class SidebarWorkspaceChats: ObservableObject {
    enum Section: Hashable { case all, pinned, recent, week, month, older, search }
    struct PageCursor: Hashable {
        fileprivate let section: Section
        fileprivate let revision: UInt
        fileprivate let updatedOffset: Int
        fileprivate let createdOffset: Int
    }
    struct Page: Equatable {
        var chats: [ChatEntity] = []
        var updatedOffset = 0
        var createdOffset = 0
        var hasMore = true
        var revision: UInt = 0
        static func == (lhs: Page, rhs: Page) -> Bool {
            lhs.revision == rhs.revision && lhs.chats.map(\.objectID) == rhs.chats.map(\.objectID)
                && lhs.updatedOffset == rhs.updatedOffset && lhs.createdOffset == rhs.createdOffset
                && lhs.hasMore == rhs.hasMore
        }
    }
    static let pageSize = 30
    @Published private(set) var pages: [Section: Page] = [:]
    @Published private(set) var presentations: [NSManagedObjectID: SidebarConversationPresentation] = [:]
    @Published private(set) var totalCount = 0
    @Published private(set) var olderCount = 0
    @Published private(set) var error: String?
    @Published private(set) var moreExpanded = false
    private(set) var searchText = ""
    private let context: NSManagedObjectContext
    private let workspace: WorkspaceEntity
    private let now: () -> Date
    private let calendar: Calendar
    private var observation: AnyCancellable?
    private var refreshTask: Task<Void, Never>?
    private var visibleIDs = Set<NSManagedObjectID>()
    private var dates: SidebarChatDates
    private struct LatestMessage {
        let id: NSManagedObjectID?
        let body: String
        let timestamp: Date
        let preview: String
        let isImagePreview: Bool
    }
    private var latestMessages: [NSManagedObjectID: LatestMessage] = [:]
    private weak var selectedChat: ChatEntity?
    private var latestInvalidations = Set<NSManagedObjectID>()
    private var metadataInvalidations = Set<NSManagedObjectID>()
    private var needsPageReload = false
    private var isActive = true
    private var suspendedDirty = false
    private var paginationRevision: UInt = 0
    private var queuedPagination: [Section: (cursor: PageCursor, work: DispatchWorkItem)] = [:]
    var isGrouped: Bool { searchText.isEmpty && totalCount >= 10 }

    init(workspace: WorkspaceEntity, context: NSManagedObjectContext, now: @escaping () -> Date = Date.init, calendar: Calendar = .current) {
        self.workspace = workspace
        self.context = context
        self.now = now
        self.calendar = calendar
        self.dates = SidebarChatDates(now: now(), calendar: calendar)
        observation = NotificationCenter.default.publisher(for: .NSManagedObjectContextObjectsDidChange, object: context)
            .sink { [weak self] notification in self?.contextChanged(notification) }
    }

    deinit {
        refreshTask?.cancel()
        for request in queuedPagination.values { request.work.cancel() }
    }
    /// Preserve pages and disclosure state without relationship observation or preview work offscreen.
    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        if !active {
            cancelQueuedPagination()
            refreshTask?.cancel()
            refreshTask = nil
            suspendedDirty = true
        } else if suspendedDirty {
            suspendedDirty = false
            needsPageReload = false
            latestInvalidations.formUnion(latestMessages.keys)
            metadataInvalidations.formUnion(latestMessages.keys)
            reload()
        }
    }


    func configure(search: String) {
        guard search != searchText || pages.isEmpty else { return }
        searchText = search
        if moreExpanded { moreExpanded = false }
        reload()
    }

    func setMoreExpanded(_ expanded: Bool) {
        guard moreExpanded != expanded else { return }
        moreExpanded = expanded
        if expanded { loadNext(.older) }
        else {
            cancelQueuedPagination(.older)
            paginationRevision &+= 1
            var remaining = pages
            remaining[.older] = nil
            updatePages(remaining)
        }
    }

    func chats(in section: Section) -> [ChatEntity] { pages[section]?.chats ?? [] }
    func hasMore(in section: Section) -> Bool { error == nil && pages[section]?.hasMore == true }

    func paginationCursor(in section: Section) -> PageCursor? {
        guard isActive, hasMore(in: section), let page = pages[section] else { return nil }
        return PageCursor(section: section, revision: page.revision, updatedOffset: page.updatedOffset, createdOffset: page.createdOffset)
    }

    /// Visibility is reported during SwiftUI reconciliation. Fetch and publish only after it returns.
    func setPaginationVisible(_ visible: Bool, in section: Section, after cursor: PageCursor) {
        if !visible {
            // An outgoing sentinel must not cancel the visible replacement for a newer page.
            if queuedPagination[section]?.cursor == cursor { cancelQueuedPagination(section) }
            return
        }
        guard paginationCursor(in: section) == cursor else { return }
        guard queuedPagination[section]?.cursor != cursor else { return }
        cancelQueuedPagination(section)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.queuedPagination[section]?.cursor == cursor else { return }
                self.queuedPagination[section] = nil
                self.loadNext(section, after: cursor)
            }
        }
        queuedPagination[section] = (cursor, work)
        DispatchQueue.main.async(execute: work)
    }

    private func cancelQueuedPagination(_ section: Section) {
        queuedPagination.removeValue(forKey: section)?.work.cancel()
    }

    private func cancelQueuedPagination() {
        for request in queuedPagination.values { request.work.cancel() }
        queuedPagination.removeAll(keepingCapacity: true)
    }

    func presentation(for chat: ChatEntity) -> SidebarConversationPresentation? {
        presentations[chat.objectID]
    }

    func select(_ chat: ChatEntity?) {
        guard selectedChat?.objectID != chat?.objectID else { return }
        selectedChat = chat
        if isActive { updatePages(pages) } else { suspendedDirty = true }
    }

    private func updatePages(_ updated: [Section: Page]) {
        var retained: [NSManagedObjectID: ChatEntity] = [:]
        for page in updated.values {
            for chat in page.chats { retained[chat.objectID] = chat }
        }
        if searchText.isEmpty, let selectedChat, !selectedChat.isDeleted, selectedChat.workspace == workspace {
            retained[selectedChat.objectID] = selectedChat
        }
        var prepared: [NSManagedObjectID: SidebarConversationPresentation] = [:]
        for (id, chat) in retained where !chat.isDeleted {
            if latestMessages[id] == nil || latestInvalidations.contains(id) {
                let message = chat.lastMessage
                let body = message?.body ?? ""
                let previous = latestMessages[id]
                let preview: String
                if let previous, previous.body == body {
                    preview = previous.preview
                } else {
                    preview = ToolActivityRecord.removingMarkers(in: body)
                        .replacingOccurrences(of: "<think>.*?</think>", with: "", options: .regularExpression)
                        .replacingOccurrences(of: "\n", with: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                latestMessages[id] = LatestMessage(id: message?.objectID, body: body,
                    timestamp: message?.timestamp ?? .distantPast, preview: preview,
                    isImagePreview: body.starts(with: "<image-uuid>"))
            }
            guard let latest = latestMessages[id] else { continue }
            if let existing = presentations[id], !metadataInvalidations.contains(id), !latestInvalidations.contains(id) {
                prepared[id] = existing
            } else {
                prepared[id] = SidebarConversationPresentation(chatName: chat.name,
                    personaColor: chat.persona?.color, personaSymbolName: chat.persona?.symbolName,
                    personaOverlaySymbolName: chat.persona?.symbolOverlayName,
                    timestamp: latest.timestamp, preview: latest.preview,
                    isImagePreview: latest.isImagePreview, isPinned: chat.isPinned)
            }
        }
        for id in latestMessages.keys where retained[id] == nil { latestMessages[id] = nil }
        latestInvalidations.removeAll(keepingCapacity: true)
        metadataInvalidations.removeAll(keepingCapacity: true)
        visibleIDs = Set(updated.values.flatMap { $0.chats.map(\.objectID) })
        if presentations != prepared { presentations = prepared }
        if pages != updated { pages = updated }
    }

    /// Keep a selected, unpaged chat reachable without forcing More open after a deliberate collapse.
    func selectionOutsidePages(_ chat: ChatEntity?) -> ChatEntity? {
        guard searchText.isEmpty, let chat, !chat.isDeleted, chat.workspace == workspace,
              !pages.values.contains(where: { $0.chats.contains(where: { $0.objectID == chat.objectID }) }) else { return nil }
        return chat
    }

    func reload() {
        guard isActive else { suspendedDirty = true; return }
        cancelQueuedPagination()
        paginationRevision &+= 1
        guard !workspace.isDeleted else { selectedChat = nil; updatePages([:]); return }
        do {
            dates = SidebarChatDates(now: now(), calendar: calendar)
            let countRequest = NSFetchRequest<ChatEntity>(entityName: "ChatEntity")
            countRequest.predicate = NSPredicate(format: "workspace == %@", workspace)
            let count = try context.count(for: countRequest)
            if totalCount != count { totalCount = count }
            let previousPages = pages
            var rebuilt: [Section: Page] = [:]
            let sections: [Section]
            let oldCount: Int
            if !searchText.isEmpty { sections = [.search]; oldCount = 0 }
            else if !isGrouped {
                sections = [.all]; oldCount = 0
                if moreExpanded { moreExpanded = false }
            } else {
                countRequest.predicate = predicate(for: .older)
                oldCount = try context.count(for: countRequest)
                sections = [.pinned, .recent, .week, .month] + (moreExpanded ? [.older] : [])
            }
            if olderCount != oldCount { olderCount = oldCount }
            for section in sections {
                var page = Page(revision: paginationRevision)
                let target = max(Self.pageSize, previousPages[section]?.chats.count ?? 0)
                repeat { try fetchNext(section, page: &page) }
                while page.hasMore && (section == .pinned || page.chats.count < target)
                rebuilt[section] = page
            }
            updatePages(rebuilt)
            if error != nil { error = nil }
        } catch { self.error = error.localizedDescription }
    }

    func loadNext(_ section: Section, after cursor: PageCursor? = nil) {
        guard isActive else { return }
        guard section != .older || moreExpanded, error == nil else { return }
        guard pages[section]?.hasMore != false else { return }
        guard cursor == nil || paginationCursor(in: section) == cursor else { return }
        cancelQueuedPagination(section)
        do {
            var updated = pages
            var page = updated[section] ?? Page(revision: paginationRevision)
            try fetchNext(section, page: &page)
            updated[section] = page
            updatePages(updated)
        }
        catch { self.error = error.localizedDescription }
    }

    private func predicate(for section: Section) -> NSPredicate {
        var predicates = [NSPredicate(format: "workspace == %@", workspace)]
        switch section {
        case .pinned: predicates.append(NSPredicate(format: "isPinned == YES"))
        case .recent, .week, .month, .older:
            predicates.append(NSPredicate(format: "isPinned == NO"))
            let bucket: SidebarChatDates.Bucket
            switch section {
            case .recent: bucket = .recent
            case .week: bucket = .week
            case .month: bucket = .month
            default: bucket = .older
            }
            predicates.append(dates.predicate(for: bucket))
        case .search:
            predicates.append(NSPredicate(format: "name CONTAINS[cd] %@ OR persona.name CONTAINS[cd] %@ OR ANY messages.body CONTAINS[cd] %@", searchText, searchText, searchText))
        case .all: break
        }
        return NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
    }

    private func fetchNext(_ section: Section, page: inout Page) throws {
        // Separate sorted streams implement updatedDate ?? createdDate in SQLite, without sorting
        // or hydrating the entire workspace. Each fetch is capped at 30, including later pages.
        let base = predicate(for: section)
        func fetch(updated: Bool, offset: Int) throws -> [ChatEntity] {
            let request = NSFetchRequest<ChatEntity>(entityName: "ChatEntity")
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                base, NSPredicate(format: updated ? "updatedDate != nil" : "updatedDate == nil")
            ])
            request.sortDescriptors = (section == .all || section == .search ? [NSSortDescriptor(key: "isPinned", ascending: false)] : []) + [
                NSSortDescriptor(key: updated ? "updatedDate" : "createdDate", ascending: false),
                NSSortDescriptor(key: "id", ascending: true)
            ]
            request.fetchLimit = Self.pageSize
            request.fetchOffset = offset
            request.fetchBatchSize = Self.pageSize
            request.returnsObjectsAsFaults = true
            return try context.fetch(request)
        }
        let updated = try fetch(updated: true, offset: page.updatedOffset)
        let created = try fetch(updated: false, offset: page.createdOffset)
        var u = 0, c = 0
        while u + c < Self.pageSize && (u < updated.count || c < created.count) {
            let useUpdated: Bool
            if c == created.count { useUpdated = true }
            else if u == updated.count { useUpdated = false }
            else {
                let lhs = updated[u], rhs = created[c]
                if (section == .all || section == .search) && lhs.isPinned != rhs.isPinned { useUpdated = lhs.isPinned }
                else {
                    let lhsDate = lhs.updatedDate ?? lhs.createdDate ?? .distantPast
                    let rhsDate = rhs.updatedDate ?? rhs.createdDate ?? .distantPast
                    useUpdated = lhsDate == rhsDate ? lhs.id.uuidString < rhs.id.uuidString : lhsDate > rhsDate
                }
            }
            if useUpdated { page.chats.append(updated[u]); u += 1 }
            else { page.chats.append(created[c]); c += 1 }
        }
        page.updatedOffset += u
        page.createdOffset += c
        page.hasMore = u < updated.count || c < created.count || updated.count == Self.pageSize || created.count == Self.pageSize
    }

    private func contextChanged(_ notification: Notification) {
        guard isActive else { suspendedDirty = true; return }
        if notification.userInfo?[NSInvalidatedAllObjectsKey] != nil {
            latestInvalidations.formUnion(latestMessages.keys)
            metadataInvalidations.formUnion(latestMessages.keys)
            needsPageReload = true
            scheduleReload()
            return
        }
        let inserted = notification.userInfo?[NSInsertedObjectsKey] as? Set<NSManagedObject> ?? []
        let deleted = notification.userInfo?[NSDeletedObjectsKey] as? Set<NSManagedObject> ?? []
        let updated = (notification.userInfo?[NSUpdatedObjectsKey] as? Set<NSManagedObject> ?? [])
            .union(notification.userInfo?[NSRefreshedObjectsKey] as? Set<NSManagedObject> ?? [])
            .union(notification.userInfo?[NSInvalidatedObjectsKey] as? Set<NSManagedObject> ?? [])
        let retainedIDs = Set(latestMessages.keys)
        let pageKeys: Set<String> = ["name", "isPinned", "updatedDate", "createdDate", "workspace", "persona"]
        let messageOrderKeys: Set<String> = ["chat", "sequence", "timestamp", "kind"]
        for object in inserted.union(deleted).union(updated) {
            let isNewOrDeleted = inserted.contains(object) || deleted.contains(object)
            let keys = Set(object.changedValuesForCurrentEvent().keys)
            if let chat = object as? ChatEntity {
                if isNewOrDeleted || !keys.isDisjoint(with: pageKeys) {
                    if chat.workspace == workspace || retainedIDs.contains(chat.objectID) || keys.contains("workspace") {
                        needsPageReload = true
                    }
                }
                if retainedIDs.contains(chat.objectID) {
                    metadataInvalidations.insert(chat.objectID)
                    if isNewOrDeleted || keys.contains("messages") || keys.isEmpty { latestInvalidations.insert(chat.objectID) }
                }
            } else if let message = object as? MessageEntity {
                var owners = Set(latestMessages.filter { $0.value.id == message.objectID }.map(\.key))
                if let chat = message.chat { owners.insert(chat.objectID) }
                if let old = message.committedValues(forKeys: ["chat"])["chat"] as? ChatEntity { owners.insert(old.objectID) }
                for id in owners.intersection(retainedIDs) {
                    if isNewOrDeleted || !keys.isDisjoint(with: messageOrderKeys) || keys.isEmpty
                        || (keys.contains("body") && latestMessages[id]?.id == message.objectID) {
                        latestInvalidations.insert(id)
                    }
                }
                if !searchText.isEmpty { needsPageReload = true }
            } else if let persona = object as? PersonaEntity {
                for chat in pages.values.flatMap(\.chats) where chat.persona == persona {
                    metadataInvalidations.insert(chat.objectID)
                }
                if selectedChat?.persona == persona, let id = selectedChat?.objectID { metadataInvalidations.insert(id) }
                if !searchText.isEmpty { needsPageReload = true }
            }
        }
        if needsPageReload || !latestInvalidations.isDisjoint(with: retainedIDs)
            || !metadataInvalidations.isDisjoint(with: retainedIDs) { scheduleReload() }
    }

    private func scheduleReload() {
        guard isActive else { suspendedDirty = true; return }
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, let self else { return }
            self.refreshTask = nil
            let reloadPages = self.needsPageReload
            self.needsPageReload = false
            if reloadPages { self.reload() } else { self.updatePages(self.pages) }
        }
    }
}

struct WorkspaceChatRows: View {
    @EnvironmentObject private var activityStore: ChatActivityStore
    @StateObject private var data: SidebarWorkspaceChats
    @Binding var selectedChat: ChatEntity?
    let searchText: String
    private let context: NSManagedObjectContext
    private let workspace: WorkspaceEntity
    private let clock = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    init(workspace: WorkspaceEntity, context: NSManagedObjectContext, selectedChat: Binding<ChatEntity?>, searchText: String, data: SidebarWorkspaceChats? = nil) {
        self.workspace = workspace
        self.context = context
        self._selectedChat = selectedChat
        self.searchText = searchText
        self._data = StateObject(wrappedValue: data ?? SidebarWorkspaceChats(workspace: workspace, context: context))
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 6) {
            if let error = data.error {
                Text(error).font(.caption).foregroundStyle(.secondary)
                Button("Retry") { data.reload() }
            } else if !searchText.isEmpty {
                rows(.search)
                if data.chats(in: .search).isEmpty { emptyLabel("No matches") }
            } else if !data.isGrouped {
                rows(.all)
                if data.totalCount == 0 { emptyLabel("No chats") }
            } else {
                rows(.pinned)
                if let chat = data.selectionOutsidePages(selectedChat) { row(chat) }
                rows(.recent)
                datedRows(.week, title: "Previous Week")
                datedRows(.month, title: "Previous Month")
                if data.olderCount > 0 {
                    DisclosureGroup(isExpanded: Binding(get: { data.moreExpanded }, set: { data.setMoreExpanded($0) })) {
                        // DisclosureGroup can evaluate its content while collapsed. Guard the row construction too.
                        if data.moreExpanded {
                            LazyVStack(alignment: .leading, spacing: 6) { rows(.older) }
                        }
                    } label: {
                        Text("More").font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("workspace.more.\(workspace.id.uuidString)")
                }
            }
        }
        .task(id: searchText) {
            data.select(selectedChat)
            data.configure(search: searchText)
        }
        .onChange(of: selectedChat?.objectID) { data.select(selectedChat) }
        .onReceive(clock) { _ in data.reload() }
    }

    private func emptyLabel(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.tertiary).padding(.leading, 15).padding(.vertical, 4)
    }

    @ViewBuilder private func datedRows(_ section: SidebarWorkspaceChats.Section, title: String) -> some View {
        if !data.chats(in: section).isEmpty {
            Text(title).font(.caption).foregroundStyle(.secondary).padding(.top, 6)
            rows(section)
        }
    }

    @ViewBuilder private func rows(_ section: SidebarWorkspaceChats.Section) -> some View {
        ForEach(data.chats(in: section), id: \.objectID) { chat in row(chat) }
        if let cursor = data.paginationCursor(in: section) {
            Button("Load More") { data.loadNext(section, after: cursor) }
                .font(.caption)
                .id(cursor)
                .onScrollVisibilityChange { visible in
                    data.setPaginationVisible(visible, in: section, after: cursor)
                }
                .onDisappear { data.setPaginationVisible(false, in: section, after: cursor) }
        }
    }

    @ViewBuilder private func row(_ chat: ChatEntity) -> some View {
        if let presentation = data.presentation(for: chat) {
            ChatListRow(chat: chat, presentation: presentation,
                        showsAttentionIndicator: activityStore.contains(chat.id),
                        activitySnapshot: activityStore.snapshot(for: chat.id), selectedChat: $selectedChat,
                        viewContext: context, searchText: searchText)
                .id(chat.objectID)
                .accessibilityIdentifier("chat.\(chat.id.uuidString)")
        }
    }
}

