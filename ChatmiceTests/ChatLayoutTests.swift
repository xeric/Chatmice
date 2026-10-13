import AppKit
import CoreData
import SwiftUI
import XCTest
@testable import Chatmice

final class ChatLayoutTests: XCTestCase {
    func testAutomaticScrollingDoesNotChangeFollowIntent() {
        var state = ChatScrollFollowState()
        state.phaseChanged(from: .idle, to: .animating, distanceFromBottom: 600)
        state.phaseChanged(from: .animating, to: .idle, distanceFromBottom: 600)
        XCTAssertTrue(state.followsBottom, "Content growth or a programmatic scroll must not count as user scrolling")

        state.detach()
        state.phaseChanged(from: .idle, to: .animating, distanceFromBottom: 0)
        state.phaseChanged(from: .animating, to: .idle, distanceFromBottom: 0)
        XCTAssertFalse(state.followsBottom, "Search/programmatic navigation must not resume following")
        state.followLatest()
        XCTAssertTrue(state.followsBottom)
    }

    func testUserScrollResumesFollowingOnlyAtBottom() {
        var state = ChatScrollFollowState()
        state.phaseChanged(from: .idle, to: .interacting, distanceFromBottom: 0)
        XCTAssertFalse(state.followsBottom)
        state.phaseChanged(from: .interacting, to: .decelerating, distanceFromBottom: 300)
        state.phaseChanged(from: .decelerating, to: .idle, distanceFromBottom: 24.1)
        XCTAssertFalse(state.followsBottom)
        state.phaseChanged(from: .idle, to: .interacting, distanceFromBottom: 24.1)
        state.phaseChanged(from: .interacting, to: .idle, distanceFromBottom: 24)
        XCTAssertTrue(state.followsBottom)
    }

    @MainActor
    func testRichTextWrappingAndCopyRemainStableAcrossUpdates() throws {
        let view = SelectableRichTextView()
        let content = NSAttributedString(
            string: String(repeating: "Selectable code and rich text should wrap without losing the selection.\n", count: 25),
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)]
        )
        view.setContent(content)
        let range = NSRange(location: 5, length: 24)
        view.setSelectedRange(range)
        let expectedSelection = (content.string as NSString).substring(with: range)
        let wide = view.measuredSize(for: 640)
        let narrow = view.measuredSize(for: 200)
        XCTAssertEqual(wide.width, 640)
        XCTAssertEqual(narrow.width, 200)
        XCTAssertGreaterThan(narrow.height, wide.height)
        for _ in 0..<12 {
            view.setContent(NSAttributedString(attributedString: content))
            XCTAssertEqual(view.measuredSize(for: 640), wide)
            XCTAssertEqual(view.measuredSize(for: 200), narrow)
            XCTAssertEqual(view.selectedRange(), range)
        }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(view.writeSelection(to: pasteboard, types: view.writablePasteboardTypes))
        XCTAssertEqual(pasteboard.string(forType: .string), expectedSelection)
        XCTAssertTrue(view.isSelectable)
        XCTAssertFalse(view.isEditable)

        view.setContent(NSAttributedString(string: "Hi", attributes: [.font: NSFont.systemFont(ofSize: 14)]))
        XCTAssertLessThanOrEqual(NSMaxRange(view.selectedRange()), 2)
        XCTAssertLessThan(view.measuredSize(for: 200).height, narrow.height)
        view.setContent(NSAttributedString(string: ""))
        XCTAssertEqual(view.measuredSize(for: 200).height, 0)
    }

    @MainActor
    func testRichTextAttachmentsAndLinksSurviveMeasurement() throws {
        let attachment = NSTextAttachment()
        attachment.image = NSImage(size: NSSize(width: 60, height: 30))
        attachment.bounds = NSRect(x: 0, y: 0, width: 60, height: 30)
        let content = NSMutableAttributedString(attachment: attachment)
        let url = try XCTUnwrap(URL(string: "https://example.com/document"))
        content.append(NSAttributedString(string: " link", attributes: [.link: url]))
        let view = SelectableRichTextView()
        view.setContent(content)
        let size = view.measuredSize(for: 240)
        XCTAssertGreaterThanOrEqual(size.height, 30)
        _ = view.measuredSize(for: 80)
        XCTAssertEqual(view.measuredSize(for: 240), size)
        XCTAssertEqual(view.textStorage?.attribute(.link, at: 2, effectiveRange: nil) as? URL, url)
        XCTAssertNotNil(view.textStorage?.attribute(.attachment, at: 0, effectiveRange: nil))
    }

    @MainActor
    func testDisplayMathSizeDoesNotDependOnItsPreviousFrame() {
        let host = NSHostingView(rootView: AdaptiveMathView(equation: #"\frac{x^2 + 1}{\sqrt{y}}"#, fontSize: 20))
        let natural = host.fittingSize
        XCTAssertGreaterThan(natural.width, 20)
        XCTAssertGreaterThan(natural.height, 20)
        for width in [100.0, 600.0, 180.0, 600.0] {
            host.setFrameSize(NSSize(width: width, height: 200))
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.fittingSize.width, natural.width, accuracy: 1)
            XCTAssertEqual(host.fittingSize.height, natural.height, accuracy: 1)
        }
    }
}

