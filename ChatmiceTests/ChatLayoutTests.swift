import AppKit
import CoreData
import SwiftUI
import XCTest
@testable import Chatmice
@MainActor
private final class StreamingMarkdownTestState: ObservableObject {
    @Published var content: String
    @Published var isStreaming: Bool

    init(content: String, isStreaming: Bool) {
        self.content = content
        self.isStreaming = isStreaming
    }
}

private struct StreamingMarkdownTestHarness: View {
    @ObservedObject var state: StreamingMarkdownTestState

    var body: some View {
        MessageContentView(
            message: nil,
            content: state.content,
            isStreaming: state.isStreaming,
            own: false,
            effectiveFontSize: 15,
            colorScheme: .dark,
            inlineAttachments: true,
            reasoningDuration: nil,
            isActiveReasoning: false,
            prefetchedElements: nil,
            searchText: .constant(""),
            currentSearchOccurrence: nil
        )
        .frame(width: 720, alignment: .leading)
    }
}

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
    @MainActor
    func testEnhancedMarkdownRendersInNativeMessageView() async throws {
        let filler = String(repeating: "A paragraph keeps this text on the TextKit rendering path.\n", count: 24)
        let markdown = """
            \(filler)
            Alternative Heading
            ===================
            ~~removed~~<br>next line
            H~2~O and X^2^
            [Reference Link][reference]
            A footnote appears here[^note].
            > [!NOTE]
            > Callout body
            > > Nested quote
            - Top item
              - Nested item
            - [x] Completed task
            - [ ] Pending task

            ---

            $$x^2 + y^2$$

            Name | Role | Notes
            :--- | :---: | ---:
            **Alice** | `Developer` | A \\| B

            [reference]: https://example.com "Reference title"
            [^note]: Footnote **details**.
            """
        let root = MessageContentView(
            message: nil,
            content: markdown,
            isStreaming: false,
            own: false,
            effectiveFontSize: 15,
            colorScheme: .light,
            inlineAttachments: true,
            reasoningDuration: nil,
            isActiveReasoning: false,
            prefetchedElements: nil,
            searchText: .constant(""),
            currentSearchOccurrence: nil,
            allowsStreamingLayout: false
        )
        let host = NSHostingView(rootView: root.frame(width: 760, alignment: .leading))
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 900),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()

        func richTextViews(in view: NSView) -> [SelectableRichTextView] {
            let current = (view as? SelectableRichTextView).map { [$0] } ?? []
            return current + view.subviews.flatMap(richTextViews(in:))
        }
        let richText = try XCTUnwrap(richTextViews(in: host).first)
        let rendered = try XCTUnwrap(richText.textStorage)
        XCTAssertFalse(rendered.string.contains("<br>"))
        XCTAssertTrue(rendered.string.contains("removed  \nnext line"))
        XCTAssertTrue(rendered.string.contains("│ NOTE"))
        XCTAssertTrue(rendered.string.contains("│ │ Nested quote"))
        XCTAssertFalse(rendered.string.contains("[!NOTE]"))
        XCTAssertTrue(rendered.string.contains("Alternative Heading"))
        XCTAssertFalse(rendered.string.contains("==================="))
        XCTAssertTrue(rendered.string.contains("☑︎ Completed task"))
        XCTAssertTrue(rendered.string.contains("☐ Pending task"))
        XCTAssertTrue(rendered.string.contains("H2O and X2"))
        XCTAssertFalse(rendered.string.contains("H~2~O"))
        XCTAssertFalse(rendered.string.contains("X^2^"))

        let headingRange = (rendered.string as NSString).range(of: "Alternative Heading")
        let headingFont = rendered.attribute(.font, at: headingRange.location, effectiveRange: nil) as? NSFont
        XCTAssertGreaterThan(try XCTUnwrap(headingFont).pointSize, 15)
        let chemicalRange = (rendered.string as NSString).range(of: "H2O")
        let exponentRange = (rendered.string as NSString).range(of: "X2")
        let subscriptOffset = rendered.attribute(
            .baselineOffset,
            at: chemicalRange.location + 1,
            effectiveRange: nil
        ) as? CGFloat
        let superscriptOffset = rendered.attribute(
            .baselineOffset,
            at: exponentRange.location + 1,
            effectiveRange: nil
        ) as? CGFloat
        XCTAssertLessThan(try XCTUnwrap(subscriptOffset), 0)
        XCTAssertGreaterThan(try XCTUnwrap(superscriptOffset), 0)

        let linkRange = (rendered.string as NSString).range(of: "Reference Link")
        XCTAssertEqual(
            rendered.attribute(
                MarkdownLinkTitleSupport.toolTipKey,
                at: linkRange.location,
                effectiveRange: nil
            ) as? String,
            "Reference title"
        )

        let removedRange = (rendered.string as NSString).range(of: "removed")
        XCTAssertNotEqual(removedRange.location, NSNotFound)
        XCTAssertEqual(
            rendered.attribute(.strikethroughStyle, at: removedRange.location, effectiveRange: nil) as? Int,
            NSUnderlineStyle.single.rawValue
        )
        let topRange = (rendered.string as NSString).range(of: "- Top item")
        let nestedRange = (rendered.string as NSString).range(of: "- Nested item")
        let topStyle = rendered.attribute(.paragraphStyle, at: topRange.location, effectiveRange: nil)
            as? NSParagraphStyle
        let nestedStyle = rendered.attribute(.paragraphStyle, at: nestedRange.location, effectiveRange: nil)
            as? NSParagraphStyle
        XCTAssertGreaterThan(try XCTUnwrap(nestedStyle).firstLineHeadIndent, try XCTUnwrap(topStyle).firstLineHeadIndent)

        var visited = Set<ObjectIdentifier>()
        func accessibilityText(from object: AnyObject) -> [String] {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return [] }
            var values: [String] = []
            if let element = object as? any NSAccessibilityProtocol {
                if let value = element.accessibilityValue() as? String { values.append(value) }
                if let label = element.accessibilityLabel() { values.append(label) }
                values += (element.accessibilityChildren() ?? []).flatMap {
                    accessibilityText(from: $0 as AnyObject)
                }
            }
            if let view = object as? NSView {
                values += view.subviews.flatMap { accessibilityText(from: $0) }
            }
            return values
        }
        let visibleText = accessibilityText(from: host).joined(separator: "\n")
        XCTAssertTrue(visibleText.contains("Alice"))
        XCTAssertTrue(visibleText.contains("Developer"))
        XCTAssertTrue(visibleText.contains("A | B"))
        XCTAssertFalse(visibleText.contains("**Alice**"))
        XCTAssertTrue(visibleText.contains("Footnote details."))
    }
    @MainActor
    func testWidthProbesDoNotRewrapTheDisplayedText() throws {
        let view = SelectableRichTextView()
        view.setContent(NSAttributedString(
            string: String(repeating: "A long displayed paragraph must retain its final wrapping width.\n", count: 30),
            attributes: [.font: NSFont.systemFont(ofSize: 15)]
        ))
        for drawingWidth in [640.0, 280.0, 640.0] {
            view.setFrameSize(NSSize(width: drawingWidth, height: 3000))
            let expected = view.measuredSize(for: drawingWidth)
            for probe in [120.0, 720.0, 200.0, 720.0] { _ = view.measuredSize(for: probe) }
            let container = try XCTUnwrap(view.textContainer)
            let manager = try XCTUnwrap(view.layoutManager)
            manager.ensureLayout(for: container)
            let drawnHeight = ceil(max(manager.usedRect(for: container).maxY, manager.extraLineFragmentRect.maxY))
            XCTAssertEqual(drawnHeight, expected.height, accuracy: 1,
                           "Measurement at other widths must not leave the displayed paragraph rewrapped or clipped")
        }
    }

    @MainActor
    func testRichTextSizeTracksMutableContentAndLineLimitChanges() {
        let content = NSMutableAttributedString(string: "Short", attributes: [.font: NSFont.systemFont(ofSize: 14)])
        let view = SelectableRichTextView()
        view.setContent(content)
        let initial = view.measuredSize(for: 180)
        content.append(NSAttributedString(string: String(repeating: "\nLonger text that wraps across multiple lines.", count: 12),
                                         attributes: [.font: NSFont.systemFont(ofSize: 14)]))
        view.setContent(content)
        let expanded = view.measuredSize(for: 180)
        XCTAssertGreaterThan(expanded.height, initial.height)
        view.setContent(content, lineLimit: 1, lineBreakMode: .byTruncatingTail)
        let truncated = view.measuredSize(for: 180)
        XCTAssertLessThan(truncated.height, expanded.height)
        view.setContent(content)
        XCTAssertEqual(view.measuredSize(for: 180), expanded)
        content.addAttribute(.font, value: NSFont.systemFont(ofSize: 22), range: NSRange(location: 0, length: content.length))
        view.setContent(content)
        XCTAssertGreaterThan(view.measuredSize(for: 180).height, expanded.height)
    }

    @MainActor
    func testShortHighlightedCodeBlocksRemainVisible() async throws {
        let firstCode = "const db = env.DB;"
        let secondCode = "const row = await env.DB.prepare(\"SELECT 1\").first();"
        let markdown = """
            Worker can access the binding:

            ```js
            \(firstCode)
            ```

            A second short block must remain visible too:

            ```js
            \(secondCode)
            ```
            """
        let root = MessageContentView(
            message: nil,
            content: markdown,
            isStreaming: false,
            own: false,
            effectiveFontSize: 15,
            colorScheme: .dark,
            inlineAttachments: true,
            reasoningDuration: nil,
            isActiveReasoning: false,
            prefetchedElements: nil,
            searchText: .constant(""),
            currentSearchOccurrence: nil,
            allowsStreamingLayout: false
        )
        .environmentObject(PreviewStateManager())
        let host = NSHostingView(rootView: root.frame(width: 720, alignment: .leading))
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 760, height: 500),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()

        func richTextViews(in view: NSView) -> [SelectableRichTextView] {
            let current = (view as? SelectableRichTextView).map { [$0] } ?? []
            return current + view.subviews.flatMap(richTextViews(in:))
        }
        let expectedCode = Set([firstCode, secondCode])
        let codeViews = richTextViews(in: host).filter { expectedCode.contains($0.string) }
        XCTAssertEqual(Set(codeViews.map(\.string)), expectedCode)
        for codeView in codeViews {
            XCTAssertGreaterThan(codeView.frame.height, 0)
            let container = try XCTUnwrap(codeView.textContainer)
            let manager = try XCTUnwrap(codeView.layoutManager)
            manager.ensureLayout(for: container)
            XCTAssertGreaterThan(manager.usedRect(for: container).height, 0)
        }
    }

    @MainActor
    func testClosedCodeFenceStaysVisibleWhileFollowingTokensStream() async throws {
        let code = "llmMode: remote\nllmModel: gpt-4.1-mini"
        let state = StreamingMarkdownTestState(content: "Configuration:\n\n", isStreaming: true)
        let root = StreamingMarkdownTestHarness(state: state)
            .environmentObject(PreviewStateManager())
        let host = NSHostingView(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 760, height: 500),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        state.content += "```yaml\nllmMode: remote\n"
        try await Task.sleep(for: .milliseconds(30))
        state.content += "llmModel: gpt-4.1-mini\n```\n\n"
        try await Task.sleep(for: .milliseconds(100))
        state.content += "More response is still arriving."
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        func richTextViews(in view: NSView) -> [SelectableRichTextView] {
            let current = (view as? SelectableRichTextView).map { [$0] } ?? []
            return current + view.subviews.flatMap(richTextViews(in:))
        }
        let streamingCodeView = try XCTUnwrap(
            richTextViews(in: host).first(where: { $0.string == code }),
            "A completed code fence must create measurable text before streaming finishes"
        )
        XCTAssertGreaterThan(streamingCodeView.frame.height, 0)
        let streamingContainer = try XCTUnwrap(streamingCodeView.textContainer)
        let streamingLayoutManager = try XCTUnwrap(streamingCodeView.layoutManager)
        streamingLayoutManager.ensureLayout(for: streamingContainer)
        XCTAssertGreaterThan(
            streamingLayoutManager.usedRect(for: streamingContainer).height,
            0
        )
        func accessibilityText(from object: AnyObject, visited: inout Set<ObjectIdentifier>) -> [String] {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return [] }
            var values: [String] = []
            if let element = object as? any NSAccessibilityProtocol {
                if let value = element.accessibilityValue() as? String { values.append(value) }
                if let label = element.accessibilityLabel() { values.append(label) }
                values += (element.accessibilityChildren() ?? []).flatMap {
                    accessibilityText(from: $0 as AnyObject, visited: &visited)
                }
            }
            if let view = object as? NSView {
                values += view.subviews.flatMap {
                    accessibilityText(from: $0, visited: &visited)
                }
            }
            return values
        }

        var visited = Set<ObjectIdentifier>()
        let visibleText = accessibilityText(from: host, visited: &visited).joined(separator: "\n")
        XCTAssertTrue(visibleText.contains(code), "A completed code fence must stay visible before streaming finishes")
        XCTAssertTrue(visibleText.contains("More response is still arriving."))

        state.isStreaming = false
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let completedCodeView = try XCTUnwrap(richTextViews(in: host).first(where: { $0.string == code }))
        XCTAssertGreaterThan(completedCodeView.frame.height, 0)
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
            chat: chat,
            chatViewModel: viewModel,
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
        let root = ChatMessagesView(
            chat: chat,
            chatViewModel: viewModel,
            isStreaming: Binding(get: { chat.waitingForResponse }, set: { chat.waitingForResponse = $0 }),
            currentError: .constant(nil), searchText: .constant(""),
            reasoningDurations: [:], activeReasoningMessageID: nil
        )
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

