import Foundation
import SwiftUI
import CoreServices

enum WorkspaceReferenceTransfer {
    static let pasteboardType = NSPasteboard.PasteboardType("com.chatmice.workspace-reference")
    static let notification = Notification.Name("InsertWorkspaceFileReference")
}

struct WorkspaceReference: Identifiable, Sendable {
    let relativePath: String
    let isDirectory: Bool

    var id: String { relativePath }
    var insertionText: String { "@\(relativePath)\(isDirectory ? "/" : "") " }
}

enum WorkspaceMentionQuery {
    static func replacementRange(in text: String, selection: NSRange? = nil) -> Range<String.Index>? {
        let selection = selection ?? NSRange(location: text.utf16.count, length: 0)
        guard selection.length == 0,
              let caret = Range(selection, in: text)?.lowerBound else { return nil }
        let beforeCaret = text[..<caret]
        guard let atIndex = beforeCaret.lastIndex(of: "@") else { return nil }
        if let previous = text[..<atIndex].last, !previous.isWhitespace { return nil }
        guard !text[text.index(after: atIndex)..<caret].contains(where: \Character.isWhitespace) else { return nil }
        let end = text[caret...].firstIndex(where: \Character.isWhitespace) ?? text.endIndex
        return atIndex..<end
    }

    static func value(in text: String, selection: NSRange? = nil) -> String? {
        guard let range = replacementRange(in: text, selection: selection) else { return nil }
        let caret = selection.flatMap { Range($0, in: text)?.lowerBound } ?? text.endIndex
        return String(text[text.index(after: range.lowerBound)..<caret])
    }
}

enum WorkspaceFileIndexer {
    static func entries(in root: URL, limit: Int = 2_000) async -> [WorkspaceReference] {
        await Task.detached(priority: .userInitiated) {
            scan(root: root, limit: limit)
        }.value
    }

    private static func scan(root: URL, limit: Int) -> [WorkspaceReference] {
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: canonicalRoot,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var references: [WorkspaceReference] = []
        references.reserveCapacity(min(limit, 256))
        while let url = enumerator.nextObject() as? URL, references.count < limit {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard WorkspacePathPolicy.contains(url, in: canonicalRoot) else {
                enumerator.skipDescendants()
                continue
            }
            let relativePath = String(url.standardizedFileURL.path.dropFirst(canonicalRoot.path.count + 1))
            guard !relativePath.isEmpty else { continue }
            references.append(
                WorkspaceReference(relativePath: relativePath, isDirectory: values.isDirectory == true)
            )
        }
        return references.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory && !$1.isDirectory }
            return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
    }
}

final class WorkspaceReferenceWatcher {
    let changes: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let stream: FSEventStreamRef

    init?(root: URL) {
        let channel = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        changes = channel.stream
        continuation = channel.continuation
        let box = Callback(continuation: channel.continuation)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                _ = Unmanaged<Callback>.fromOpaque(pointer).retain()
                return pointer
            }, release: { pointer in
                if let pointer { Unmanaged<Callback>.fromOpaque(pointer).release() }
            }, copyDescription: nil)
        guard let stream = FSEventStreamCreate(nil, { _, context, _, _, _, _ in
            guard let context else { return }
            Unmanaged<Callback>.fromOpaque(context).takeUnretainedValue().continuation.yield(())
        }, &context, [root.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)) else { return nil }
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.stream = stream
    }

    deinit {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        continuation.finish()
    }

    private final class Callback {
        let continuation: AsyncStream<Void>.Continuation
        init(continuation: AsyncStream<Void>.Continuation) { self.continuation = continuation }
    }
}

struct WorkspaceMentionSuggestionsView: View {
    @ObservedObject var workspace: WorkspaceEntity
    let references: [WorkspaceReference]
    let isLoading: Bool
    let selectedID: String?
    let onSelect: (WorkspaceReference) -> Void
    let onListingChange: ([WorkspaceReference]?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(workspace.name, systemImage: "folder")
                    .font(.caption.weight(.semibold))
                Spacer()
                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)

            Divider()

            if references.isEmpty && !isLoading {
                Text("No matching files or folders")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
            } else {
                ForEach(references.prefix(8)) { reference in
                    Button {
                        onSelect(reference)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: reference.isDirectory ? "folder" : "doc")
                                .foregroundStyle(reference.isDirectory ? Color.accentColor : .secondary)
                                .frame(width: 14)
                            Text(reference.relativePath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                        }
                        .font(.system(size: 12))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                        .background(reference.id == selectedID ? Color.accentColor.opacity(0.18) : .clear)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("workspace-reference-\(reference.id)")
                    .accessibilityAddTraits(reference.id == selectedID ? .isSelected : [])
                }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
        .task(id: workspace.rootURL.path) {
            let root = workspace.rootURL
            let watcher = WorkspaceReferenceWatcher(root: root)
            onListingChange(nil)
            let initial = await WorkspaceFileIndexer.entries(in: root)
            guard !Task.isCancelled else { return }
            onListingChange(initial)
            guard let watcher else { return }
            for await _ in watcher.changes {
                guard !Task.isCancelled else { return }
                let references = await WorkspaceFileIndexer.entries(in: root)
                guard !Task.isCancelled else { return }
                onListingChange(references)
            }
        }
    }
}
