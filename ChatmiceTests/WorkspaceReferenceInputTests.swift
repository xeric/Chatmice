import AppKit
import CoreData
import SwiftUI
import XCTest
@testable import Chatmice

final class WorkspaceReferenceInputTests: XCTestCase {
    @MainActor
    func testReferenceKeyboardSelectionDoesNotSendAndPlacesCaretAfterPath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Chatmice-Reference-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("中文文档.txt"))
        try Data().write(to: root.appendingPathComponent("另一个.txt"))
        try Data().write(to: root.appendingPathComponent("中文第二.txt"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("目录"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: PersistenceController.shared.container.managedObjectModel)
        try coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        let workspace = WorkspaceEntity(context: context)
        workspace.id = UUID()
        workspace.name = "Reference input smoke"
        workspace.path = root.path
        let chat = ChatEntity(context: context)
        chat.id = UUID()
        chat.gptModel = "test"
        chat.systemMessage = ""
        chat.requestMessages = []
        chat.workspace = workspace
        try context.save()
        var draft = ""
        var sends = 0
        let view = MessageInputView(chat: chat, text: Binding(get: { draft }, set: { draft = $0 }),
                                    attachedImages: .constant([]), attachedFiles: .constant([]),
                                    isInferenceInProgress: false, imageUploadsAllowed: false,
                                    pdfUploadsAllowed: false, imageGenerationSupported: false,
                                    onEnter: { sends += 1 }, onAddImage: {}, onAddFile: {}, onStopInference: {})
            .environment(\.managedObjectContext, context)
            .environmentObject(PreviewStateManager())
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 700, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func findEditor(_ view: NSView) -> NSTextView? {
            if let textView = view as? NSTextView, textView.isEditable { return textView }
            return view.subviews.lazy.compactMap { findEditor($0) }.first
        }
        try await Task.sleep(for: .milliseconds(200))
        let editor = try XCTUnwrap(findEditor(host))
        window.makeFirstResponder(editor)
        editor.insertText("@", replacementRange: editor.selectedRange())
        try await Task.sleep(for: .milliseconds(500))
        editor.insertText("中文", replacementRange: editor.selectedRange())
        try await Task.sleep(for: .milliseconds(50))
        editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(sends, 0, "Return in the candidate list must not send the message")
        XCTAssertEqual(editor.string, "@中文第二.txt ", "Down must accept the second matching Chinese file")
        XCTAssertEqual(editor.selectedRange().location, (editor.string as NSString).length)
        let reference = editor.string
        editor.insertText("继续", replacementRange: editor.selectedRange())
        XCTAssertEqual(editor.string, reference + "继续", "Typing must continue after the complete reference")
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(sends, 1, "Return outside the candidate list must still send")
        editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
        editor.insertText("Before @目录 after", replacementRange: editor.selectedRange())
        editor.setSelectedRange(NSRange(location: ("Before @目录" as NSString).length, length: 0))
        try await Task.sleep(for: .milliseconds(300))
        let point = NSPoint(x: 45, y: host.isFlipped ? 40 : host.bounds.height - 40)
        let location = host.convert(point, to: nil)
        let mouseDown = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: location,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let mouseUp = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: location,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        // Mouse-down tracks synchronously; queue mouse-up so its tracking loop can consume it.
        NSApp.postEvent(mouseUp, atStart: true)
        window.sendEvent(mouseDown)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(editor.string, "Before @目录/  after")
        XCTAssertEqual(editor.selectedRange().location, ("Before @目录/ " as NSString).length)
        editor.insertText("继续", replacementRange: editor.selectedRange())
        XCTAssertEqual(editor.string, "Before @目录/ 继续 after")
        editor.setSelectedRange(NSRange(location: ("Before @目录/" as NSString).length, length: 0))
        editor.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        XCTAssertEqual(editor.string, "Before  继续 after", "Backspace must remove the complete folder reference")
        editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
        editor.insertText("@no-such-file", replacementRange: editor.selectedRange())
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(sends, 1, "An empty candidate list must not send accidentally")
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(sends, 2, "Escape must dismiss the list and restore normal Return behavior")
        editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
        editor.insertText("@中文", replacementRange: editor.selectedRange())
        editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
        editor.doCommand(by: #selector(NSResponder.moveUp(_:)))
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(editor.string, "@中文文档.txt ")
        editor.setSelectedRange(NSRange(location: ("@中文文档.txt" as NSString).length, length: 0))
        editor.doCommand(by: #selector(NSResponder.moveLeft(_:)))
        XCTAssertEqual(editor.selectedRange().location, 0, "Left must skip the entire reference")
        editor.doCommand(by: #selector(NSResponder.moveRight(_:)))
        XCTAssertEqual(editor.selectedRange().location, ("@中文文档.txt" as NSString).length)
        editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
        editor.setMarkedText("@中", selectedRange: NSRange(location: 2, length: 0), replacementRange: editor.selectedRange())
        let consumed = editor.delegate?.textView?(editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(consumed, false, "Return must stay with the input method while composing")
        XCTAssertEqual(sends, 2)
        editor.unmarkText()
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        editor.insertText("", replacementRange: editor.selectedRange())
        try await Task.sleep(for: .milliseconds(100))
        let createdFile = root.appendingPathComponent("新建.md")
        try Data("new file".utf8).write(to: createdFile)
        editor.insertText("@新建", replacementRange: editor.selectedRange())
        try await Task.sleep(for: .milliseconds(500))
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(editor.string, "@新建.md ", "Reopening @ must discover newly created files in the same workspace")
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        editor.insertText("@", replacementRange: editor.selectedRange())
        try await Task.sleep(for: .milliseconds(300))
        let nestedFolder = root.appendingPathComponent("目录/新子目录", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedFolder, withIntermediateDirectories: true)
        let nestedFile = nestedFolder.appendingPathComponent("刚创建.txt")
        try Data().write(to: nestedFile)
        try await Task.sleep(for: .milliseconds(800))
        editor.insertText("刚创建", replacementRange: editor.selectedRange())
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(editor.string, "@目录/新子目录/刚创建.txt ", "An open @ list must notice nested directory creation")
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        editor.insertText("@刚创建", replacementRange: editor.selectedRange())
        try await Task.sleep(for: .milliseconds(300))
        try FileManager.default.removeItem(at: nestedFile)
        try await Task.sleep(for: .milliseconds(800))
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(editor.string, "@刚创建", "Deleted files must disappear while the candidate list is open")
        XCTAssertEqual(sends, 2)
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        editor.insertText("@新建", replacementRange: editor.selectedRange())
        let otherRoot = root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        try Data().write(to: otherRoot.appendingPathComponent("新建-other.txt"))
        workspace.path = otherRoot.path
        try context.save()
        try await Task.sleep(for: .milliseconds(500))
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(editor.string, "@新建-other.txt ", "Changing the workspace path must replace the old listing")
    }
}

extension WorkspaceReferenceInputTests {
    @MainActor
    func testWorkspaceFileTreeLoadsExpandedDirectoriesAndTracksDiskChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Chatmice-Tree-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("资料", isDirectory: true)
        let nested = folder.appendingPathComponent("子目录", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("README.md"))
        try Data().write(to: root.appendingPathComponent(".hidden"))
        let file = nested.appendingPathComponent("中文.txt")
        try Data("hello".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("outside"), withDestinationURL: URL(fileURLWithPath: "/tmp"))
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: PersistenceController.shared.container.managedObjectModel)
        try coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        let workspace = WorkspaceEntity(context: context)
        workspace.id = UUID()
        workspace.name = "Workspace files"
        workspace.path = root.path
        try context.save()
        let host = NSHostingView(rootView: WorkspaceFileBrowser(workspace: workspace, onClose: {}).environment(\.managedObjectContext, context))
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 320, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func findOutline(_ view: NSView) -> NSOutlineView? {
            if let outline = view as? NSOutlineView { return outline }
            return view.subviews.lazy.compactMap { findOutline($0) }.first
        }
        func waitUntil(_ predicate: () -> Bool) async throws {
            for _ in 0..<100 {
                if predicate() { return }
                try await Task.sleep(for: .milliseconds(30))
            }
            XCTFail("The actual file tree did not reach the requested state")
        }
        try await waitUntil { findOutline(host)?.numberOfRows == 4 }
        let outline = try XCTUnwrap(findOutline(host))
        func node(_ name: String) -> WorkspaceFileTree.Node? {
            (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? WorkspaceFileTree.Node }.first { $0.url.lastPathComponent == name }
        }
        let directory = try XCTUnwrap(node("资料"))
        XCTAssertNil(directory.children, "Collapsed directories must not be scanned eagerly")
        XCTAssertFalse(try XCTUnwrap(node("outside")).isDirectory, "Symlinks must not expand outside the workspace")
        XCTAssertNotNil(node(".hidden"), "The browser must include actual hidden files")
        outline.expandItem(directory)
        try await waitUntil { node("子目录") != nil }
        let child = try XCTUnwrap(node("子目录"))
        outline.expandItem(child)
        try await waitUntil { node("中文.txt") != nil }
        let selected = try XCTUnwrap(node("中文.txt"))
        outline.selectRowIndexes(IndexSet(integer: outline.row(forItem: selected)), byExtendingSelection: false)
        let added = nested.appendingPathComponent("新文件.md")
        try Data().write(to: added)
        try await waitUntil { node("新文件.md") != nil }
        XCTAssertTrue(outline.isItemExpanded(directory))
        XCTAssertTrue(outline.isItemExpanded(child))
        XCTAssertTrue(outline.item(atRow: outline.selectedRow) as? WorkspaceFileTree.Node === selected,
                      "A disk refresh must preserve the selected file")
        try FileManager.default.moveItem(at: added, to: nested.appendingPathComponent("已重命名.md"))
        try await waitUntil { node("已重命名.md") != nil && node("新文件.md") == nil }
        try FileManager.default.removeItem(at: file)
        try await waitUntil { node("中文.txt") == nil }
        workspace.path = nested.path
        try context.save()
        try await waitUntil { outline.numberOfRows == 1 && node("已重命名.md") != nil }
        XCTAssertNil(node("资料"), "Switching roots must discard the old tree")
    }
}

