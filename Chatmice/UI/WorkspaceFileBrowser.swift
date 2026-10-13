import AppKit
import SwiftUI

struct WorkspaceDirectoryEntry: Sendable {
    let url: URL
    let isDirectory: Bool
    let isSymbolicLink: Bool
}

@MainActor
final class WorkspaceFileTree: ObservableObject {
    final class Node: NSObject {
        let url: URL
        let isDirectory: Bool
        let isSymbolicLink: Bool
        var children: [Node]?
        var isLoading = false

        init(url: URL, isDirectory: Bool, isSymbolicLink: Bool = false) {
            self.url = url
            self.isDirectory = isDirectory
            self.isSymbolicLink = isSymbolicLink
        }
    }

    @Published private(set) var revision = 0
    @Published private(set) var error: String?
    @Published private(set) var isLoading = false
    private(set) var root: Node?
    private var nodes: [String: Node] = [:]
    private var generation = 0

    static nonisolated func directoryEntries(at directory: URL, root: URL) async throws -> [WorkspaceDirectoryEntry] {
        try await Task.detached(priority: .userInitiated) {
            guard WorkspacePathPolicy.contains(directory, in: root) else { throw WorkspacePathError.outsideWorkspace(root.path) }
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
            return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
                .map { url in
                    let values = try url.resourceValues(forKeys: keys)
                    return WorkspaceDirectoryEntry(url: url.standardizedFileURL,
                        isDirectory: values.isDirectory == true && values.isSymbolicLink != true && values.isPackage != true,
                        isSymbolicLink: values.isSymbolicLink == true)
                }
                .sorted {
                    if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                    return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
                }
        }.value
    }

    func observe(rootURL: URL) async {
        generation += 1
        let current = generation
        nodes.removeAll()
        error = nil
        let rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let rootNode = Node(url: rootURL, isDirectory: true)
        root = rootNode
        nodes[rootURL.path] = rootNode
        revision += 1
        let watcher = WorkspaceReferenceWatcher(root: rootURL)
        await load(rootNode, generation: current)
        guard !Task.isCancelled, generation == current, let watcher else { return }
        for await _ in watcher.changes {
            guard !Task.isCancelled, generation == current else { return }
            await refresh()
        }
    }

    func loadIfNeeded(_ node: Node) {
        guard node.isDirectory, node.children == nil, !node.isLoading else { return }
        node.isLoading = true
        let current = generation
        Task { await load(node, generation: current) }
    }

    private func load(_ node: Node, generation current: Int) async {
        guard let root else { return }
        node.isLoading = true
        if node === root { isLoading = true }
        do {
            let entries = try await Self.directoryEntries(at: node.url, root: root.url)
            guard !Task.isCancelled, generation == current else { return }
            node.children = makeNodes(entries)
            error = nil
        } catch {
            guard !Task.isCancelled, generation == current else { return }
            node.children = []
            self.error = "\(node.url.lastPathComponent): \(error.localizedDescription)"
        }
        node.isLoading = false
        isLoading = false
        revision += 1
    }

    func refresh() async {
        guard let root else { return }
        let current = generation
        let loadedDirectories = nodes.values.filter { $0.isDirectory && $0.children != nil && !$0.isLoading }
        for directory in loadedDirectories {
            guard !Task.isCancelled, generation == current else { return }
            await load(directory, generation: current)
        }
        // Drop removed subtrees so cached directories cannot accumulate across filesystem edits.
        var reachable: [String: Node] = [:]
        func visit(_ node: Node) {
            reachable[node.url.path] = node
            for child in node.children ?? [] { visit(child) }
        }
        guard generation == current else { return }
        visit(root)
        nodes = reachable
    }

    private func makeNodes(_ entries: [WorkspaceDirectoryEntry]) -> [Node] {
        entries.map { entry in
            if let node = nodes[entry.url.path], node.isDirectory == entry.isDirectory,
               node.isSymbolicLink == entry.isSymbolicLink { return node }
            let node = Node(url: entry.url, isDirectory: entry.isDirectory, isSymbolicLink: entry.isSymbolicLink)
            nodes[entry.url.path] = node
            return node
        }
    }
}

struct WorkspaceFileBrowser: View {
    @ObservedObject var workspace: WorkspaceEntity
    @StateObject private var tree = WorkspaceFileTree()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label(workspace.name, systemImage: "folder")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if tree.isLoading { ProgressView().controlSize(.mini) }
                Button { Task { await tree.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain)
                    .help("Refresh workspace files")
                    .accessibilityIdentifier("workspace-files-refresh")
            }
            .padding(12)
            Text(workspace.path)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .help(workspace.path)
            Divider()
            WorkspaceFileOutline(tree: tree)
                .overlay {
                    if tree.root?.children?.isEmpty == true && tree.error == nil && !tree.isLoading {
                        ContentUnavailableView("Empty Folder", systemImage: "folder")
                    }
                }
            if let error = tree.error {
                Text(error).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("workspace-file-browser")
        .task(id: workspace.rootURL.path) { await tree.observe(rootURL: workspace.rootURL) }
    }
}

private struct WorkspaceFileOutline: NSViewRepresentable {
    @ObservedObject var tree: WorkspaceFileTree