extension ChatLayoutTests {
    @MainActor
    func testConversationLoadingKeepsLatestSelectionWhenEarlierFetchFinishes() async throws {
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: PersistenceController.shared.container.managedObjectModel)
        try coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        func makeChat(_ name: String) -> ChatEntity {
            let chat = ChatEntity(context: context)
            chat.id = UUID()
            chat.name = name
            chat.systemMessage = ""
            chat.gptModel = "test"
            chat.requestMessages = []
            let message = MessageEntity(context: context)
            message.id = 1
            message.sequence = 1
            message.timestamp = Date()
            message.own = false
            message.body = "Content belonging to \(name)"
            message.chat = chat
            return chat
        }
        let first = makeChat("Alpha")
        let superseded = makeChat("Beta")
        let latest = makeChat("Gamma")
        try context.save()
        let presentation = ConversationPresentationController()
        func waitForChat(_ chat: ChatEntity) async throws {
            for _ in 0..<100 {
                if !presentation.isLoading, presentation.displayedChat?.objectID == chat.objectID { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTFail("The requested conversation must replace loading after its data is prepared")
        }
        presentation.select(first, in: context)
        XCTAssertTrue(presentation.isLoading)
        try await waitForChat(first)

        // Block the real store queue while the destination's background fetch is pending.
        let storeHeld = expectation(description: "store coordinator held")
        let releaseStore = DispatchSemaphore(value: 0)
        let heldStoreTask = Task {
            await coordinator.perform {
                storeHeld.fulfill()
                _ = releaseStore.wait(timeout: .now() + 3)
            }
        }
        defer { releaseStore.signal() }
        await fulfillment(of: [storeHeld], timeout: 1)
        presentation.select(superseded, in: context)
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertTrue(presentation.isLoading, "Loading must remain active while the store fetch is blocked")
        XCTAssertEqual(presentation.displayedChat?.objectID, first.objectID)
        presentation.select(latest, in: context)
        XCTAssertTrue(presentation.isLoading, "A newer selection must not clear pending loading feedback")
        releaseStore.signal()
        await heldStoreTask.value
        try await waitForChat(latest)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(presentation.displayedChat?.objectID, latest.objectID, "A superseded fetch must never overwrite the latest selection")
        XCTAssertFalse(presentation.isLoading)

        presentation.select(superseded, in: context)
        presentation.select(nil, in: context)
        XCTAssertNil(presentation.displayedChat)
        XCTAssertFalse(presentation.isLoading)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(presentation.displayedChat, "Clearing selection must prevent an already scheduled load from repopulating it")
        XCTAssertFalse(presentation.isLoading)
    }
}

extension ChatLayoutTests {
    @MainActor
    func testSystemPromptIsNotRenderedInConversation() throws {
        let coordinator = NSPersistentStoreCoordinator(
            managedObjectModel: PersistenceController.shared.container.managedObjectModel
        )
        try coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator

        let chat = ChatEntity(context: context)
        chat.id = UUID()
        chat.name = "Hidden prompt regression"
        chat.systemMessage = "PRIVATE PERSONA PROMPT MUST NOT BE VISIBLE"
        chat.gptModel = "test"
        chat.requestMessages = []

        let message = MessageEntity(context: context)
        message.id = 1
        message.sequence = 1
        message.timestamp = Date()
        message.body = "Visible conversation message"
        message.own = true
        message.chat = chat
        try context.save()

        let viewModel = ChatViewModel(chat: chat, viewContext: context)
        let root = ChatMessagesView(
            chat: chat,
            chatViewModel: viewModel,
            isStreaming: .constant(false),
            currentError: .constant(nil),
            searchText: .constant(""),
            reasoningDurations: [:],
            activeReasoningMessageID: nil
        )
        .environment(\.managedObjectContext, context)
        .environmentObject(PreviewStateManager())
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        host.layoutSubtreeIfNeeded()

        func accessibilityText(from object: AnyObject) -> [String] {
            var values: [String] = []
            if let element = object as? any NSAccessibilityProtocol {
                if let value = element.accessibilityValue() as? String { values.append(value) }
                if let label = element.accessibilityLabel() { values.append(label) }
                values += (element.accessibilityChildren() ?? []).flatMap {
                    accessibilityText(from: $0 as AnyObject)
                }
            }
            if let view = object as? NSView {
                values += view.subviews.flatMap { accessibilityText(from: $0) }
            }
            return values
        }

        let visibleText = accessibilityText(from: host).joined(separator: "\n")
        XCTAssertTrue(visibleText.contains("Visible conversation message"))
        XCTAssertFalse(visibleText.contains(chat.systemMessage))
    }
}

extension ChatLayoutTests {
    func testGlassBackgroundStyleExpandsFormerHighStrengthRangeAcrossTenSteps() {
        let levels = (1...10).map {
            GlassBackgroundStyle(backgroundOpacity: 75, blurLevel: Double($0))
        }

        XCTAssertEqual(levels[0].effectiveBlurLevel, 8, accuracy: 0.0001)
        XCTAssertEqual(levels[9].effectiveBlurLevel, 10, accuracy: 0.0001)
        XCTAssertEqual(levels[0].maximumMaterialOpacity, 0, accuracy: 0.0001)
        XCTAssertEqual(levels[9].maximumMaterialOpacity, 1, accuracy: 0.0001)

        for (lower, upper) in zip(levels, levels.dropFirst()) {
            XCTAssertEqual(upper.effectiveBlurLevel - lower.effectiveBlurLevel, 2 / 9, accuracy: 0.0001)
            XCTAssertGreaterThan(upper.maximumMaterialOpacity, lower.maximumMaterialOpacity)
        }
        XCTAssertLessThan(levels[4].tintOpacity, 0.25)
    }
}

extension ChatLayoutTests {
    @MainActor
    func testToolCardsRemainClickableAfterRepeatedExpansionAndStreamingCompletion() async throws {
        let first = ToolActivityRecord(name: "write_file", input: "{\"path\":\"example.md\"}",
                                       output: "Wrote 15 bytes to example.md", isError: false)
        let second = ToolActivityRecord(name: "read_file", input: "{\"path\":\"example.md\"}",
                                        output: "FILE_TOOL_SMOKE", isError: false)
        let content = "Before the tools.\n\n\(first.marker)\n\nBetween the tools.\n\n\(second.marker)\n\nAfter the tools."
        let state = StreamingMarkdownTestState(content: content, isStreaming: false)
        let host = NSHostingView(rootView: StreamingMarkdownTestHarness(state: state)
            .environmentObject(PreviewStateManager()))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 760, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.title = "Tool disclosure regression"
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        func element(containing text: String) -> (any NSAccessibilityProtocol)? {
            var visited = Set<ObjectIdentifier>()
            func find(_ object: AnyObject) -> (any NSAccessibilityProtocol)? {
                guard visited.insert(ObjectIdentifier(object)).inserted else { return nil }
                if let node = object as? any NSAccessibilityProtocol {
                    let value = node.accessibilityValue() as? String ?? ""
                    let label = node.accessibilityLabel() ?? ""
                    if value.contains(text) || label.contains(text) { return node }
                    for child in node.accessibilityChildren() ?? [] {
                        if let found = find(child as AnyObject) { return found }
                    }
                }
                for child in (object as? NSView)?.subviews ?? [] {
                    if let found = find(child) { return found }
                }
                return nil
            }
            return find(host)
        }

        func clickHeader(after precedingText: String) async throws {
            host.layoutSubtreeIfNeeded()
            let frame = try XCTUnwrap(element(containing: precedingText)).accessibilityFrame()
            let location = window.convertPoint(fromScreen: NSPoint(x: frame.minX + 80, y: frame.minY - 40))
            let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: location,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: location,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
            NSApp.postEvent(up, atStart: true)
            window.sendEvent(down)
            try await Task.sleep(for: .milliseconds(250))
        }

        try await Task.sleep(for: .milliseconds(200))
        for streamed in [false, true] {
            if streamed {
                state.isStreaming = true
                try await Task.sleep(for: .milliseconds(100))
                state.content += " More streamed text."
                state.isStreaming = false
                try await Task.sleep(for: .milliseconds(200))
            }
            for cycle in 0..<10 {
                let collapsedHeight = host.fittingSize.height
                try await clickHeader(after: "Before the tools.")
                let firstExpandedHeight = host.fittingSize.height
                XCTAssertGreaterThan(firstExpandedHeight, collapsedHeight + 20, "Expand cycle \(cycle), streamed=\(streamed)")
                try await clickHeader(after: "Before the tools.")
                XCTAssertEqual(host.fittingSize.height, collapsedHeight, accuracy: 1, "Collapse cycle \(cycle), streamed=\(streamed)")
                try await clickHeader(after: "Between the tools.")
                XCTAssertGreaterThan(host.fittingSize.height, collapsedHeight + 20, "Second card expand cycle \(cycle), streamed=\(streamed)")
                try await clickHeader(after: "Between the tools.")
                XCTAssertEqual(host.fittingSize.height, collapsedHeight, accuracy: 1, "Second card collapse cycle \(cycle), streamed=\(streamed)")
            }
        }
    }
}


extension ChatLayoutTests {
    @MainActor
    func testCheckpointCardUsesFullRowDisclosureTarget() async throws {
        let coordinator = NSPersistentStoreCoordinator(
            managedObjectModel: PersistenceController.shared.container.managedObjectModel
        )
        try coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        let checkpoint = MessageEntity(context: context)
        checkpoint.id = 1
        checkpoint.sequence = 1
        checkpoint.kind = MessageKind.contextCheckpoint.rawValue
        checkpoint.name = "Context checkpoint"
        checkpoint.body = String(repeating: "Durable checkpoint details. ", count: 12)
        checkpoint.checkpointOriginalTokens = 7_000
        checkpoint.checkpointCompactedTokens = 1_000
        checkpoint.checkpointCoversThroughSequence = 4
        checkpoint.checkpointValid = true
        let content = ChatBubbleContent(
            message: checkpoint.body,
            own: false,
            waitingForResponse: false,
            errorMessage: nil,
            systemMessage: false,
            isStreaming: false,
            isLatestMessage: false,
            reasoningDuration: nil,
            isActiveReasoning: false
        )
        let host = NSHostingView(rootView: ChatBubbleView(
            content: content,
            message: checkpoint,
            searchText: .constant("")
        ).environment(\.managedObjectContext, context))
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 760, height: 240),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()