extension ChatLayoutTests {
    @MainActor
    func testRetryKeepsLastTurnVisibleInLongConversation() async throws {
        let coordinator = NSPersistentStoreCoordinator(
            managedObjectModel: PersistenceController.shared.container.managedObjectModel
        )
        try coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        let chat = ChatEntity(context: context)
        chat.id = UUID()
        chat.name = "Retry viewport regression"
        chat.systemMessage = ""
        chat.gptModel = "test"
        chat.requestMessages = []
        var sequence: Int64 = 0
        func append(_ text: String, own: Bool) -> MessageEntity {
            sequence += 1
            let message = MessageEntity(context: context)
            message.id = sequence
            message.sequence = sequence
            message.timestamp = Date()
            message.body = text
            message.own = own
            message.chat = chat
            return message
        }
        for count in [3, 40, 5, 100] {
            _ = append("Explain the next section \(count)", own: true)
            _ = append(String(repeating: "## History\n\nA long paragraph before the final turn. "
                + "The earlier messages must remain above the viewport during retry.\n\n", count: count), own: false)
        }
        let prompt = "Give me the complete workspace path"
        _ = append(prompt, own: true)
        let previous = append("`/tmp/project/markdown-syntax-sample.md`", own: false)
        try context.save()
        let viewModel = ChatViewModel(chat: chat, viewContext: context)
        let root = ChatMessagesView(
            chat: chat, chatViewModel: viewModel, inputBuffer: ChatInputBuffer(),
            editSystemMessage: .constant(false),
            isStreaming: Binding(get: { chat.waitingForResponse }, set: { chat.waitingForResponse = $0 }),
            currentError: .constant(nil), searchText: .constant(""),
            reasoningDurations: [:], activeReasoningMessageID: nil
        )
        .environment(\.managedObjectContext, context)
        .environmentObject(PreviewStateManager())
        let host = NSHostingView(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 940, height: 720),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "Chatmice Retry viewport regression"
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        func visibleText(_ text: String) -> Bool {
            let viewport = window.convertToScreen(host.convert(host.bounds, to: nil))
            var visited = Set<ObjectIdentifier>()
            func find(_ object: AnyObject) -> Bool {
                guard visited.insert(ObjectIdentifier(object)).inserted else { return false }
                if let element = object as? any NSAccessibilityProtocol {
                    let value = element.accessibilityValue() as? String ?? element.accessibilityLabel() ?? ""
                    if value.contains(text), element.accessibilityFrame().intersects(viewport) { return true }
                    if (element.accessibilityChildren() ?? []).contains(where: { find($0 as AnyObject) }) { return true }
                }
                return (object as? NSView)?.subviews.contains(where: { find($0) }) ?? false
            }
            return find(host)
        }
        func requireVisible(_ text: String, stage: String) async throws {
            try await Task.sleep(for: .milliseconds(100))
            for _ in 0..<60 {
                host.layoutSubtreeIfNeeded()
                if visibleText(text) {
                    return
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTFail("\(stage): the latest turn must be visible without a wheel event")
        }

        try await requireVisible("/tmp/project/markdown-syntax-sample.md", stage: "before retry")
        let service = RetryViewportStream()
        let manager = MessageManager(apiService: service, viewContext: context)
        defer { manager.cancelCurrentRequest() }
        let completed = expectation(description: "replacement completed")
        chat.waitingForResponse = true
        manager.sendMessageStream(prompt, in: chat, contextSize: 10, replacing: previous) { result in
            if case .failure(let error) = result { XCTFail("Retry failed: \(error)") }
            completed.fulfill()
        }
        try await requireVisible(prompt, stage: "old response removed, awaiting first token")
        let replacement = "The workspace path is /tmp/project/retried.md"
        service.continuation.yield(replacement)
        try await requireVisible(replacement, stage: "first replacement token")
        service.continuation.finish()
        await fulfillment(of: [completed], timeout: 3)
        try await requireVisible(replacement, stage: "retry completed")
    }
}

private final class RetryViewportStream: APIService {
    let name = "Controlled retry stream"
    let baseURL = URL(string: "https://example.invalid")!
    private let stream: AsyncThrowingStream<String, Error>
    let continuation: AsyncThrowingStream<String, Error>.Continuation
    private var isActive = false

    init() {
        (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
    }

    func sendMessage(_ messages: [[String: String]], temperature: Float,
                     completion: @escaping (Result<String, APIError>) -> Void) {
        completion(.failure(.invalidResponse))
    }

    func sendMessageStream(_ messages: [[String: String]], temperature: Float) async throws
        -> AsyncThrowingStream<String, Error> {
        isActive = true
        return stream
    }

    func fetchModels() async throws -> [AIModel] { [] }
    func cancelCurrentRequest() {
        if isActive { continuation.finish() }
    }
}

extension ChatLayoutTests {
    @MainActor
    func testSendingBelowLongContentKeepsStreamingTurnVisible() async throws {
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: PersistenceController.shared.container.managedObjectModel)
        try coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        let chat = ChatEntity(context: context)
        chat.id = UUID()
        chat.systemMessage = ""
        chat.gptModel = "test"
        chat.requestMessages = []
        func append(_ text: String, own: Bool) -> MessageEntity {
            let message = MessageEntity(context: context)
            message.id = chat.nextSequence()
            message.sequence = message.id
            message.timestamp = Date()
            message.body = text
            message.own = own
            message.chat = chat
            return message
        }
        for index in 0..<30 {
            _ = append("Explain section \(index)", own: true)
            _ = append(String(repeating: "## History \(index)\n\nVariable-height history paragraphs.\n\n", count: index % 7 + 1), own: false)
        }
        _ = append("Give me a long document", own: true)
        _ = append(String(repeating: "Long document line with enough content to wrap across the viewport.\n", count: 240), own: false)
        try context.save()
        let viewModel = ChatViewModel(chat: chat, viewContext: context)
        var latestGeometry: ScrollGeometry?
        let root = ChatMessagesView(chat: chat, chatViewModel: viewModel, inputBuffer: ChatInputBuffer(),
                                    editSystemMessage: .constant(false),
                                    isStreaming: Binding(get: { chat.waitingForResponse }, set: { chat.waitingForResponse = $0 }),
                                    currentError: .constant(nil), searchText: .constant(""),
                                    reasoningDurations: [:], activeReasoningMessageID: nil)
            .environment(\.managedObjectContext, context)
            .environmentObject(PreviewStateManager())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { _, geometry in
                latestGeometry = geometry
            }
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 940, height: 720),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.title = "Long streaming viewport regression"
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func hasVisibleText(_ text: String) -> Bool {
            let viewport = window.convertToScreen(host.convert(host.bounds, to: nil))
            var visited = Set<ObjectIdentifier>()
            func find(_ object: AnyObject) -> Bool {
                guard visited.insert(ObjectIdentifier(object)).inserted else { return false }
                if let node = object as? any NSAccessibilityProtocol {
                    let value = node.accessibilityValue() as? String ?? node.accessibilityLabel() ?? ""
                    if value.contains(text), node.accessibilityFrame().intersects(viewport) { return true }
                    if (node.accessibilityChildren() ?? []).contains(where: { find($0 as AnyObject) }) { return true }
                }
                return (object as? NSView)?.subviews.contains(where: { find($0) }) ?? false
            }
            return find(host)
        }
        func checkpoint(_ stage: String, visible text: String) async throws {
            try await Task.sleep(for: .milliseconds(500))
            let geometry = try XCTUnwrap(latestGeometry)
            XCTAssertLessThanOrEqual(geometry.visibleRect.minY, geometry.contentSize.height, "\(stage): viewport cannot be below all content")
            XCTAssertEqual(geometry.visibleRect.maxY, geometry.contentSize.height, accuracy: 30, "\(stage): following must stay at the actual bottom")
            XCTAssertTrue(hasVisibleText(text), "\(stage): actual latest message must be in the viewport")
        }
        try await checkpoint("initial", visible: "Long document line")
        let prompt = "New prompt below the long document"
        _ = append(prompt, own: true)
        try context.save()
        let service = RetryViewportStream()
        let manager = MessageManager(apiService: service, viewContext: context)
        defer { manager.cancelCurrentRequest() }
        let completed = expectation(description: "stream completed")
        manager.sendMessageStream(prompt, in: chat, contextSize: 10) { result in
            if case .failure(let error) = result { XCTFail(error.localizedDescription) }
            completed.fulfill()
        }
        try await checkpoint("waiting", visible: prompt)
        service.continuation.yield("First replacement token.\n\n")
        try await checkpoint("first-token", visible: "First replacement token")
        window.setContentSize(NSSize(width: 640, height: 720))
        try await checkpoint("resized", visible: "First replacement token")
        window.setContentSize(NSSize(width: 940, height: 720))
        for index in 0..<12 {
            service.continuation.yield("## Section \(index)\n\n" + String(repeating: "Growing response paragraph. ", count: 20) + "\n\nLatest section marker \(index).\n\n")
            try await checkpoint("growing-\(index)", visible: "Latest section marker \(index)")
        }
        func wheel(_ delta: Int32, phase: NSEvent.Phase) throws {
            let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                             wheel1: delta, wheel2: 0, wheel3: 0))
            let point = window.convertPoint(toScreen: NSPoint(x: 450, y: 360))
            event.location = CGPoint(x: point.x, y: CGDisplayBounds(CGMainDisplayID()).height - point.y)
            let cgPhase: CGScrollPhase = switch phase {
            case .began: .began
            case .changed: .changed
            default: .ended
            }
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(cgPhase.rawValue))
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            let scrollEvent = try XCTUnwrap(NSEvent(cgEvent: event))
            let localPoint = host.convert(NSPoint(x: 450, y: 360), from: nil)
            var ancestor = host.hitTest(localPoint)
            while let view = ancestor, !(view is NSScrollView) { ancestor = view.superview }
            let target = try XCTUnwrap(ancestor as? NSScrollView)
            target.scrollWheel(with: scrollEvent)
        }
        let bottomOffset = try XCTUnwrap(latestGeometry).visibleRect.minY
        try wheel(700, phase: .began)
        try await Task.sleep(for: .milliseconds(100))
        try wheel(700, phase: .changed)
        try await Task.sleep(for: .milliseconds(100))
        try wheel(0, phase: .ended)
        try await Task.sleep(for: .milliseconds(200))
        let readingOffset = try XCTUnwrap(latestGeometry).visibleRect.minY
        XCTAssertLessThan(readingOffset, bottomOffset - 200, "A user scroll must move away from the latest response")
        service.continuation.yield("\n\nMore response while reading history.\n\n")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(try XCTUnwrap(latestGeometry).visibleRect.minY, readingOffset, accuracy: 2,
                       "Streaming must not pull a reader back to the bottom")
        service.continuation.finish()
        await fulfillment(of: [completed], timeout: 3)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(try XCTUnwrap(latestGeometry).visibleRect.minY, readingOffset, accuracy: 2,
                       "Completion must not pull a reader back to the bottom")
        try wheel(-700, phase: .began)
        try await Task.sleep(for: .milliseconds(100))
        for _ in 0..<8 {
            try wheel(-700, phase: .changed)
            try await Task.sleep(for: .milliseconds(100))
        }
        try wheel(0, phase: .ended)
        try await checkpoint("completed", visible: "More response while reading history")
    }
}
