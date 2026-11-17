import AppKit
import CoreData
import SwiftUI
import XCTest
@testable import Chatmice

@MainActor
final class SidebarConversationTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-11-10T12:00:00Z")!
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testContinuousNativeWheelScrollingKeepsRealSidebarResponsive() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let home = environment["SIDEBAR_TEST_HOME"], let bundleID = environment["SIDEBAR_TEST_BUNDLE_ID"] else {
            throw XCTSkip("Native wheel stress requires an isolated app bundle and HOME")
        }
        XCTAssertEqual(FileManager.default.homeDirectoryForCurrentUser.path, home)
        XCTAssertEqual(Bundle.main.bundleIdentifier, bundleID)
        let fixture = try Fixture()
        let workspaces = (0..<3).map { index in
            let workspace = fixture.workspace(temporary: index == 0)
            workspace.name = "Wheel Workspace \(index)"
            workspace.sortOrder = Int64(index)
            return workspace
        }
        let counts = [180, 65, 65]
        for workspaceIndex in 0..<3 {
            for index in 0..<counts[workspaceIndex] {
                let chat = fixture.chat(workspaces[workspaceIndex], name: "Wheel \(workspaceIndex)-\(index)",
                    date: workspaceIndex == 1 ? .distantPast : Date().addingTimeInterval(-Double(index)))
                let message = fixture.message()
                message.chat = chat; message.sequence = 1; message.kind = MessageKind.message.rawValue
                message.body = String(repeating: "Synthetic preview 中文 العربية 日本語 Кириллица \(index). ",
                                      count: index.isMultiple(of: 15) ? 2_000 : 200)
            }
        }
        try fixture.context.save()
        // Preserve production's 1178 x 878 window and its original nested sidebar hierarchy.
        // Native hosted-window safe-area geometry differs by eight points; measure, do not force it.
        for width: CGFloat in [265, 180, 400] {
            let state = StructuralState()
            let host = NSHostingView(rootView: WheelRoot(state: state, width: width)
                .environment(\.managedObjectContext, fixture.context).environmentObject(ChatActivityStore.shared))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1178, height: 878),
                                  styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.animationBehavior = .none
            window.title = "Owned sidebar wheel fixture"; window.contentView = host
            window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
            host.additionalSafeAreaInsets = NSEdgeInsets(top: -52, left: 0, bottom: 0, right: 0)
            window.orderFrontRegardless()
            defer { window.contentView = nil; window.close() }
            try await awaitCondition { self.findScrollView(host) != nil && state.presentation.queries.count == 3 }
            try await Task.sleep(for: .milliseconds(200))
            let scroll = try XCTUnwrap(findScrollView(host))
            XCTAssertEqual(scroll.contentView.bounds.width, width, accuracy: 2)
            XCTAssertTrue((700...820).contains(scroll.contentView.bounds.height))
            XCTAssertEqual(scroll.visibleRect.height, scroll.contentView.bounds.height, accuracy: 2)
            let queries = try workspaces.map { try XCTUnwrap(state.presentation.queries[$0.id]) }
            queries[1].setMoreExpanded(true)
            var boundsChanges = 0
            var publications = 0
            let observation = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                object: scroll.contentView, queue: nil) { _ in boundsChanges += 1 }
            let subscriptions = queries.map { $0.objectWillChange.sink { publications += 1 } }
            defer { NotificationCenter.default.removeObserver(observation); subscriptions.forEach { $0.cancel() } }
            let point = scroll.contentView.convert(NSPoint(x: scroll.contentView.bounds.midX, y: scroll.contentView.bounds.midY), to: nil)
            XCTAssertTrue(host.hitTest(host.convert(point, from: nil))?.enclosingScrollView === scroll)
            var wheelCalls = 0
            func wheel(_ delta: Int32, units: CGScrollEventUnit) throws {
                let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 1,
                                                 wheel1: delta, wheel2: 0, wheel3: 0))
                let native = try XCTUnwrap(NSEvent(cgEvent: event))
                XCTAssertEqual(native.type, .scrollWheel)
                XCTAssertNotEqual(native.scrollingDeltaY, 0)
                // Actual AppKit wheel handling, without WindowServer coalescing the entire stress burst.
                scroll.scrollWheel(with: native)
                wheelCalls += 1
            }
            func allPagesLoaded() -> Bool {
                queries[0].chats(in: .recent).count == 180 && !queries[0].hasMore(in: .recent)
                    && queries[1].chats(in: .older).count == 65 && !queries[1].hasMore(in: .older)
                    && queries[2].chats(in: .recent).count == 65 && !queries[2].hasMore(in: .recent)
            }
            var maximumOffset: CGFloat = 0
            func sweep(down: Bool, units: CGScrollEventUnit, cycle: Int) async throws {
                let deadline = ProcessInfo.processInfo.systemUptime + 7
                let startingBoundsChanges = boundsChanges
                var frames = 0
                while ProcessInfo.processInfo.systemUptime < deadline {
                    let amount: Int32 = units == .line ? 2 : 64
                    for _ in 0..<12 { try wheel(down ? -amount : amount, units: units) }
                    // Reverse briefly in the middle of each sweep, not only over the first few rows.
                    if frames.isMultiple(of: 7) {
                        for _ in 0..<2 { try wheel(down ? amount : -amount, units: units) }
                    }
                    try await Task.sleep(for: .milliseconds(16))
                    let offset = scroll.contentView.bounds.origin.y
                    maximumOffset = max(maximumOffset, offset)
                    let document = try XCTUnwrap(scroll.documentView)
                    let atEnd = down ? scroll.contentView.bounds.maxY >= document.bounds.maxY - 2 : offset <= 2
                    if frames.isMultiple(of: 20) {
                        print("SIDEBAR_WHEEL width=\(width) cycle=\(cycle) down=\(down) offset=\(offset) document=\(document.bounds.height) bounds=\(boundsChanges) pages=\(queries.map { $0.pages.values.reduce(0) { $0 + $1.chats.count } }) publications=\(publications)")
                    }
                    if atEnd && (!down || allPagesLoaded()) {
                        XCTAssertGreaterThan(boundsChanges, startingBoundsChanges)
                        return
                    }
                    frames += 1
                }
                XCTFail("Native wheel sweep did not reach \(down ? "all pages and bottom" : "top") within seven seconds")
                throw NSError(domain: "SidebarWheelFixture", code: 1)
            }
            let started = ProcessInfo.processInfo.systemUptime
            for cycle in 0..<3 {
                let units: CGScrollEventUnit = cycle.isMultiple(of: 2) ? .line : .pixel
                try await sweep(down: true, units: units, cycle: cycle)
                try await sweep(down: false, units: units, cycle: cycle)
                let responseStarted = ProcessInfo.processInfo.systemUptime
                await drainPaginationQueue()
                XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - responseStarted, 1)
            }
            XCTAssertTrue(allPagesLoaded())
            XCTAssertGreaterThan(maximumOffset, scroll.contentView.bounds.height * 3, "Stress must churn through workspaces, not just the first rows")
            XCTAssertLessThan(boundsChanges, wheelCalls * 8)
            XCTAssertLessThan(publications, 64, "Queries must remain bounded by pages, not publish per wheel event")
            try await Task.sleep(for: .milliseconds(150))
            await drainPaginationQueue()
            let quietPublications = publications
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertEqual(publications, quietPublications, "Pagination must stop after the wheel and all pages drain")
            XCTAssertEqual(state.presentation.scrollOffset.y, scroll.contentView.bounds.origin.y, accuracy: 2)
            func visibleButton(_ view: NSView) -> NSButton? {
                if let button = view as? NSButton, !button.isHiddenOrHasHiddenAncestor,
                   button.bounds.intersects(button.visibleRect), button.frame.height > 30 { return button }
                return view.subviews.lazy.compactMap(visibleButton).first
            }
            let button = try XCTUnwrap(visibleButton(scroll.documentView!))
            try clickNative(at: button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil), in: window)
            try await awaitCondition { state.selectedChat != nil }
            XCTAssertTrue(state.selectedChat?.workspace === workspaces[0])
            print("SIDEBAR_WHEEL_DONE width=\(width) viewport=\(scroll.contentView.bounds.size) nativeWheels=\(wheelCalls) maxOffset=\(maximumOffset) seconds=\(ProcessInfo.processInfo.systemUptime - started) selected=\(state.selectedChat != nil) publications=\(publications)")
        }
    }

    private struct WheelRoot: View {
        @ObservedObject var state: StructuralState
        let width: CGFloat
        var body: some View {
            NavigationSplitView(columnVisibility: Binding(get: { state.visible ? .all : .detailOnly }, set: { state.visible = $0 != .detailOnly })) {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 38)
                    ChatListView(selectedChat: $state.selectedChat, searchText: $state.search, onNewChat: { _ in },
                                 isVisible: state.visible, presentation: state.presentation)
                    Divider()
                    Color.clear.frame(height: 54)
                }
                .navigationSplitViewColumnWidth(min: width, ideal: width, max: width)
            } detail: { Text("Owned native wheel fixture").frame(minWidth: 400) }
            .ignoresSafeArea(.container, edges: .top)
        }
    }

    func testVisibilityPaginationDefersCoalescesAndRejectsObsoleteCursors() async throws {
        let fixture = try Fixture()
        let workspace = fixture.workspace()
        for index in 0..<180 { fixture.chat(workspace, name: "Deferred \(index)", date: now) }
        try fixture.context.save()
        let data = store(workspace, fixture)
        data.configure(search: "")
        let first = try XCTUnwrap(data.paginationCursor(in: .recent))
        var publications = 0
        let subscription = data.objectWillChange.sink { publications += 1 }
        defer { subscription.cancel() }
        for _ in 0..<100 { data.setPaginationVisible(true, in: .recent, after: first) }
        XCTAssertEqual(data.chats(in: .recent).count, 30)
        XCTAssertEqual(publications, 0, "Visibility callbacks must neither fetch nor publish synchronously")
        await drainPaginationQueue()
        XCTAssertEqual(data.chats(in: .recent).count, 60, "Repeated visibility callbacks coalesce one expected page")
        let second = try XCTUnwrap(data.paginationCursor(in: .recent))
        data.setPaginationVisible(true, in: .recent, after: second)
        data.loadNext(.recent, after: second)
        await drainPaginationQueue()
        XCTAssertEqual(data.chats(in: .recent).count, 90, "Manual Load More must consume the queued auto request once")
        let third = try XCTUnwrap(data.paginationCursor(in: .recent))
        data.setPaginationVisible(true, in: .recent, after: third)
        data.setPaginationVisible(false, in: .recent, after: second)
        await drainPaginationQueue()
        XCTAssertEqual(data.chats(in: .recent).count, 120, "Outgoing sentinel callbacks cannot cancel a newer visible cursor")
        data.loadNext(.recent, after: third)
        data.setPaginationVisible(true, in: .recent, after: third)
        await drainPaginationQueue()
        XCTAssertEqual(data.chats(in: .recent).count, 120, "Obsolete manual and automatic cursors cannot fetch twice")
        let fourth = try XCTUnwrap(data.paginationCursor(in: .recent))
        data.setPaginationVisible(true, in: .recent, after: fourth)
        data.setPaginationVisible(false, in: .recent, after: fourth)
        await drainPaginationQueue()
        XCTAssertEqual(data.chats(in: .recent).count, 120)
    }

    func testQueuedVisibilityPaginationCancelsAcrossQueryLifecycle() async throws {
        let fixture = try Fixture()
        let workspace = fixture.workspace()
        for index in 0..<95 {
            fixture.chat(workspace, name: "Lifecycle recent \(index)", date: now)
            fixture.chat(workspace, name: "Lifecycle older \(index)", date: .distantPast)
        }
        try fixture.context.save()
        let data = store(workspace, fixture)
        data.configure(search: "")
        let first = try XCTUnwrap(data.paginationCursor(in: .recent))
        data.setPaginationVisible(true, in: .recent, after: first)
        data.setActive(false)
        await drainPaginationQueue()
        XCTAssertEqual(data.chats(in: .recent).count, 30)
        data.setActive(true)
        data.setMoreExpanded(true)
        let older = try XCTUnwrap(data.paginationCursor(in: .older))
        data.setPaginationVisible(true, in: .older, after: older)
        data.setMoreExpanded(false)
        await drainPaginationQueue()
        XCTAssertTrue(data.chats(in: .older).isEmpty)
        data.setMoreExpanded(true)
        let reopened = try XCTUnwrap(data.paginationCursor(in: .older))
        data.setPaginationVisible(true, in: .older, after: reopened)
        data.setPaginationVisible(false, in: .older, after: older)
        await drainPaginationQueue()
        XCTAssertEqual(data.chats(in: .older).count, 60)
        let recent = try XCTUnwrap(data.paginationCursor(in: .recent))
        data.setPaginationVisible(true, in: .recent, after: recent)
        data.configure(search: "Lifecycle")
        await drainPaginationQueue()
        XCTAssertEqual(data.chats(in: .search).count, 30)
        XCTAssertTrue(data.chats(in: .recent).isEmpty)
        XCTAssertFalse(data.moreExpanded)
        let search = try XCTUnwrap(data.paginationCursor(in: .search))
        data.setPaginationVisible(true, in: .search, after: search)
        data.reload()
        await drainPaginationQueue()
        XCTAssertEqual(data.chats(in: .search).count, 30)
        let reloaded = try XCTUnwrap(data.paginationCursor(in: .search))
        XCTAssertNotEqual(search, reloaded)
        data.setPaginationVisible(true, in: .search, after: reloaded)
        data.setPaginationVisible(false, in: .search, after: search)
        await drainPaginationQueue()
        XCTAssertEqual(data.chats(in: .search).count, 60)
    }

    private func drainPaginationQueue() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    private func clickNative(at point: NSPoint, in window: NSWindow) throws {
        let timestamp = ProcessInfo.processInfo.systemUptime
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
            timestamp: timestamp + 0.001, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 0))
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: timestamp, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        // NSButton tracks synchronously; mouseUp must already be available to its tracking loop.
        NSApp.postEvent(up, atStart: true)
        window.sendEvent(down)
        if let remaining = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
            window.sendEvent(remaining)
        }
    }

    func testNativeSidebarHiddenBoundaryPreservesQueriesFoldsMoreSelectionAndScroll() async throws {
        let fixture = try Fixture()
        let workspaces = (0..<3).map { index in
            let workspace = fixture.workspace(temporary: index == 0)
            workspace.name = "Structural Workspace \(index)"
            workspace.sortOrder = Int64(index)
            return workspace
        }
        for index in 0..<50 {
            let chat = fixture.chat(workspaces[index % 3], name: "Structural Chat \(index)",
                                    date: index < 30 ? Date().addingTimeInterval(-Double(index)) : .distantPast)
            let message = fixture.message()
            message.chat = chat; message.sequence = 1; message.kind = MessageKind.message.rawValue
            message.body = String(repeating: "Large synthetic preview words. ", count: index == 0 ? 2_000 : 200)
        }
        try fixture.context.save()
        let state = StructuralState()
        let host = NSHostingView(rootView: StructuralRoot(state: state).environment(\.managedObjectContext, fixture.context)
            .environmentObject(ChatActivityStore.shared))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 420),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.animationBehavior = .none; window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        func descendants<T: NSView>(_ view: NSView, as type: T.Type) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, as: type) }
        }
        var conversationButtonClass: ObjectIdentifier?
        func conversationButtons() -> [NSButton] {
            descendants(host, as: NSButton.self).filter { ObjectIdentifier(type(of: $0)) == conversationButtonClass }
        }
        func measure(_ phase: String) async throws {
            try await Task.sleep(for: .milliseconds(200))
            let start = ProcessInfo.processInfo.systemUptime
            host.invalidateIntrinsicContentSize(); host.needsUpdateConstraints = true
            host.updateConstraintsForSubtreeIfNeeded(); host.layoutSubtreeIfNeeded()
            let fitting = host.fittingSize
            print("SIDEBAR_BOUNDARY \(phase) seconds=\(ProcessInfo.processInfo.systemUptime - start) fitting=\(fitting) buttons=\(descendants(host, as: NSButton.self).count) scrolls=\(descendants(host, as: NSScrollView.self).count) sizing=\(host.sizingOptions.rawValue)")
            if conversationButtonClass != nil { print("SIDEBAR_CONVERSATION_CONTROLS \(phase) count=\(conversationButtons().count)") }
        }
        try await measure("expanded")
        XCTAssertEqual(state.presentation.workspaces.count, 3)
        let button = try XCTUnwrap(descendants(host, as: NSButton.self).first)
        button.performClick(nil)
        try await awaitCondition { state.selectedChat != nil }
        conversationButtonClass = ObjectIdentifier(type(of: button))
        print("SIDEBAR_CONVERSATION_CONTROLS expanded count=\(conversationButtons().count)")
        let selected = try XCTUnwrap(state.selectedChat)
        let query = try XCTUnwrap(state.presentation.queries[selected.workspace!.id])
        query.setMoreExpanded(true)
        let historicalIDs = query.chats(in: .older).map(\.objectID)
        XCTAssertFalse(historicalIDs.isEmpty)
        let scroll = try XCTUnwrap(findScrollView(host))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 180))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await awaitCondition { state.presentation.scrollOffset.y > 100 }
        let savedOffset = state.presentation.scrollOffset
        let prepared = try XCTUnwrap(query.presentation(for: selected))
        let latest = try XCTUnwrap(selected.lastMessage)
        state.visible = false
        try await measure("column-hidden")
        XCTAssertNil(findScrollView(host), "Hidden must remove the real scroll/row graph, not just hide its column")
        XCTAssertTrue(descendants(host, as: NSButton.self).isEmpty)
        XCTAssertFalse(state.presentation.isVisible)
        selected.name = "Changed while hidden"
        latest.body = "Fresh hidden edit"
        let added = fixture.chat(selected.workspace!, name: "Inserted while hidden", date: Date())
        try fixture.context.save()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(query.presentation(for: selected), prepared, "Hidden notifications must not prepare previews")
        XCTAssertFalse(query.pages.values.contains { $0.chats.contains(added) }, "Hidden notifications must not fetch pages")
        XCTAssertEqual(query.chats(in: .older).map(\.objectID), historicalIDs)
        XCTAssertTrue(query.moreExpanded)
        state.visible = true
        try await measure("reshown")
        XCTAssertTrue(state.presentation.queries[selected.workspace!.id] === query)
        XCTAssertEqual(query.presentation(for: selected)?.title, "Changed while hidden")
        XCTAssertEqual(query.presentation(for: selected)?.preview, "Fresh hidden edit")
        XCTAssertTrue(query.pages.values.contains { $0.chats.contains(added) })
        XCTAssertTrue(query.moreExpanded)
        XCTAssertEqual(query.chats(in: .older).map(\.objectID), historicalIDs)
        XCTAssertTrue(state.selectedChat === selected)
        let restoredScroll = try XCTUnwrap(findScrollView(host))
        XCTAssertEqual(restoredScroll.contentView.bounds.origin.y, savedOffset.y, accuracy: 2)
        for workspace in workspaces { state.presentation.setWorkspaceExpanded(false, id: workspace.id) }
        // The retained native offset need not cover every header after a deliberate bulk collapse.
        try await Task.sleep(for: .milliseconds(150))
        restoredScroll.contentView.scroll(to: .zero)
        restoredScroll.reflectScrolledClipView(restoredScroll.contentView)
        try await measure("folded")
        XCTAssertTrue(state.presentation.expandedWorkspaceIDs.isEmpty)
        XCTAssertTrue(conversationButtons().isEmpty, "Only workspace headers, no conversation buttons, may remain")
        XCTAssertEqual(descendants(host, as: ReorderDragSourceView.self).count, 3)
        state.visible = false
        try await measure("folded-hidden")
        XCTAssertNil(findScrollView(host))
        state.visible = true
        try await measure("folded-reshown")
        XCTAssertTrue(state.presentation.expandedWorkspaceIDs.isEmpty, "Showing the column must not expand deliberately collapsed workspaces")
        XCTAssertEqual(descendants(host, as: ReorderDragSourceView.self).count, 3)
        XCTAssertTrue(conversationButtons().isEmpty)
        XCTAssertTrue(query.moreExpanded)
        XCTAssertTrue(host.sizingOptions.contains(.minSize))
    }

    func testSuspendedQueriesRetainPagesAndRefreshDirtyDataOnResume() async throws {
        let fixture = try Fixture()
        let workspace = fixture.workspace()
        for index in 0..<65 {
            let chat = fixture.chat(workspace, name: "History \(index)", date: .distantPast)
            let message = fixture.message()
            message.chat = chat; message.kind = MessageKind.message.rawValue; message.sequence = 1
            message.body = "Preview \(index)"
        }
        try fixture.context.save()
        let data = store(workspace, fixture)
        data.configure(search: "")
        data.setMoreExpanded(true)
        data.loadNext(.older)
        XCTAssertEqual(data.chats(in: .older).count, 60)
        let chat = try XCTUnwrap(data.chats(in: .older).first)
        let before = data.presentation(for: chat)
        data.setActive(false)
        chat.name = "Edited while suspended"
        chat.lastMessage?.body = "New suspended preview"
        try fixture.context.save()
        try await Task.sleep(for: .milliseconds(250))
        data.loadNext(.older)
        data.reload()
        XCTAssertEqual(data.chats(in: .older).count, 60)
        XCTAssertEqual(data.presentation(for: chat), before)
        data.setActive(true)
        XCTAssertTrue(data.moreExpanded)
        XCTAssertEqual(data.chats(in: .older).count, 60)
        XCTAssertEqual(data.presentation(for: chat)?.title, "Edited while suspended")
        XCTAssertEqual(data.presentation(for: chat)?.preview, "New suspended preview")
    }

    func testPendingSearchSurvivesHideWithoutExpandingDeliberateFolds() async throws {
        let fixture = try Fixture()
        let workspace = fixture.workspace()
        fixture.chat(workspace, name: "Pending search match", date: now)
        try fixture.context.save()
        let presentation = SidebarPresentation()
        presentation.configure(context: fixture.context, search: "", selectedChat: nil, visible: true)
        presentation.setWorkspaceExpanded(false, id: workspace.id)
        presentation.setSearch("Pending")
        presentation.setVisible(false)
        try await Task.sleep(for: .milliseconds(250))
        presentation.setVisible(true)
        XCTAssertEqual(presentation.searchText, "Pending")
        XCTAssertTrue(presentation.expandedWorkspaceIDs.isEmpty)
        XCTAssertEqual(presentation.queries[workspace.id]?.chats(in: .search).count, 1)
        presentation.setSearch("")
        try await awaitCondition { presentation.searchText.isEmpty }
        XCTAssertTrue(presentation.expandedWorkspaceIDs.isEmpty)
    }

    @MainActor
    private final class StructuralState: ObservableObject {
        @Published var visible = true
        @Published var selectedChat: ChatEntity?
        @Published var search = ""
        let presentation = SidebarPresentation()
    }
    private struct StructuralRoot: View {
        @ObservedObject var state: StructuralState
        var body: some View {
            NavigationSplitView(columnVisibility: Binding(get: { state.visible ? .all : .detailOnly }, set: { state.visible = $0 != .detailOnly })) {
                ChatListView(selectedChat: $state.selectedChat, searchText: $state.search, onNewChat: { _ in },
                             isVisible: state.visible, presentation: state.presentation)
                    .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 400)
            } detail: { Text("Owned structural sidebar fixture").frame(minWidth: 400) }
        }
    }



    func testPreparedPreviewPreservesMarkersThinkingImagesAndFullSearch() async throws {
        let fixture = try Fixture()
        let workspace = fixture.workspace()
        let chat = fixture.chat(workspace, name: "Preview", date: now)
        let marker = ToolActivityRecord(name: "Synthetic", input: "Input", output: "Hidden output", isError: false).marker
        let message = fixture.message()
        message.chat = chat
        message.kind = MessageKind.message.rawValue
        message.sequence = 1
        message.timestamp = now
        message.body = "  Before\n\(marker)\n<think>hidden reasoning</think>After\n "
        try fixture.context.save()
        let data = store(workspace, fixture)
        data.configure(search: "")
        XCTAssertEqual(data.presentation(for: chat)?.preview, "Before After")
        XCTAssertEqual(data.presentation(for: chat)?.timestamp, now)
        message.body = "<image-uuid>synthetic-id</image-uuid>"
        try fixture.context.save()
        try await awaitCondition { data.presentation(for: chat)?.isImagePreview == true }
        XCTAssertEqual(data.presentation(for: chat)?.preview, message.body)
        message.body = marker
        try fixture.context.save()
        try await awaitCondition { data.presentation(for: chat)?.preview == "" }
        message.body = String(repeating: "Long visible source ", count: 4_000) + "<think>completeSearchNeedle</think>"
        try fixture.context.save()
        try await awaitCondition { data.presentation(for: chat)?.preview.count == 79_999 }
        XCTAssertFalse(try XCTUnwrap(data.presentation(for: chat)).preview.contains("completeSearchNeedle"))
        data.configure(search: "completeSearchNeedle")
        XCTAssertEqual(data.chats(in: .search).map(\.objectID), [chat.objectID], "Search must query complete messages, not prepared previews")
        XCTAssertGreaterThan(try XCTUnwrap(data.presentation(for: chat)).preview.count, 59_000)
    }

    func testPreparedRowsRefreshLatestIdentityMetadataAndRelationshipChanges() async throws {
        let fixture = try Fixture()
        let workspace = fixture.workspace()
        let firstChat = fixture.chat(workspace, name: "Original", date: now)
        let secondChat = fixture.chat(workspace, name: "Other", date: now)
        let first = fixture.message()
        first.chat = firstChat; first.body = "First"; first.kind = MessageKind.message.rawValue
        first.sequence = 1; first.timestamp = now
        let latest = fixture.message()
        latest.chat = firstChat; latest.body = "Latest"; latest.kind = MessageKind.message.rawValue
        latest.sequence = 2; latest.timestamp = now.addingTimeInterval(1)
        try fixture.context.save()
        let data = store(workspace, fixture)
        data.configure(search: "")
        let other = try XCTUnwrap(data.presentation(for: secondChat))
        XCTAssertEqual(data.presentation(for: firstChat)?.preview, "Latest")
        latest.body = "Edited latest"
        firstChat.name = "Renamed"
        latest.timestamp = now.addingTimeInterval(2)
        let persona = fixture.persona()
        persona.id = UUID(); persona.color = "#009900"; persona.symbolName = " star.fill "
        firstChat.persona = persona
        try fixture.context.save()
        try await awaitCondition { data.presentation(for: firstChat)?.title == "Renamed" && data.presentation(for: firstChat)?.preview == "Edited latest" }
        XCTAssertEqual(data.presentation(for: firstChat)?.timestamp, now.addingTimeInterval(2))
        XCTAssertEqual(data.presentation(for: firstChat)?.symbolName, "star.fill")
        XCTAssertEqual(data.presentation(for: firstChat)?.color, "#009900")
        XCTAssertEqual(data.presentation(for: secondChat), other)
        first.sequence = 3
        try fixture.context.save()
        try await awaitCondition { data.presentation(for: firstChat)?.preview == "First" }
        first.kind = MessageKind.contextCheckpoint.rawValue
        try fixture.context.save()
        try await awaitCondition { data.presentation(for: firstChat)?.preview == "Edited latest" }
        latest.chat = secondChat
        try fixture.context.save()
        try await awaitCondition { data.presentation(for: firstChat)?.preview == "" && data.presentation(for: secondChat)?.preview == "Edited latest" }
        fixture.context.delete(latest)
        try fixture.context.save()
        try await awaitCondition { data.presentation(for: secondChat)?.preview == "" }
        persona.symbolName = "no.such.synthetic.symbol"
        try fixture.context.save()
        try await awaitCondition { data.presentation(for: firstChat)?.symbolName == PersonaAppearance.defaultSymbol }
    }

    func testPreparedHistoricalRowsReleaseExceptSelectedAndReloadWithoutStaleValues() async throws {
        let fixture = try Fixture()
        let workspace = fixture.workspace()
        var chats: [ChatEntity] = []
        for index in 0..<35 {
            let chat = fixture.chat(workspace, name: "Historical \(index)", date: .distantPast)
            let message = fixture.message()
            message.chat = chat; message.kind = MessageKind.message.rawValue; message.sequence = 1
            message.body = "Historical preview \(index)"
            chats.append(chat)
        }
        try fixture.context.save()
        let data = store(workspace, fixture)
        data.configure(search: "")
        XCTAssertTrue(data.presentations.isEmpty)
        data.setMoreExpanded(true)
        XCTAssertEqual(data.presentations.count, 30)
        let selected = try XCTUnwrap(data.chats(in: .older).first)
        data.select(selected)
        data.setMoreExpanded(false)
        XCTAssertEqual(Set(data.presentations.keys), [selected.objectID])
        data.select(nil)
        XCTAssertTrue(data.presentations.isEmpty)
        selected.name = "Updated while unloaded"
        selected.isPinned = true
        try fixture.context.save()
        try await awaitCondition { data.chats(in: .pinned).contains(selected) }
        XCTAssertEqual(data.presentation(for: selected)?.title, "Updated while unloaded")
        XCTAssertTrue(try XCTUnwrap(data.presentation(for: selected)).isPinned)
        selected.isPinned = false
        try fixture.context.save()
        try await awaitCondition { data.presentations.isEmpty }
        data.configure(search: "Historical preview")
        XCTAssertEqual(data.presentations.count, 30)
        data.configure(search: "")
        XCTAssertTrue(data.presentations.isEmpty)
    }

    func testMessageCellUpdatesTitleTimestampSelectionAndNativeSelectionAction() async throws {
        let fixture = try Fixture()
        let workspace = fixture.workspace()
        let first = fixture.chat(workspace, name: "Original", date: now)
        let second = fixture.chat(workspace, name: "Replacement", date: now)
        let latest = fixture.message()
        latest.chat = first
        latest.kind = MessageKind.message.rawValue
        latest.body = "Prepared preview"
        latest.timestamp = now
        try fixture.context.save()
        let data = store(workspace, fixture)
        data.configure(search: "")
        var selectedChat: ChatEntity?
        func cell(_ chat: ChatEntity, _ presentation: SidebarConversationPresentation) -> MessageCell {
            MessageCell(chatObjectID: chat.objectID, presentation: presentation,
                showsAttentionIndicator: false, activitySnapshot: nil,
                isActive: selectedChat?.objectID == chat.objectID, searchText: "",
                onSelect: { selectedChat = chat })
        }
        let initial = try XCTUnwrap(data.presentation(for: first))
        let original = cell(first, initial)
        first.name = "Renamed"
        try fixture.context.save()
        try await awaitCondition { data.presentation(for: first)?.title == "Renamed" }
        let renamed = try XCTUnwrap(data.presentation(for: first))
        XCTAssertNotEqual(original, cell(first, renamed), "A prepared title edit must invalidate the leaf")
        latest.timestamp = now.addingTimeInterval(1)
        try fixture.context.save()
        try await awaitCondition { data.presentation(for: first)?.timestamp == self.now.addingTimeInterval(1) }
        let dated = try XCTUnwrap(data.presentation(for: first))
        XCTAssertNotEqual(cell(first, renamed), cell(first, dated), "Current timestamps must not be retained as local State")
        let inactive = cell(first, dated)
        selectedChat = first
        XCTAssertNotEqual(inactive, cell(first, dated), "Selection comparison must use captured scalar values")
        selectedChat = nil
        let host = NSHostingView(rootView: cell(first, dated).equatable().frame(width: 300, height: 64))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = host
        window.orderFront(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        func mountedButton(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton { return button }
            return view.subviews.lazy.compactMap(mountedButton).first
        }
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        try XCTUnwrap(mountedButton(host)).performClick(nil)
        XCTAssertTrue(selectedChat === first, "The mounted native button must dispatch the SwiftUI selection action")
        host.rootView = cell(second, try XCTUnwrap(data.presentation(for: second))).equatable().frame(width: 300, height: 64)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        try XCTUnwrap(mountedButton(host)).performClick(nil)
        XCTAssertTrue(selectedChat === second, "Reusing the host with another identity must not dispatch the old action")
    }

    func testNormalizedSymbolsPreserveValidInvalidAndOverlayChoices() {
        XCTAssertTrue(PersonaAppearance.isValidSymbol(" person.fill "))
        XCTAssertFalse(PersonaAppearance.isValidSymbol("  "))
        XCTAssertFalse(PersonaAppearance.isValidSymbol("no.such.synthetic.symbol"))
        XCTAssertFalse(PersonaAppearance.isValidSymbol(" no.such.synthetic.symbol "))
        XCTAssertEqual(PersonaAppearance.validatedSymbol(" person.fill ", fallback: "star.fill"), "person.fill")
        XCTAssertEqual(PersonaAppearance.validatedSymbol("no.such.synthetic.symbol", fallback: "star.fill"), "star.fill")
        let valid = SidebarConversationPresentation(chatName: "Title", personaColor: nil,
            personaSymbolName: "person.fill", personaOverlaySymbolName: " star.fill ")
        XCTAssertEqual(valid.overlaySymbolName, "star.fill")
        let invalid = SidebarConversationPresentation(chatName: "Title", personaColor: nil,
            personaSymbolName: "no.such.synthetic.symbol", personaOverlaySymbolName: "no.such.synthetic.symbol")
        XCTAssertEqual(invalid.symbolName, PersonaAppearance.defaultSymbol)
        XCTAssertNil(invalid.overlaySymbolName)
    }

    func testExclusiveCalendarBoundariesAndMissingDateFallback() throws {
        let dates = SidebarChatDates(now: now, calendar: calendar)
        XCTAssertEqual(dates.week, now.addingTimeInterval(-7 * 86400))
        XCTAssertEqual(dates.month, ISO8601DateFormatter().date(from: "2026-10-10T12:00:00Z"))
        XCTAssertEqual(dates.twoMonths, ISO8601DateFormatter().date(from: "2026-09-10T12:00:00Z"))
        let fixture = try Fixture()
        let workspace = fixture.workspace()
        let values: [(Date?, SidebarChatDates.Bucket)] = [
            (now, .recent), (dates.week, .recent), (dates.week.addingTimeInterval(-1), .week),
            (dates.month, .week), (dates.month.addingTimeInterval(-1), .month),
            (dates.twoMonths, .month), (dates.twoMonths.addingTimeInterval(-1), .older), (nil, .older)
        ]
        for (index, value) in values.enumerated() {
            let chat = fixture.chat(workspace, name: "Boundary \(index)", date: value.0)
            if index.isMultiple(of: 2) { chat.createdDate = value.0; chat.updatedDate = nil }
            else { chat.createdDate = .distantPast }
            XCTAssertEqual(dates.bucket(for: chat.updatedDate ?? chat.createdDate), value.1)
        }
        try fixture.context.save()
        for bucket in SidebarChatDates.Bucket.allCases {
            let request = NSFetchRequest<ChatEntity>(entityName: "ChatEntity")
            request.predicate = dates.predicate(for: bucket)
            let names = try fixture.context.fetch(request).map(\.name).sorted()
            let expected = values.enumerated().filter { $0.element.1 == bucket }.map { "Boundary \($0.offset)" }.sorted()
            XCTAssertEqual(names, expected, "SQLite predicate must agree with the calendar classification")
        }
    }

    func testNineChatsBypassGroupingAndTenEnableItPerWorkspace() async throws {
        let fixture = try Fixture()
        let temporary = fixture.workspace(temporary: true)
        let regular = fixture.workspace()
        for index in 0..<9 { fixture.chat(temporary, name: "Temporary \(index)", date: .distantPast) }
        for index in 0..<10 { fixture.chat(regular, name: "Regular \(index)", date: .distantPast) }
        try fixture.context.save()
        let data = store(temporary, fixture)
        let other = store(regular, fixture)
        data.configure(search: "")
        other.configure(search: "")
        XCTAssertFalse(data.isGrouped)
        XCTAssertEqual(data.chats(in: .all).count, 9)
        XCTAssertTrue(other.isGrouped)
        XCTAssertEqual(other.olderCount, 10)
        XCTAssertTrue(other.chats(in: .older).isEmpty)
        let tenth = fixture.chat(temporary, name: "Tenth", date: now)
        try fixture.context.save()
        try await awaitCondition { data.totalCount == 10 }
        XCTAssertTrue(data.isGrouped)
        XCTAssertEqual(data.chats(in: .recent).map(\.objectID), [tenth.objectID])
        XCTAssertTrue(data.chats(in: .all).isEmpty)
        fixture.context.delete(tenth)
        try fixture.context.save()
        try await awaitCondition { data.totalCount == 9 }
        XCTAssertFalse(data.isGrouped)
        XCTAssertEqual(data.chats(in: .all).count, 9)
    }

    func testCollapsedMoreDoesNotFetchOldRowsAndExpansionPagesThirty() throws {
        let fixture = try Fixture()
        let workspace = fixture.workspace()
        for index in 0..<65 {
            let chat = fixture.chat(workspace, name: "Old \(index)", date: now.addingTimeInterval(-100 * 86400 - Double(index)))
            if index.isMultiple(of: 2) { chat.createdDate = chat.updatedDate; chat.updatedDate = nil }
        }
        try fixture.context.save()
        let savedID = workspace.objectID
        fixture.context.reset()
        let restored = try XCTUnwrap(fixture.context.existingObject(with: savedID) as? WorkspaceEntity)
        let data = store(restored, fixture)
        data.configure(search: "")
        XCTAssertNil(data.error)
        XCTAssertEqual(data.olderCount, 65)
        XCTAssertFalse(data.moreExpanded)
        XCTAssertTrue(data.chats(in: .older).isEmpty)
        XCTAssertFalse(fixture.context.registeredObjects.contains { $0 is ChatEntity }, "Count-only More must not register historical chat objects")
        data.setMoreExpanded(true)
        XCTAssertEqual(data.chats(in: .older).count, 30)
        XCTAssertEqual(data.chats(in: .older).map(\.name), (0..<30).map { "Old \($0)" })
        data.loadNext(.older)
        XCTAssertEqual(data.chats(in: .older).count, 60)
        data.loadNext(.older)
        XCTAssertEqual(data.chats(in: .older).count, 65)
        XCTAssertFalse(data.hasMore(in: .older))
        XCTAssertEqual(Set(data.chats(in: .older).map(\.objectID)).count, 65)
        data.setMoreExpanded(false)
        XCTAssertTrue(data.chats(in: .older).isEmpty)
        data.loadNext(.older)
        XCTAssertTrue(data.chats(in: .older).isEmpty)
        data.setMoreExpanded(true)
        XCTAssertEqual(data.chats(in: .older).count, 30, "Reopening starts with one bounded page")
    }

    func testPinnedOldChatsRemainFirstAndSelectedUnpagedChatStaysReachable() throws {
        let fixture = try Fixture()
        let workspace = fixture.workspace()
        let pinned = fixture.chat(workspace, name: "Pinned old", date: .distantPast)
        pinned.isPinned = true
        for index in 0..<40 { fixture.chat(workspace, name: "Old \(index)", date: now.addingTimeInterval(-100 * 86400 - Double(index))) }
        let recent = fixture.chat(workspace, name: "Recent", date: now)
        let selected = fixture.chat(workspace, name: "Selected oldest", date: .distantPast)
        try fixture.context.save()
        let data = store(workspace, fixture)
        data.configure(search: "")
        XCTAssertEqual(data.chats(in: .pinned).map(\.objectID), [pinned.objectID])
        XCTAssertEqual(data.chats(in: .recent).map(\.objectID), [recent.objectID])
        XCTAssertEqual(data.olderCount, 41, "Pinned chats must not be duplicated in dated buckets")
        XCTAssertEqual(data.selectionOutsidePages(selected), selected)
        XCTAssertNil(data.selectionOutsidePages(pinned))
        data.setMoreExpanded(true)
        data.setMoreExpanded(false)
        XCTAssertEqual(data.selectionOutsidePages(selected), selected)
        XCTAssertFalse(data.moreExpanded, "Selection must not override a deliberate collapse")
    }

    func testPinnedChatsBeyondOnePageRemainReadilyAvailable() throws {
        let fixture = try Fixture()
        let workspace = fixture.workspace()
        for index in 0..<44 {
            let chat = fixture.chat(workspace, name: "Pinned \(index)", date: .distantPast)
            chat.isPinned = true
        }
        try fixture.context.save()
        let data = store(workspace, fixture)
        data.configure(search: "")
        XCTAssertNil(data.error)
        XCTAssertEqual(data.chats(in: .pinned).count, 44)
        XCTAssertFalse(data.hasMore(in: .pinned))
        XCTAssertEqual(data.olderCount, 0)
        XCTAssertTrue(data.chats(in: .older).isEmpty)
    }

    func testSearchFindsOldTitlePersonaAndMessageMatchesWithoutMore() throws {
        let fixture = try Fixture()
        let workspace = fixture.workspace()
        for index in 0..<35 { fixture.chat(workspace, name: "Unrelated \(index)", date: now) }
        let title = fixture.chat(workspace, name: "Café title", date: .distantPast)
        let persona = fixture.chat(workspace, name: "Persona match", date: .distantPast)
        let assistant = fixture.persona()
        assistant.id = UUID()
        assistant.name = "CAFÉ assistant"
        persona.persona = assistant
        let messageChat = fixture.chat(workspace, name: "Message match", date: .distantPast)
        let message = fixture.message()
        message.body = "A café message from long ago"
        message.chat = messageChat
        message.sequence = 1
        let otherWorkspace = fixture.workspace()
        fixture.chat(otherWorkspace, name: "Café elsewhere", date: now)
        try fixture.context.save()
        let data = store(workspace, fixture)
        data.configure(search: "cafe")
        XCTAssertNil(data.error)
        XCTAssertFalse(data.isGrouped)
        XCTAssertFalse(data.moreExpanded)
        XCTAssertEqual(Set(data.chats(in: .search).map(\.objectID)), Set([title, persona, messageChat].map(\.objectID)))
        XCTAssertNil(data.selectionOutsidePages(messageChat), "Search must not leak nonmatching selected rows into results")
    }

    func testDatePinMoveAndUnloadedDeletionRefreshReactively() async throws {
        let fixture = try Fixture()
        let workspace = fixture.workspace()
        let destination = fixture.workspace()
        var chats: [ChatEntity] = []
        for index in 0..<12 { chats.append(fixture.chat(workspace, name: "Old \(index)", date: .distantPast)) }
        try fixture.context.save()
        let data = store(workspace, fixture)
        let other = store(destination, fixture)
        data.configure(search: "")
        other.configure(search: "")
        chats[0].updatedDate = now
        chats[1].isPinned = true
        chats[2].workspace = destination
        fixture.context.delete(chats[3])
        try fixture.context.save()
        try await awaitCondition { data.totalCount == 10 && other.totalCount == 1 }
        XCTAssertNil(data.error)
        XCTAssertEqual(data.totalCount, 10)
        XCTAssertEqual(data.chats(in: .recent).map(\.objectID), [chats[0].objectID])
        XCTAssertEqual(data.chats(in: .pinned).map(\.objectID), [chats[1].objectID])
        XCTAssertEqual(data.olderCount, 8)
        XCTAssertEqual(other.chats(in: .all).map(\.objectID), [chats[2].objectID])
        chats[1].isPinned = false
        chats[0].updatedDate = now.addingTimeInterval(-10 * 86400)
        try fixture.context.save()
        try await awaitCondition { data.olderCount == 9 && data.chats(in: .week).count == 1 }
        XCTAssertTrue(data.chats(in: .pinned).isEmpty)
        XCTAssertTrue(data.chats(in: .recent).isEmpty)
        XCTAssertEqual(data.chats(in: .week).map(\.objectID), [chats[0].objectID])
        XCTAssertEqual(data.olderCount, 9)
    }

    func testRecentAndSearchPagesHaveStableTiesAndNoDuplicates() throws {
        let fixture = try Fixture()
        let workspace = fixture.workspace()
        var chats: [ChatEntity] = []
        for index in 0..<65 {
            let chat = fixture.chat(workspace, name: "Match \(index)", date: now)
            if index.isMultiple(of: 2) { chat.updatedDate = nil; chat.createdDate = now }
            chats.append(chat)
        }
        try fixture.context.save()
        let data = store(workspace, fixture)
        data.configure(search: "")
        XCTAssertEqual(data.chats(in: .recent).count, 30)
        while data.hasMore(in: .recent) { data.loadNext(.recent) }
        XCTAssertEqual(data.chats(in: .recent).map(\.id), chats.sorted { $0.id.uuidString < $1.id.uuidString }.map(\.id))
        chats[64].isPinned = true
        try fixture.context.save()
        data.configure(search: "Match")
        XCTAssertEqual(data.chats(in: .search).first, chats[64])
        while data.hasMore(in: .search) { data.loadNext(.search) }
        XCTAssertEqual(Set(data.chats(in: .search).map(\.id)).count, 65)
    }

    func testBoundedMetadataRestoresSelectionAndPreservesCreationDeletionCounts() throws {
        let fixture = try Fixture()
        let workspace = fixture.workspace()
        for index in 0..<65 { fixture.chat(workspace, name: "History \(index)", date: .distantPast) }
        let restored = fixture.chat(workspace, name: "Restored selection", date: now)
        restored.gptModel = "restored-model"
        let restoredID = restored.id
        try fixture.context.save()
        let permanentWorkspaceID = workspace.objectID
        XCTAssertFalse(permanentWorkspaceID.isTemporaryID)
        fixture.context.reset()
        XCTAssertEqual(try SidebarChatLookup.count(in: fixture.context), 66)
        XCTAssertFalse(fixture.context.registeredObjects.contains { $0 is ChatEntity })
        let selected = try XCTUnwrap(SidebarChatLookup.chat(id: restoredID, in: fixture.context))
        XCTAssertEqual(selected.name, "Restored selection")
        XCTAssertEqual(fixture.context.registeredObjects.filter { $0 is ChatEntity }.count, 1)
        let restoredWorkspace = try XCTUnwrap(fixture.context.existingObject(with: permanentWorkspaceID) as? WorkspaceEntity)
        let justInserted = fixture.chat(restoredWorkspace, name: "New chat", date: now.addingTimeInterval(1))
        XCTAssertEqual(try SidebarChatLookup.latest(excluding: justInserted.id, in: fixture.context)?.gptModel, "restored-model")

        let empty = try Fixture()
        let temporary = empty.workspace(temporary: true)
        XCTAssertEqual(try SidebarChatLookup.count(in: empty.context), 0)
        let first = empty.chat(temporary, name: "First", date: now)
        let firstID = first.id
        try empty.context.save()
        XCTAssertEqual(try SidebarChatLookup.count(in: empty.context), 1)
        empty.context.delete(first)
        try empty.context.save()
        XCTAssertEqual(try SidebarChatLookup.count(in: empty.context), 0)
        XCTAssertNil(try SidebarChatLookup.chat(id: firstID, in: empty.context))
    }

    func testNativeMoreDisclosureExpandsScrollsAndCollapsesInIsolatedWindow() async throws {
        let fixture = try Fixture()
        let workspace = fixture.workspace(temporary: true)
        for index in 0..<65 {
            fixture.chat(workspace, name: String(format: "Historical %03d", index), date: Date().addingTimeInterval(-100 * 86400 - Double(index)))
        }
        try fixture.context.save()
        let workspaceID = workspace.objectID
        fixture.context.reset()
        let restored = try XCTUnwrap(fixture.context.existingObject(with: workspaceID) as? WorkspaceEntity)
        let data = SidebarWorkspaceChats(workspace: restored, context: fixture.context)
        let host = NSHostingView(rootView: ScrollView {
            WorkspaceChatRows(workspace: restored, context: fixture.context, selectedChat: .constant(nil), searchText: "", data: data)
                .padding(12)
        }.environmentObject(ChatActivityStore.shared))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 420),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.title = "Sidebar history regression fixture"
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(data.olderCount, 65)
        XCTAssertTrue(data.chats(in: .older).isEmpty)
        XCTAssertFalse(fixture.context.registeredObjects.contains { $0 is ChatEntity })
        XCTAssertFalse(accessibilityText(host).contains("Historical 000"))
        XCTAssertFalse(accessibilityText(host).contains("Previous Week"))
        XCTAssertFalse(accessibilityText(host).contains("Previous Month"))
        attach(host, name: "More collapsed — isolated fixture")
        try pressMore(in: host, window: window)
        try await awaitCondition { data.moreExpanded }
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(data.moreExpanded)
        XCTAssertEqual(data.chats(in: .older).count, 30, "Offscreen pagination must not drain all history on expansion")
        attach(host, name: "More expanded — first page")
        let scroll = try XCTUnwrap(findScrollView(host))
        for _ in 0..<3 {
            let document = try XCTUnwrap(scroll.documentView)
            document.scroll(NSPoint(x: 0, y: document.bounds.maxY))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(for: .milliseconds(200))
            host.layoutSubtreeIfNeeded()
        }
        XCTAssertEqual(data.chats(in: .older).count, 65)
        XCTAssertFalse(data.hasMore(in: .older))
        attach(host, name: "More expanded — final page after scrolling")
        scroll.documentView?.scroll(.zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        try pressMore(in: host, window: window)
        try await awaitCondition { !data.moreExpanded }
        XCTAssertFalse(data.moreExpanded)
        XCTAssertTrue(data.chats(in: .older).isEmpty)
        XCTAssertFalse(accessibilityText(host).contains("Historical 000"))
        XCTAssertFalse(accessibilityText(host).contains("Historical 064"))
        attach(host, name: "More collapsed again")
    }

    private func pressMore(in host: NSView, window: NSWindow) throws {
        // The fixture's captured native disclosure is 16 points from the left and 22 from the top.
        // Use the actual AppKit event path instead of relying on an SDK-specific accessibility tree.
        let point = host.convert(NSPoint(x: 16, y: host.isFlipped ? 22 : host.bounds.height - 22), to: nil)
        try clickNative(at: point, in: window)
        print("Sidebar More activated through native disclosure click")
    }

    private func awaitCondition(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(condition(), "Reactive sidebar update did not arrive within three seconds")
    }

    private func store(_ workspace: WorkspaceEntity, _ fixture: Fixture) -> SidebarWorkspaceChats {
        SidebarWorkspaceChats(workspace: workspace, context: fixture.context, now: { self.now }, calendar: calendar)
    }

    private func accessibilityNodes(_ root: AnyObject) -> [any NSAccessibilityProtocol] {
        var visited = Set<ObjectIdentifier>()
        func walk(_ object: AnyObject) -> [any NSAccessibilityProtocol] {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return [] }
            var nodes: [any NSAccessibilityProtocol] = []
            if let node = object as? any NSAccessibilityProtocol {
                nodes.append(node)
                nodes += (node.accessibilityChildren() ?? []).flatMap { walk($0 as AnyObject) }
            }
            if let view = object as? NSView { nodes += view.subviews.flatMap { walk($0) } }
            return nodes
        }
        return walk(root)
    }

    private func accessibilityText(_ host: AnyObject) -> String {
        accessibilityNodes(host).map { ($0.accessibilityValue() as? String ?? "") + ($0.accessibilityLabel() ?? "") }.joined(separator: "\n")
    }

    private func findScrollView(_ view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap(findScrollView).first
    }

    private func attach(_ host: NSView, name: String) {
        guard ProcessInfo.processInfo.environment["SIDEBAR_TEST_CAPTURE_WINDOWS"] == "1" else { return }
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private final class Fixture {
        let context: NSManagedObjectContext
        let directory: URL
        init(model: NSManagedObjectModel? = nil) throws {
            if let expectedHome = ProcessInfo.processInfo.environment["SIDEBAR_TEST_HOME"] {
                XCTAssertEqual(FileManager.default.homeDirectoryForCurrentUser.path, expectedHome)
                XCTAssertTrue(AppConstants.persistentStoreURL.path.hasPrefix(expectedHome + "/"))
                XCTAssertEqual(Bundle.main.bundleIdentifier, ProcessInfo.processInfo.environment["SIDEBAR_TEST_BUNDLE_ID"])
                print("Sidebar isolation: bundle=\(Bundle.main.bundleIdentifier ?? "unknown"); home=\(FileManager.default.homeDirectoryForCurrentUser.path); appStore=\(AppConstants.persistentStoreURL.path)")
            }
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("SidebarConversationTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let model = model ?? PersistenceController.shared.container.managedObjectModel
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
            try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil,
                                               at: directory.appendingPathComponent("fixture.sqlite"))
            context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
            context.persistentStoreCoordinator = coordinator
        }
        deinit {
            context.reset()
            do {
                if let coordinator = context.persistentStoreCoordinator {
                    for store in coordinator.persistentStores { try coordinator.remove(store) }
                }
                try FileManager.default.removeItem(at: directory)
            } catch { XCTFail("Fixture cleanup failed: \(error.localizedDescription)") }
        }

        func persona() -> PersonaEntity {
            PersonaEntity(entity: NSEntityDescription.entity(forEntityName: "PersonaEntity", in: context)!, insertInto: context)
        }

        func message() -> MessageEntity {
            MessageEntity(entity: NSEntityDescription.entity(forEntityName: "MessageEntity", in: context)!, insertInto: context)
        }

        func workspace(temporary: Bool = false) -> WorkspaceEntity {
            let workspace = WorkspaceEntity(entity: NSEntityDescription.entity(forEntityName: "WorkspaceEntity", in: context)!, insertInto: context)
            workspace.id = UUID()
            workspace.name = temporary ? "Temporary Chats" : "Workspace"
            workspace.path = directory.path
            workspace.isTemporary = temporary
            return workspace
        }

        @discardableResult
        func chat(_ workspace: WorkspaceEntity, name: String, date: Date?) -> ChatEntity {
            let chat = ChatEntity(entity: NSEntityDescription.entity(forEntityName: "ChatEntity", in: context)!, insertInto: context)
            chat.id = UUID()
            chat.name = name
            chat.workspace = workspace
            chat.createdDate = date
            chat.updatedDate = date
            chat.requestMessages = []
            chat.systemMessage = ""
            chat.gptModel = "test"
            return chat
        }
    }
}