        let collapsedHeight = host.fittingSize.height
        let hostPoint = NSPoint(x: host.bounds.maxX - 40, y: host.bounds.midY)
        let windowPoint = host.convert(hostPoint, to: nil)
        let mouseDown = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
        let mouseUp = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: windowPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 0
        ))
        window.sendEvent(mouseDown)
        window.sendEvent(mouseUp)
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(
            host.fittingSize.height,
            collapsedHeight + 20,
            "Clicking the trailing side of the checkpoint header must expand the card"
        )
    }
}

extension ChatLayoutTests {
    func testUsageFallbackPrefersAPIAndMatchesPiCharacterCounting() {
        let request = [["role": "user", "content": "汉字🙂abc"]]
        let estimated = ContextManagement.resolvedUsage(reported: nil, requestMessages: request, response: "12345")
        XCTAssertEqual(estimated, ModelTokenUsage(inputTokens: 2, outputTokens: 2, isEstimated: true))
        XCTAssertEqual(ContextManagement.estimatedTokens(in: ""), 0)
        let reported = ModelTokenUsage(inputTokens: 17, outputTokens: 9)
        XCTAssertEqual(ContextManagement.resolvedUsage(reported: reported, requestMessages: request, response: "12345"), reported)
        XCTAssertEqual(ContextManagement.resolvedUsage(reported: ModelTokenUsage(inputTokens: 0, outputTokens: 0), requestMessages: request, response: "12345"), estimated)
    }

