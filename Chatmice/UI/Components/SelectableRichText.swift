import AppKit
import SwiftUI

/// TextKit owns selection; SwiftUI asks for a size instead of receiving size state during layout.
struct SelectableRichText: NSViewRepresentable {
    let text: NSAttributedString

    init(_ text: NSAttributedString) {
        self.text = text
    }

    func makeNSView(context: Context) -> SelectableRichTextView {
        let view = SelectableRichTextView()
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: SelectableRichTextView, context: Context) {
        context.coordinator.openURL = context.environment.openURL
        let lineLimit = context.environment.lineLimit ?? 0
        let lineBreakMode: NSLineBreakMode
        switch context.environment.truncationMode {
        case .head: lineBreakMode = .byTruncatingHead
        case .middle: lineBreakMode = .byTruncatingMiddle
        case .tail: lineBreakMode = .byTruncatingTail
        @unknown default: lineBreakMode = .byTruncatingTail
        }
        view.setContent(text, lineLimit: lineLimit, lineBreakMode: lineLimit == 0 ? .byWordWrapping : lineBreakMode)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SelectableRichTextView, context: Context) -> CGSize? {
        nsView.measuredSize(for: proposal.width)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var openURL: OpenURLAction?

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)),
                  let openURL else { return false }
            openURL(url)
            return true
        }
    }
}

final class SelectableRichTextView: NSTextView {
    // Share the text storage, not the layout: SwiftUI's width probes must never reflow the drawing container.
    private let measurementManager = NSLayoutManager()
    private let measurementContainer = NSTextContainer(containerSize: .zero)
    private var measuredSizes: [CGFloat: CGSize] = [:]
    private var immutableContent: NSAttributedString?

    init() {
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        manager.allowsNonContiguousLayout = true
        manager.backgroundLayoutEnabled = false
        let container = NSTextContainer(containerSize: .zero)
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        storage.addLayoutManager(measurementManager)
        measurementManager.addTextContainer(measurementContainer)
        measurementManager.backgroundLayoutEnabled = false
        measurementContainer.lineFragmentPadding = 0
        measurementContainer.widthTracksTextView = false
        measurementContainer.heightTracksTextView = false
        drawsBackground = false
        isEditable = false
        isSelectable = true
        isRichText = true
        isHorizontallyResizable = false
        isVerticallyResizable = false
        textContainerInset = .zero
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { nil }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard newSize.width > 0, let container = textContainer,
              container.containerSize.width != newSize.width else { return }
        container.containerSize = CGSize(width: newSize.width, height: .greatestFiniteMagnitude)
        // Pay for the real drawing width once during layout, not when scrolling first reveals a paragraph.
        layoutManager?.ensureLayout(for: container)
    }



    func setContent(_ text: NSAttributedString, lineLimit: Int = 0, lineBreakMode: NSLineBreakMode = .byWordWrapping) {
        guard let storage = textStorage, let container = textContainer else { return }
        var drawingLayoutChanged = false
        let unchangedIdentity = immutableContent === text && !(text is NSMutableAttributedString)
        if !unchangedIdentity && !storage.isEqual(to: text) {
            let ranges = selectedRanges
            storage.setAttributedString(text)
            selectedRanges = ranges.map { value in
                let range = value.rangeValue
                let location = min(range.location, storage.length)
                return NSValue(range: NSRange(location: location, length: min(range.length, storage.length - location)))
            }
            measuredSizes.removeAll(keepingCapacity: true)
            drawingLayoutChanged = true
        }
        immutableContent = text is NSMutableAttributedString ? nil : text
        if container.maximumNumberOfLines != lineLimit || container.lineBreakMode != lineBreakMode {
            container.maximumNumberOfLines = lineLimit
            container.lineBreakMode = lineBreakMode
            measurementContainer.maximumNumberOfLines = lineLimit
            measurementContainer.lineBreakMode = lineBreakMode
            measuredSizes.removeAll(keepingCapacity: true)
            drawingLayoutChanged = true
        }
        if drawingLayoutChanged {
            invalidateIntrinsicContentSize()
            needsLayout = true
            needsDisplay = true
            if bounds.width > 0 {
                layoutManager?.ensureLayout(for: container)
            }
        }
    }

    func measuredSize(for proposedWidth: CGFloat?) -> CGSize {
        let width = proposedWidth.flatMap { $0.isFinite ? max(0, $0) : nil } ?? CGFloat.greatestFiniteMagnitude
        guard width > 0 else { return .zero }
        if let size = measuredSizes[width] { return size }
        measurementContainer.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        measurementManager.ensureLayout(for: measurementContainer)
        let used = measurementManager.usedRect(for: measurementContainer)
        let height = string.isEmpty ? 0 : ceil(max(used.maxY, measurementManager.extraLineFragmentRect.maxY))
        let size = CGSize(width: width == .greatestFiniteMagnitude ? ceil(used.maxX) : width, height: height)
        // A resize can propose arbitrarily many widths; retain only a small working set per text view.
        if measuredSizes.count == 8 { measuredSizes.removeAll(keepingCapacity: true) }
        measuredSizes[width] = size
        return size
    }
}