    func makeCoordinator() -> Coordinator { Coordinator(tree: tree) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = FileOutlineView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.backgroundColor = .clear
        outline.rowHeight = 26
        outline.indentationPerLevel = 14
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.target = context.coordinator
        outline.doubleAction = #selector(Coordinator.activate(_:))
        outline.onPreview = { [weak coordinator = context.coordinator] in coordinator?.preview() }
        outline.onOpen = { [weak coordinator = context.coordinator] in coordinator?.open() }
        outline.menu = context.coordinator.makeMenu()
        outline.setDraggingSourceOperationMask(.copy, forLocal: true)
        outline.setAccessibilityIdentifier("workspace-file-tree")
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = outline
        context.coordinator.outline = outline
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.tree = tree
        guard context.coordinator.revision != tree.revision, let outline = context.coordinator.outline else { return }
        let expanded = (0..<outline.numberOfRows).compactMap { row -> WorkspaceFileTree.Node? in
            guard let node = outline.item(atRow: row) as? WorkspaceFileTree.Node, outline.isItemExpanded(node) else { return nil }
            return node
        }
        let selected = outline.item(atRow: outline.selectedRow) as? WorkspaceFileTree.Node
        let origin = scroll.contentView.bounds.origin
        context.coordinator.revision = tree.revision
        outline.reloadData()
        for node in expanded { outline.expandItem(node) }
        if let selected {
            let row = outline.row(forItem: selected)
            if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        }
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        var tree: WorkspaceFileTree
        weak var outline: FileOutlineView?
        var revision = -1
        init(tree: WorkspaceFileTree) { self.tree = tree }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let node = item as? WorkspaceFileTree.Node ?? tree.root else { return 0 }
            tree.loadIfNeeded(node)
            return node.children?.count ?? 0
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            let node = item as? WorkspaceFileTree.Node ?? tree.root!
            return node.children![index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? WorkspaceFileTree.Node)?.isDirectory == true
        }

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let node = item as? WorkspaceFileTree.Node, let root = tree.root,
                  WorkspacePathPolicy.contains(node.url, in: root.url) else { return nil }
            let item = NSPasteboardItem()
            item.setString(node.url.path, forType: WorkspaceReferenceTransfer.pasteboardType)
            return item
        }

        @objc func insertReference() {
            guard let node = selected, let outline else { return }
            NotificationCenter.default.post(name: WorkspaceReferenceTransfer.notification,
                                            object: outline.window, userInfo: ["path": node.url.path])
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? WorkspaceFileTree.Node else { return nil }
            let id = NSUserInterfaceItemIdentifier("file-cell")
            let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? makeCell(id: id)
            cell.textField?.stringValue = node.url.lastPathComponent
            cell.imageView?.image = NSWorkspace.shared.icon(forFile: node.url.path)
            cell.toolTip = node.url.path
            return cell
        }

        private func makeCell(id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = id
            let icon = NSImageView()
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 12)
            label.lineBreakMode = .byTruncatingMiddle
            icon.translatesAutoresizingMaskIntoConstraints = false
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(icon)
            cell.addSubview(label)
            cell.imageView = icon
            cell.textField = label
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            ])
            return cell
        }

        private var selected: WorkspaceFileTree.Node? {
            guard let outline, outline.selectedRow >= 0 else { return nil }
            return outline.item(atRow: outline.selectedRow) as? WorkspaceFileTree.Node
        }

        @objc func activate(_ sender: Any?) {
            guard let node = selected, let outline else { return }
            if node.isDirectory {
                if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
            } else { preview() }
        }

        @objc func preview() {
            guard let node = selected, !node.isDirectory, let root = tree.root,
                  WorkspacePathPolicy.contains(node.url, in: root.url) else { return }
            QuickLookPreviewer.shared.preview(url: node.url)
        }

        @objc func open() {
            guard let node = selected, let root = tree.root,
                  WorkspacePathPolicy.contains(node.url, in: root.url) else { return }
            NSWorkspace.shared.open(node.url)
        }

        @objc func reveal() {
            guard let node = selected else { return }
            NSWorkspace.shared.activateFileViewerSelecting([node.url])
        }

        @objc func copyPath() {
            guard let node = selected, let root = tree.root else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(String(node.url.path.dropFirst(root.url.path.count + 1)), forType: .string)
        }

        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.delegate = self
            for (title, action) in [("Reference in Message", #selector(insertReference)),
                                    ("Quick Look", #selector(preview)), ("Open", #selector(open)),
                                    ("Reveal in Finder", #selector(reveal)), ("Copy Relative Path", #selector(copyPath))] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
            return menu
        }

        func menuWillOpen(_ menu: NSMenu) {
            guard let outline else { return }
            if outline.clickedRow >= 0 { outline.selectRowIndexes(IndexSet(integer: outline.clickedRow), byExtendingSelection: false) }
            for item in menu.items { item.isEnabled = selected != nil && (item.action != #selector(preview) || selected?.isDirectory == false) }
        }
    }
}

private final class FileOutlineView: NSOutlineView {
    var onPreview: (() -> Void)?
    var onOpen: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 { onPreview?() }
        else if event.keyCode == 36 { onOpen?() }
        else { super.keyDown(with: event) }
    }
}