    @MainActor
    func testCompletedResponsesPersistFallbackThenReplaceItWithReportedUsage() async throws {
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: PersistenceController.shared.container.managedObjectModel)
        try coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        let chat = ChatEntity(context: context)
        chat.id = UUID()
        chat.name = "Usage regression"
        chat.systemMessage = "abcd"
        chat.gptModel = "private-test-model"
        chat.requestMessages = []
        let api = APIServiceEntity(context: context)
        api.contextWindowOverrideTokens = 100
        chat.apiService = api
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UsageRegressionURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            UsageRegressionURLProtocol.reported = false
            UsageRegressionURLProtocol.requestKinds = []
        }
        let config = APIServiceConfig(name: "Usage fixture", apiUrl: URL(string: "https://usage.invalid/v1")!, apiKey: "fixture", model: "private-test-model", type: "chatgpt")
        let manager = MessageManager(apiService: ChatGPTHandler(config: config, session: session), viewContext: context)
        defer { manager.cancelCurrentRequest() }
        let fallback = expectation(description: "fallback stream completes")
        manager.sendMessageStream("1234", in: chat, contextSize: 10) { result in
            if case .failure(let error) = result { XCTFail(error.localizedDescription) }
            XCTAssertFalse(
                chat.messagesArray.contains(where: \.isContextCheckpoint),
                "Completing a response records usage; compaction belongs before the next request"
            )
            fallback.fulfill()
        }
        await fulfillment(of: [fallback], timeout: 5)
        XCTAssertEqual(chat.contextInputTokens, 2)
        XCTAssertEqual(chat.contextOutputTokens, 100)
        XCTAssertNil(chat.contextUpdatedAt)
        UsageRegressionURLProtocol.reported = true
        let reported = expectation(description: "reported nonstream completes")
        manager.sendMessage("Next request", in: chat, contextSize: 10) { result in
            if case .failure(let error) = result { XCTFail(error.localizedDescription) }
            XCTAssertTrue(
                chat.messagesArray.contains(where: \.isContextCheckpoint),
                "An over-threshold conversation must compact before the user request is sent"
            )
            reported.fulfill()
        }
        await fulfillment(of: [reported], timeout: 5)
        let checkpoint = try XCTUnwrap(chat.messagesArray.first(where: \.isContextCheckpoint))
        XCTAssertEqual(checkpoint.body, "Checkpoint summary")
        XCTAssertEqual(checkpoint.checkpointOriginalTokens, 102)
        XCTAssertEqual(Array(UsageRegressionURLProtocol.requestKinds.prefix(3)), ["response", "compaction", "response"])
        XCTAssertEqual(chat.contextInputTokens, 7)
        XCTAssertEqual(chat.contextOutputTokens, 3)
        XCTAssertNotNil(chat.contextUpdatedAt, "Real usage must replace the preflight estimate")
        chat.contextInputTokens = 90
        chat.contextOutputTokens = 0
        chat.contextUpdatedAt = Date()
        let streamingRequestStart = UsageRegressionURLProtocol.requestKinds.count
        let streamed = expectation(description: "trailing usage stream completes")
        manager.sendMessageStream("Streamed reported usage", in: chat, contextSize: 10) { result in
            if case .failure(let error) = result { XCTFail(error.localizedDescription) }
            XCTAssertEqual(chat.messagesArray.filter(\.isContextCheckpoint).count, 2)
            streamed.fulfill()
        }
        await fulfillment(of: [streamed], timeout: 5)
        for _ in 0..<100 {
            if chat.contextInputTokens == 11 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(
            Array(UsageRegressionURLProtocol.requestKinds.dropFirst(streamingRequestStart).prefix(2)),
            ["compaction", "response"]
        )
        XCTAssertEqual(chat.contextInputTokens, 11)
        XCTAssertEqual(chat.contextOutputTokens, 5, "Usage-only chunks after finish_reason must reach persistence")
        XCTAssertNotNil(chat.contextUpdatedAt)
    }

    func testUpstreamTokenFailureIsPresentedAsAuthenticationError() {
        let message = #"{"error":{"message":"Authentication error: Token request failed: TLS handshake EOF","type":"authentication_error"}}"#
        let error = ErrorMessage(type: .serverError(message), timestamp: Date())
        XCTAssertEqual(error.displayTitle, "Authentication Error")
        XCTAssertTrue(error.displayMessage.contains("Token request failed"))
        XCTAssertTrue(error.canRetry, "Transient token-network failures remain retryable")
    }
}

extension ChatLayoutTests {
    func testImportedMCPSchemaKeepsArgumentConstraintsThroughRoundTrip() throws {
        let source: [String: Any] = [
            "type": "object",
            "properties": [
                "name": ["type": "string", "description": "Exact Custom Skill name.", "enum": ["help", "search"]],
                "task": ["type": "string", "minLength": 1],
                "options": ["$ref": "#/$defs/options"],
            ],
            "required": ["name", "task"],
            "additionalProperties": false,
            "$defs": ["options": ["anyOf": [["type": "null"], ["type": "object", "additionalProperties": true]]]],
        ]
        let data = try JSONSerialization.data(withJSONObject: source)
        let decoded = try JSONDecoder().decode(JSONSchema.self, from: data)
        let imported = try XCTUnwrap(JSONSchema(anyCodable: AnyCodable(source)))
        for schema in [decoded, imported] {
            XCTAssertEqual(schema.openAIWireDict as NSDictionary, source as NSDictionary)
            let restored = try JSONSerialization.jsonObject(with: JSONEncoder().encode(schema)) as? NSDictionary
            XCTAssertEqual(restored, source as NSDictionary)
        }
    }
}

extension ChatLayoutTests {
    @MainActor
    func testModelOverridesPreserveAutomaticFallbackAndProviderIsolation() throws {
        let first = UUID(), second = UUID()
        let key = "service_models_\(first.uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: PersistenceController.shared.container.managedObjectModel)
        try coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        let service = APIServiceEntity(context: context)
        service.id = first; service.type = "openai-responses"
        service.imageUploadsAllowed = false; service.pdfUploadsAllowed = true
        let override = ModelConfigurationOverrides(contextWindowTokens: 64_000, visionSupported: true, filesSupported: false, audioSupported: true, thinkingSupported: true)
        let rows = [ServiceModelRow(modelID: "private-model", overrides: override), ServiceModelRow(modelID: "gpt-5.6-sol", overrides: ModelConfigurationOverrides(thinkingSupported: false))]
        UserDefaults.standard.set(String(data: try JSONEncoder().encode(rows), encoding: .utf8), forKey: key)
        XCTAssertEqual(ModelConfigurationStore.overrides(serviceID: first, modelID: "private-model"), override)
        XCTAssertEqual(ModelConfigurationStore.overrides(serviceID: second, modelID: "private-model"), ModelConfigurationOverrides())
        XCTAssertEqual(ModelContextRegistry.resolve(service: service, modelID: "private-model")?.tokens, 64_000)
        XCTAssertTrue(ModelAttachmentCapabilities.vision(service: service, modelID: "private-model"))
        XCTAssertFalse(ModelAttachmentCapabilities.files(service: service, modelID: "private-model"))
        XCTAssertTrue(ModelAttachmentCapabilities.audio(service: service, modelID: "private-model"))
        XCTAssertFalse(ModelAttachmentCapabilities.vision(service: service, modelID: "other-model"))
        XCTAssertTrue(ModelAttachmentCapabilities.files(service: service, modelID: "other-model"))
        var body: [String: Any] = [:]
        ReasoningRequestEncoder.apply(selection: .high, profile: ModelReasoningRegistry.resolve(modelID: "private-model", serviceType: "openai-responses", serviceID: first), maxTokens: 1000, to: &body)
        XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], "high")
        body = [:]
        ReasoningRequestEncoder.apply(selection: .high, profile: ModelReasoningRegistry.resolve(modelID: "gpt-5.6-sol", serviceType: "openai-responses", serviceID: first), maxTokens: 1000, to: &body)
        XCTAssertNil(body["reasoning"])
        XCTAssertTrue(ModelReasoningRegistry.resolve(modelID: "gpt-5.6-sol", serviceType: "openai-responses", serviceID: second).supportsReasoning)
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(ModelContextRegistry.resolve(service: service, modelID: "gpt-5.6-sol")?.tokens, 400_000)
        XCTAssertFalse(ModelAttachmentCapabilities.vision(service: service, modelID: "private-model"))
        XCTAssertTrue(ModelAttachmentCapabilities.files(service: service, modelID: "private-model"))
        let legacy = Data("[{\"id\":\"legacy\",\"nickname\":\"\",\"modelID\":\"old\"}]".utf8)
        XCTAssertNil(try JSONDecoder().decode([ServiceModelRow].self, from: legacy).first?.overrides)
    }
}

extension ChatLayoutTests {
    @MainActor
    func testEmptySubmissionsDoNotCreateMessagesOrStartInference() throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let chat = ChatEntity(context: context)
        chat.id = UUID(); chat.gptModel = "test"; chat.requestMessages = []
        let viewModel = ChatViewModel(chat: chat, viewContext: context)
        let handler = ChatLogicHandler(viewContext: context, chat: chat, chatViewModel: viewModel)
        for text in ["", " \t\n"] {
            handler.sendMessage(messageText: text, attachedImages: [], attachedFiles: [])
            XCTAssertFalse(chat.waitingForResponse)
            XCTAssertFalse(handler.isStreaming)
            XCTAssertNil(handler.currentError)
            XCTAssertTrue(chat.messagesArray.isEmpty)
        }
    }
}

extension ChatLayoutTests {
    func testCustomHeaderValidationRejectsInjectionAndCaseDuplicates() throws {
        let headers = try ProviderHeaderStore.parse("Authorization: Bearer custom\nX-Tenant: a=b:c")
        XCTAssertEqual(headers["X-Tenant"], "a=b:c")
        XCTAssertThrowsError(try ProviderHeaderStore.parse("X-Tenant: a\nx-tenant: b"))
        XCTAssertThrowsError(try ProviderHeaderStore.validate(["Bad Name": "value"]))
        XCTAssertThrowsError(try ProviderHeaderStore.validate(["X-Tenant": "a\r\nAuthorization: injected"]))
        var request = URLRequest(url: URL(string: "https://example.com")!)
        request.setValue("Bearer default", forHTTPHeaderField: "Authorization")
        ProviderHeaderStore.apply(headers, to: &request)
        XCTAssertEqual(request.value(forHTTPHeaderField: "authorization"), "Bearer custom")
    }

    func testOAuthCallbackRejectsWrongStateOriginAndDuplicateCode() throws {
        let redirect = "chatmice://oauth/callback"
        XCTAssertEqual(try MCPOAuthManager.authorizationCode(
            callback: URL(string: redirect + "?state=expected&code=valid")!,
            redirectURI: redirect, state: "expected"), "valid")
        for callback in [redirect + "?state=wrong&code=valid", "chatmice://other/callback?state=expected&code=valid",
                         redirect + "?state=expected&code=a&code=b"] {
            XCTAssertThrowsError(try MCPOAuthManager.authorizationCode(
                callback: URL(string: callback)!, redirectURI: redirect, state: "expected"))
        }
        XCTAssertFalse(AuthOriginRedirectDelegate.sameOrigin(
            URL(string: "https://example.com/sse")!, URL(string: "http://example.com/messages")!))
        XCTAssertFalse(AuthOriginRedirectDelegate.sameOrigin(
            URL(string: "https://example.com/sse")!, URL(string: "https://example.com:444/messages")!))
        XCTAssertEqual(MCPOAuthManager.formEncode(["scope": "a b+c&d"]), "scope=a%20b%2Bc%26d")
    }

    func testLegacyMCPAndMinimalOAuthJSONDecode() throws {
        let legacy = Data("{\"name\":\"local\",\"kind\":\"http\",\"args\":[],\"env\":{},\"url\":\"http://localhost/mcp\",\"enabled\":true}".utf8)
        XCTAssertNil(try JSONDecoder().decode(MCPServerConfig.self, from: legacy).oauth)
        let oauth = try JSONDecoder().decode(MCPOAuthConfiguration.self, from: Data(
            "{\"grant\":\"clientCredentials\",\"tokenURL\":\"https://example.com/token\",\"clientID\":\"client\"}".utf8))
        try oauth.validate()
        XCTAssertEqual(oauth.grant, .clientCredentials)
        var insecure = oauth
        insecure.tokenURL = "http://remote.example.com/token"
        XCTAssertThrowsError(try insecure.validate())
    }

    func testLoopbackOAuthRedirectPreservesPortAndPathAndRejectsRemoteHosts() throws {
        let redirect = "http://localhost:18767/mcp-callback"
        let callback = try MCPOAuthConfiguration.callbackURL(redirect)
        XCTAssertEqual(callback.port, 18767)
        XCTAssertEqual(callback.path, "/mcp-callback")
        XCTAssertEqual(try MCPOAuthManager.authorizationCode(
            callback: URL(string: redirect + "?state=expected&code=valid")!,
            redirectURI: redirect, state: "expected"), "valid")
        for invalid in ["http://example.com:18767/mcp-callback", "http://0.0.0.0:18767/mcp-callback",
                        "http://localhost/mcp-callback", "http://localhost:80/mcp-callback",
                        redirect + "?state=fixed", "http://user@localhost:18767/mcp-callback"] {
            XCTAssertThrowsError(try MCPOAuthConfiguration.callbackURL(invalid))
        }
        for invalid in ["http://localhost:18768/mcp-callback?state=expected&code=valid",
                        "http://localhost:18767/other?state=expected&code=valid"] {
            XCTAssertThrowsError(try MCPOAuthManager.authorizationCode(
                callback: URL(string: invalid)!, redirectURI: redirect, state: "expected"))
        }
    }
}

extension ChatLayoutTests {
    func testMCPEventStreamPreservesFramingMultilineDataAndNotificationBoundaries() {
        var decoder = MCPEventStreamDecoder()
        let source = ": keepalive\r\n\r\nevent: message\r\ndata: {\"jsonrpc\":\"2.0\",\r\ndata: \"id\":7,\"result\":{}}\r\n\r\ndata: notification\n\ndata: partial"
        var events: [MCPEventStreamDecoder.Event] = []
        for byte in source.utf8 {
            if let event = decoder.append(byte) { events.append(event) }
        }
        XCTAssertEqual(events.map(\.name), ["message", "message"])
        XCTAssertEqual(events.map(\.data), ["{\"jsonrpc\":\"2.0\",\n\"id\":7,\"result\":{}}", "notification"])
    }
}

extension ChatLayoutTests {
    func testLegacyMCPOAuthIdentityRemainsStableAcrossReloadsAndIsolatesClients() throws {
        let source = ["clientID": "legacy-client", "redirectURI": "http://localhost:18767/mcp-callback", "tokenURL": "https://example.com/token"]
        func decode(_ fields: [String: String]) throws -> MCPOAuthConfiguration {
            try JSONDecoder().decode(MCPOAuthConfiguration.self, from: JSONSerialization.data(withJSONObject: fields))
        }
        let first = try decode(source)
        let reloaded = try decode(source)
        XCTAssertEqual(first, reloaded, "Token lookup hashes the entire configuration")
        XCTAssertEqual(MCPOAuthManager.secretKey(first), MCPOAuthManager.secretKey(reloaded))
        XCTAssertEqual(first, try JSONDecoder().decode(MCPOAuthConfiguration.self, from: JSONEncoder().encode(first)))
        for field in ["clientID", "redirectURI", "tokenURL"] {
            var changed = source
            changed[field] = source[field]! + "-different"
            XCTAssertNotEqual(MCPOAuthManager.secretKey(first), MCPOAuthManager.secretKey(try decode(changed)))
        }
        var explicit = source
        explicit["credentialID"] = "saved-client-id"
        XCTAssertEqual(try decode(explicit).credentialID, "saved-client-id")
    }
}

extension ChatLayoutTests {
    func testLiveICalMCPHandshakeSmoke() async throws {
        guard ProcessInfo.processInfo.environment["CHATMICE_LIVE_MCP_SMOKE"] == "1" else {
            throw XCTSkip("Opt-in production check requires local MCP configuration and Keychain credentials")
        }
        let preferencesURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/xeric.com.chatmice.plist")
        let preferences = try PropertyListSerialization.propertyList(from: Data(contentsOf: preferencesURL), format: nil) as! [String: Any]
        let json = try XCTUnwrap(preferences["mcpServersJSON"] as? String)
        let configs = try JSONDecoder().decode([MCPServerConfig].self, from: Data(json.utf8))
        let config = try XCTUnwrap(configs.first { $0.url == "https://prod-ical-mcpserver.c-86fbf98.kyma.ondemand.com/mcp" })
        let service = MCPService()
        await service.reconnect(config)
        let status = await service.statuses().first
        XCTAssertTrue(status?.connected == true, status?.lastError ?? "Missing server status")
        let tools = await service.tools(forServer: config.name)
        XCTAssertTrue(tools.contains { $0.name.localizedCaseInsensitiveContains("search") })
        await service.disconnect(name: config.name)
    }
}











private final class UsageRegressionURLProtocol: URLProtocol {
    static var reported = false
    static var requestKinds: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
        }
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let streaming = json["stream"] as? Bool == true
        let messages = json["messages"] as? [[String: Any]] ?? []
        let summary = (messages.first?["content"] as? String)?.contains("durable conversation checkpoint") == true
        Self.requestKinds.append(summary ? "compaction" : "response")
        let text = summary ? "Checkpoint summary" : String(repeating: "文", count: 400)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": streaming ? "text/event-stream" : "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if streaming {
            let chunk = ["choices": [["delta": ["content": text]]]]
            let data = try! JSONSerialization.data(withJSONObject: chunk)
            let delta = "data: \(String(data: data, encoding: .utf8)!)\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n"
            client?.urlProtocol(self, didLoad: Data(delta.utf8))
            if Self.reported {
                client?.urlProtocol(self, didLoad: Data("data: {\"choices\":[],\"usage\":{\"prompt_tokens\":11,\"completion_tokens\":5,\"total_tokens\":16}}\n\n".utf8))
            }
            client?.urlProtocol(self, didLoad: Data("data: [DONE]\n\n".utf8))
        } else {
            var payload: [String: Any] = ["choices": [["message": ["content": text]]]]
            if Self.reported { payload["usage"] = ["prompt_tokens": 7, "completion_tokens": 3, "total_tokens": 10] }
            client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: payload))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
