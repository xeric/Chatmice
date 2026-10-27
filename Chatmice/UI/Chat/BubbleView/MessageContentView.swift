//
//  MessageContentView.swift
//  Chatmice
//
//  Created by Renat on 03.04.2025.
//

import AppKit
import CoreData
import MermaidRender
import SwiftMath
import SwiftUI

enum InlineMathSegment: Equatable {
    case text(String)
    case formula(latex: String, source: String)
}

enum InlineMathParser {
    static func parse(_ input: String) -> [InlineMathSegment] {
        guard input.contains("\\(") || input.contains("$") else {
            return [.text(input)]
        }

        var segments: [InlineMathSegment] = []
        var textStart = input.startIndex
        var index = input.startIndex

        func appendText(until end: String.Index) {
            guard textStart < end else { return }
            segments.append(.text(String(input[textStart..<end])))
        }

        while index < input.endIndex {
            if input[index] == "`" {
                index = indexAfterCodeSpan(startingAt: index, in: input)
                continue
            }

            if isBackslashFormulaStart(at: index, in: input),
                let closingRange = backslashFormulaEnd(after: index, in: input)
            {
                appendText(until: index)
                let contentStart = input.index(index, offsetBy: 2)
                let latex = String(input[contentStart..<closingRange.lowerBound])
                let source = String(input[index..<closingRange.upperBound])
                segments.append(.formula(latex: latex, source: source))
                index = closingRange.upperBound
                textStart = index
                continue
            }

            if isDollarFormulaStart(at: index, in: input),
                let closingIndex = dollarFormulaEnd(after: index, in: input)
            {
                let contentStart = input.index(after: index)
                let latex = String(input[contentStart..<closingIndex])
                guard !latex.isEmpty,
                    latex.first?.isWhitespace == false,
                    latex.last?.isWhitespace == false
                else {
                    index = input.index(after: index)
                    continue
                }

                appendText(until: index)
                let sourceEnd = input.index(after: closingIndex)
                let source = String(input[index..<sourceEnd])
                segments.append(.formula(latex: latex, source: source))
                index = sourceEnd
                textStart = index
                continue
            }

            index = input.index(after: index)
        }

        appendText(until: input.endIndex)
        return segments.isEmpty ? [.text(input)] : segments
    }

    private static func isBackslashFormulaStart(at index: String.Index, in input: String) -> Bool {
        guard input[index] == "\\", !isEscaped(index, in: input) else { return false }
        let next = input.index(after: index)
        return next < input.endIndex && input[next] == "("
    }

    private static func backslashFormulaEnd(
        after openingIndex: String.Index,
        in input: String
    ) -> Range<String.Index>? {
        var index = input.index(openingIndex, offsetBy: 2)
        while index < input.endIndex {
            guard input[index] != "\n" else { return nil }
            if input[index] == "\\", !isEscaped(index, in: input) {
                let next = input.index(after: index)
                if next < input.endIndex, input[next] == ")" {
                    return index..<input.index(after: next)
                }
            }
            index = input.index(after: index)
        }
        return nil
    }

    private static func isDollarFormulaStart(at index: String.Index, in input: String) -> Bool {
        guard input[index] == "$", !isEscaped(index, in: input) else { return false }
        let next = input.index(after: index)
        guard next < input.endIndex, input[next] != "$", !input[next].isWhitespace else { return false }
        if index > input.startIndex, input[input.index(before: index)] == "$" { return false }
        return true
    }

    private static func dollarFormulaEnd(
        after openingIndex: String.Index,
        in input: String
    ) -> String.Index? {
        var index = input.index(after: openingIndex)
        while index < input.endIndex {
            guard input[index] != "\n" else { return nil }
            if input[index] == "$", !isEscaped(index, in: input) {
                let next = input.index(after: index)
                if next == input.endIndex || input[next] != "$" {
                    return index
                }
            }
            index = input.index(after: index)
        }
        return nil
    }

    private static func indexAfterCodeSpan(
        startingAt openingIndex: String.Index,
        in input: String
    ) -> String.Index {
        var openingEnd = openingIndex
        var delimiterLength = 0
        while openingEnd < input.endIndex, input[openingEnd] == "`" {
            delimiterLength += 1
            openingEnd = input.index(after: openingEnd)
        }

        let delimiter = String(repeating: "`", count: delimiterLength)
        guard
            let closingRange = input.range(
                of: delimiter,
                range: openingEnd..<input.endIndex
            )
        else {
            return input.endIndex
        }
        return closingRange.upperBound
    }

    private static func isEscaped(_ index: String.Index, in input: String) -> Bool {
        var cursor = index
        var backslashCount = 0
        while cursor > input.startIndex {
            let previous = input.index(before: cursor)
            guard input[previous] == "\\" else { break }
            backslashCount += 1
            cursor = previous
        }
        return backslashCount.isMultiple(of: 2) == false
    }
}
private struct InlineMathFormulaPlaceholder {
    let marker: String
    let latex: String
    let source: String
}

private struct PreparedInlineMath {
    let markdownSource: String
    let formulas: [InlineMathFormulaPlaceholder]

    init(source: String) {
        let segments = InlineMathParser.parse(source)
        var markdownSource = ""
        markdownSource.reserveCapacity(source.count)
        var formulas: [InlineMathFormulaPlaceholder] = []

        for segment in segments {
            switch segment {
            case .text(let text):
                markdownSource.append(text)
            case .formula(let latex, let originalSource):
                let marker = "\u{E000}chatmice-inline-math-\(formulas.count)\u{E001}"
                markdownSource.append(marker)
                formulas.append(
                    InlineMathFormulaPlaceholder(
                        marker: marker,
                        latex: latex,
                        source: originalSource
                    )
                )
            }
        }

        self.markdownSource = markdownSource
        self.formulas = formulas
    }
}

private enum InlineScriptKind {
    case subscriptText
    case superscriptText
}

private struct InlineScriptPlaceholder {
    let marker: String
    let content: String
    let kind: InlineScriptKind
}

private struct PreparedInlineScripts {
    let markdownSource: String
    let scripts: [InlineScriptPlaceholder]

    init(source: String) {
        var output = ""
        output.reserveCapacity(source.count)
        var scripts: [InlineScriptPlaceholder] = []
        var index = source.startIndex
        var textStart = index

        func appendText(until end: String.Index) {
            guard textStart < end else { return }
            output.append(contentsOf: source[textStart..<end])
        }

        while index < source.endIndex {
            if source[index] == "`" {
                index = Self.indexAfterCodeSpan(startingAt: index, in: source)
                continue
            }

            let delimiter = source[index]
            let kind: InlineScriptKind?
            if delimiter == "~", Self.isSingleTilde(at: index, in: source) {
                kind = .subscriptText
            }
            else if delimiter == "^", !Self.isEscaped(index, in: source) {
                kind = .superscriptText
            }
            else {
                kind = nil
            }

            if let kind,
                let closing = Self.closingDelimiter(delimiter, after: index, in: source)
            {
                let contentStart = source.index(after: index)
                let content = String(source[contentStart..<closing])
                if !content.isEmpty,
                    content.first?.isWhitespace == false,
                    content.last?.isWhitespace == false
                {
                    appendText(until: index)
                    let marker = "\u{E000}chatmice-inline-script-\(scripts.count)\u{E001}"
                    output.append(marker)
                    scripts.append(InlineScriptPlaceholder(marker: marker, content: content, kind: kind))
                    index = source.index(after: closing)
                    textStart = index
                    continue
                }
            }
            index = source.index(after: index)
        }

        appendText(until: source.endIndex)
        markdownSource = output
        self.scripts = scripts
    }

    private static func isSingleTilde(at index: String.Index, in source: String) -> Bool {
        guard !isEscaped(index, in: source) else { return false }
        let previousIsTilde = index > source.startIndex && source[source.index(before: index)] == "~"
        let next = source.index(after: index)
        let nextIsTilde = next < source.endIndex && source[next] == "~"
        return !previousIsTilde && !nextIsTilde
    }

    private static func closingDelimiter(
        _ delimiter: Character,
        after opening: String.Index,
        in source: String
    ) -> String.Index? {
        var index = source.index(after: opening)
        while index < source.endIndex {
            guard source[index] != "\n" else { return nil }
            if source[index] == delimiter, !isEscaped(index, in: source) {
                if delimiter != "~" || isSingleTilde(at: index, in: source) {
                    return index
                }
            }
            index = source.index(after: index)
        }
        return nil
    }

    private static func indexAfterCodeSpan(
        startingAt opening: String.Index,
        in source: String
    ) -> String.Index {
        var openingEnd = opening
        var delimiterLength = 0
        while openingEnd < source.endIndex, source[openingEnd] == "`" {
            delimiterLength += 1
            openingEnd = source.index(after: openingEnd)
        }
        let delimiter = String(repeating: "`", count: delimiterLength)
        return source.range(of: delimiter, range: openingEnd..<source.endIndex)?.upperBound
            ?? source.endIndex
    }

    private static func isEscaped(_ index: String.Index, in source: String) -> Bool {
        var cursor = index
        var count = 0
        while cursor > source.startIndex {
            let previous = source.index(before: cursor)
            guard source[previous] == "\\" else { break }
            count += 1
            cursor = previous
        }
        return count.isMultiple(of: 2) == false
    }
}

enum MarkdownLinkTitleSupport {
    static let alternateDescriptionKey = NSAttributedString.Key("NSAlternateDescription")
    static let toolTipKey = NSAttributedString.Key("NSToolTip")

    static func apply(to attributedString: NSMutableAttributedString) {
        let range = NSRange(location: 0, length: attributedString.length)
        attributedString.enumerateAttribute(alternateDescriptionKey, in: range) { value, valueRange, _ in
            guard let title = value as? String, !title.isEmpty else { return }
            attributedString.addAttribute(toolTipKey, value: title, range: valueRange)
        }
    }

    static func firstTitle(in attributedString: NSAttributedString) -> String? {
        var title: String?
        let range = NSRange(location: 0, length: attributedString.length)
        attributedString.enumerateAttribute(alternateDescriptionKey, in: range) { value, _, stop in
            guard let candidate = value as? String, !candidate.isEmpty else { return }
            title = candidate
            stop.pointee = true
        }
        return title
    }
}

private final class InlineMathRenderResult: NSObject {
    let image: NSImage
    let descent: CGFloat

    init(image: NSImage, descent: CGFloat) {
        self.image = image
        self.descent = descent
    }
}

private final class InlineMathRenderer {
    static let shared = InlineMathRenderer()

    private let cache = NSCache<NSString, InlineMathRenderResult>()

    private init() {
        cache.countLimit = 256
    }

    func attachment(
        latex: String,
        font: NSFont,
        color: NSColor
    ) -> NSTextAttachment? {
        guard let rendered = render(latex: latex, fontSize: font.pointSize, color: color) else {
            return nil
        }

        let attachment = NSTextAttachment()
        attachment.image = rendered.image
        attachment.bounds = CGRect(
            x: 0,
            y: -rendered.descent,
            width: rendered.image.size.width,
            height: rendered.image.size.height
        )
        return attachment
    }

    private func render(
        latex: String,
        fontSize: CGFloat,
        color: NSColor
    ) -> InlineMathRenderResult? {
        let key = "\(latex)|\(fontSize)|\(color.description)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }

        let label = MTMathUILabel(frame: .zero)
        label.font = MTFontManager().termesFont(withSize: fontSize)
        label.fontSize = fontSize
        label.textColor = color
        label.textAlignment = .left
        label.labelMode = .text
        label.displayErrorInline = false
        label.latex = latex

        guard label.error == nil else { return nil }
        let fittingSize = label.fittingSize
        guard fittingSize.width > 0, fittingSize.height > 0 else { return nil }

        let size = CGSize(
            width: ceil(fittingSize.width),
            height: ceil(fittingSize.height)
        )
        label.frame = CGRect(origin: .zero, size: size)
        label.layoutSubtreeIfNeeded()

        let image = NSImage(data: label.dataWithPDF(inside: label.bounds))
        guard let image else { return nil }
        image.size = size
        image.accessibilityDescription = latex

        let rendered = InlineMathRenderResult(
            image: image,
            descent: label.displayList?.descent ?? abs(fontSize * 0.2)
        )
        cache.setObject(rendered, forKey: key)
        return rendered
    }
}

extension ChatFontWeightPreference {
    fileprivate var nsFontWeight: NSFont.Weight {
        switch self {
        case .light: .light
        case .regular: .regular
        case .medium: .medium
        }
    }

    fileprivate var emphasizedNSFontWeight: NSFont.Weight {
        switch self {
        case .light: .regular
        case .regular: .medium
        case .medium: .semibold
        }
    }
}

enum MarkdownParagraphLayout {
    private static let listPattern = try! NSRegularExpression(
        pattern: "^([ \\t]*)((?:[-*+][ \\t]+(?:\\[[ xX]\\][ \\t]+)?)|(?:\\d+[.)][ \\t]+))"
    )
    private static let blankParagraphs = try! NSRegularExpression(pattern: "\\n[ \\t]*\\n(?:[ \\t]*\\n)*")

    private static let headingPattern = try! NSRegularExpression(pattern: "^ {0,3}(?:#{1,6}[ \\t]|(?:=+|-+)[ \\t]*$)")
    private static let setextPattern = try! NSRegularExpression(pattern: "^ {0,3}(?:=+|-+)[ \\t]*$")

    static func prepareSource(_ source: String) -> String {
        let lines = source.components(separatedBy: "\n")
        var result = ""
        result.reserveCapacity(source.utf16.count)
        var previousWasBoundary = true
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let range = NSRange(location: 0, length: line.utf16.count)
            let heading = headingPattern.firstMatch(in: line, range: range) != nil
            let nextLine = index + 1 < lines.count ? lines[index + 1] : ""
            let setextTitle = !trimmed.isEmpty && setextPattern.firstMatch(
                in: nextLine, range: NSRange(location: 0, length: nextLine.utf16.count)
            ) != nil
            let quote = trimmed.hasPrefix(">")
            let list = listPattern.firstMatch(in: line, range: range) != nil
            let boundary = trimmed.isEmpty || heading || setextTitle || quote
            if index > 0 {
                result += previousWasBoundary || boundary || list ? "\n" : " "
            }
            result += previousWasBoundary || boundary || list ? line : trimmed
            previousWasBoundary = boundary
        }
        return result
    }

    static func apply(to text: NSMutableAttributedString, baseStyle: NSParagraphStyle, font: NSFont) {
        let source = text.string as NSString
        var offset = 0
        var continuationIndent: CGFloat?
        var edits: [(range: NSRange, prefix: NSRange, marker: String, style: NSMutableParagraphStyle)] = []
        while offset < source.length {
            let range = source.paragraphRange(for: NSRange(location: offset, length: 0))
            let line = source.substring(with: range) as NSString
            defer { offset = NSMaxRange(range) }
            // A numbered heading is still a heading after its Markdown prefix is removed.
            if let style = text.attribute(.paragraphStyle, at: offset, effectiveRange: nil) as? NSParagraphStyle,
               style.paragraphSpacingBefore > 0 {
                continuationIndent = nil
                continue
            }
            if let match = listPattern.firstMatch(in: line as String, range: NSRange(location: 0, length: line.length)) {
                let whitespace = line.substring(with: match.range(at: 1))
                let rawMarker = line.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
                let marker: String
                if rawMarker.contains("[") {
                    marker = rawMarker.lowercased().contains("[x]") ? "☑︎" : "☐"
                } else if rawMarker.first?.isNumber == true {
                    marker = rawMarker
                } else {
                    marker = "•"
                }
                let indentation = CGFloat(whitespace.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }) * font.pointSize * 0.5
                let markerWidth = (marker as NSString).size(withAttributes: [.font: font]).width
                let contentIndent = indentation + max(font.pointSize * 4 / 3, ceil(markerWidth) + font.pointSize * 0.5)
                let style = baseStyle.mutableCopy() as! NSMutableParagraphStyle
                style.firstLineHeadIndent = indentation
                style.headIndent = contentIndent
                style.tabStops = [NSTextTab(textAlignment: .left, location: contentIndent)]
                style.paragraphSpacing = font.pointSize * ChatTypography.listItemSpacingEm
                edits.append((range, NSRange(location: offset, length: match.range.length), marker + "\t", style))
                continuationIndent = contentIndent
            } else if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            } else if let indent = continuationIndent, line.hasPrefix(" ") || line.hasPrefix("\t") {
                let trimmed = (line as String).drop(while: { $0 == " " || $0 == "\t" })
                let style = baseStyle.mutableCopy() as! NSMutableParagraphStyle
                style.firstLineHeadIndent = indent
                style.headIndent = indent
                style.paragraphSpacing = font.pointSize * ChatTypography.listItemSpacingEm
                edits.append((range, NSRange(location: offset, length: line.length - trimmed.utf16.count), "", style))
            } else {
                continuationIndent = nil
            }
        }
        for edit in edits.reversed() {
            text.addAttribute(.paragraphStyle, value: edit.style, range: edit.range)
            text.replaceCharacters(in: edit.prefix, with: edit.marker)
            if !edit.marker.isEmpty {
                text.addAttribute(.font, value: font, range: NSRange(location: edit.prefix.location, length: edit.marker.utf16.count))
                let markerColor: NSColor?
                if edit.marker.hasPrefix("☑︎") {
                    markerColor = .systemGreen
                } else if edit.marker.hasPrefix("☐") {
                    markerColor = .secondaryLabelColor
                } else {
                    markerColor = nil
                }
                if let markerColor {
                    text.addAttribute(.foregroundColor, value: markerColor,
                                      range: NSRange(location: edit.prefix.location, length: edit.marker.utf16.count - 1))
                }
            }
        }
        // Source blank lines separate paragraphs; they must not also create empty line boxes.
        let blanks = blankParagraphs.matches(in: text.string, range: NSRange(location: 0, length: text.length))
        for match in blanks.reversed() {
            text.deleteCharacters(in: NSRange(location: match.range.location + 1, length: match.range.length - 1))
        }
        while text.string.hasSuffix("\n") { text.deleteCharacters(in: NSRange(location: text.length - 1, length: 1)) }
        while text.string.hasPrefix("\n") { text.deleteCharacters(in: NSRange(location: 0, length: 1)) }
        guard text.length > 0 else { return }
        let last = (text.string as NSString).paragraphRange(for: NSRange(location: text.length - 1, length: 0))
        if let style = (text.attribute(.paragraphStyle, at: last.location, effectiveRange: nil) as? NSParagraphStyle)?
            .mutableCopy() as? NSMutableParagraphStyle {
            style.paragraphSpacing = 0
            text.addAttribute(.paragraphStyle, value: style, range: last)
        }
    }
}

private struct MarkdownFootnoteText: View {
    let source: String
    let fontSize: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        AnyView(MessageContentView(
            message: nil, content: source, isStreaming: false, own: false,
            effectiveFontSize: fontSize, colorScheme: colorScheme, inlineAttachments: true,
            reasoningDuration: nil, isActiveReasoning: false, prefetchedElements: nil,
            searchText: .constant(""), allowsStreamingLayout: false
        ))
    }
}

private final class MessageTextRenderCache {
    struct Key: Equatable {
        let source: String
        let fontSize: Double
        let own: Bool
        let fontWeight: String
        let dark: Bool
        let search: String
        let messageID: NSManagedObjectID?
        let occurrence: SearchOccurrence?
    }

    final class Entry {
        let key: Key
        let text: NSAttributedString

        init(key: Key, text: NSAttributedString) {
            self.key = key
            self.text = NSAttributedString(attributedString: text)
        }
    }

    private let entries = NSCache<NSNumber, Entry>()
    private var parsedSource: String?
    private var parsedScheme: ColorScheme?
    private var parsedElements: [MessageElements] = []
    private var truncationSource: String?
    private var truncationRequired = false

    init() {
        entries.countLimit = 64
        entries.totalCostLimit = 4 * 1024 * 1024
    }

    func requiresTruncation(_ source: String) -> Bool {
        if truncationSource == source { return truncationRequired }
        truncationRequired = source.count > AppConstants.largeMessageSymbolsThreshold
            && !source.contains("<image-uuid>") && !source.contains("<file-uuid>")
            && !source.contains(ToolActivityRecord.openingTag)
        truncationSource = source
        return truncationRequired
    }

    func elements(for source: String, colorScheme: ColorScheme) -> [MessageElements] {
        if parsedSource == source, parsedScheme == colorScheme { return parsedElements }
        // Attachment resolution consults Core Data; an unchanged UUID tag need not mean unchanged data.
        if source.contains("<image-uuid>") || source.contains("<file-uuid>") {
            return MessageParser(colorScheme: colorScheme).parseMessageFromString(input: source)
        }
        parsedElements = MessageParser(colorScheme: colorScheme).parseMessageFromString(input: source)
        parsedSource = source
        parsedScheme = colorScheme
        return parsedElements
    }


    func entry(for index: Int, key: Key) -> Entry? {
        guard let entry = entries.object(forKey: NSNumber(value: index)), entry.key == key else { return nil }
        return entry
    }

    func store(_ entry: Entry, at index: Int) {
        entries.setObject(entry, forKey: NSNumber(value: index), cost: entry.text.length * 16)
    }
}

struct MessageContentView: View {
    var message: MessageEntity?
    let content: String
    let isStreaming: Bool
    let own: Bool
    let effectiveFontSize: Double
    let colorScheme: ColorScheme
    let inlineAttachments: Bool
    let reasoningDuration: TimeInterval?
    let isActiveReasoning: Bool
    let prefetchedElements: [MessageElements]?
    @Binding var searchText: String
    var currentSearchOccurrence: SearchOccurrence?
    var allowsStreamingLayout = true

    @State private var showFullMessage = false
    @State private var isParsingFullMessage = false
    @State private var expandedReasoningElements: Set<String> = []
    @State private var expandedToolElements: Set<String> = []
    @State private var copiedMermaidItem: String?
    @State private var hasUsedStreamingLayout = false
    @State private var textRenderCache = MessageTextRenderCache()
    @AppStorage("chatFontWeight") private var chatFontWeight = ChatFontWeightPreference.regular.rawValue

    private var preferredFontWeight: ChatFontWeightPreference {
        ChatFontWeightPreference(rawValue: chatFontWeight) ?? .regular
    }

    private let largeMessageSymbolsThreshold = AppConstants.largeMessageSymbolsThreshold

    var body: some View {
        Group {
            if !own && allowsStreamingLayout && (isStreaming || hasUsedStreamingLayout) {
                StreamingMarkdownContentView(
                    message: message,
                    content: content,
                    effectiveFontSize: effectiveFontSize,
                    colorScheme: colorScheme,
                    reasoningDuration: reasoningDuration,
                    isStreaming: isStreaming,
                    isActiveReasoning: isActiveReasoning,
                    searchText: $searchText,
                    currentSearchOccurrence: currentSearchOccurrence
                )
            }
            else {
                VStack(alignment: .leading, spacing: ChatTypography.contentBlockSpacing) {
                    if !showFullMessage && textRenderCache.requiresTruncation(content) {
                        renderPartialContent()
                    }
                    else {
                        renderFullContent()
                    }
                }
            }
        }
        .frame(maxWidth: own ? nil : .infinity, alignment: .leading)
        .onAppear {
            if isStreaming {
                hasUsedStreamingLayout = true
            }
        }
        .onChange(of: isStreaming) { _, streaming in
            if streaming {
                hasUsedStreamingLayout = true
            }
        }
    }


    @ViewBuilder
    private func renderPartialContent() -> some View {
        let truncatedMessage = String(content.prefix(largeMessageSymbolsThreshold))
        let parsedElements = textRenderCache.elements(for: truncatedMessage, colorScheme: colorScheme)

        let elementsToRender = filterInlineAttachments(parsedElements)
        let attachmentElements = extractAttachmentElements(from: elementsToRender)
        let attachmentIndexMap = buildAttachmentIndexMap(for: elementsToRender)

        VStack(alignment: .leading, spacing: ChatTypography.contentBlockSpacing) {
            ForEach(elementsToRender.indices, id: \.self) {
                index in
                renderElement(
                    elementsToRender[index],
                    elementIndex: index,
                    attachmentElements: attachmentElements,
                    attachmentIndexMap: attachmentIndexMap
                )
            }

            HStack(spacing: 8) {
                Button(action: {
                    isParsingFullMessage = true
                    // Parse the full message in background: very long messages may take long time to parse (and even cause app crash)
                    DispatchQueue.global(qos: .userInitiated).async {
                        let parser = MessageParser(colorScheme: colorScheme)
                        _ = parser.parseMessageFromString(input: content)

                        DispatchQueue.main.async {
                            showFullMessage = true
                            isParsingFullMessage = false
                        }
                    }
                }) {
                    Text("Show Full Message")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 12)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(16)
                }
                .buttonStyle(PlainButtonStyle())

                if isParsingFullMessage {
                    ProgressView()
                        .scaleEffect(0.4)
                        .frame(width: 12, height: 12)
                }
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func renderFullContent() -> some View {
        let parsedElements = prefetchedElements ?? textRenderCache.elements(for: content, colorScheme: colorScheme)
        let elementsToRender = filterInlineAttachments(parsedElements)
        let attachmentElements = extractAttachmentElements(from: elementsToRender)
        let attachmentIndexMap = buildAttachmentIndexMap(for: elementsToRender)

        VStack(alignment: .leading, spacing: ChatTypography.contentBlockSpacing) {
            ForEach(elementsToRender.indices, id: \.self) {
                index in
                renderElement(
                    elementsToRender[index],
                    elementIndex: index,
                    attachmentElements: attachmentElements,
                    attachmentIndexMap: attachmentIndexMap
                )
                .id(generateElementID(elementIndex: index))
            }
        }
    }

    private func generateElementID(elementIndex: Int) -> String {
        guard let messageID = message?.objectID else {
            return "element_\(elementIndex)"
        }
        let messageIDString = messageID.uriRepresentation().absoluteString
        return "\(messageIDString)_element_\(elementIndex)"
    }

    private func reasoningElementKey(for elementIndex: Int) -> String {
        guard let messageID = message?.objectID else {
            return "thinking_\(elementIndex)"
        }
        let messageIDString = messageID.uriRepresentation().absoluteString
        return "\(messageIDString)_thinking_\(elementIndex)"
    }

    private func reasoningExpansionBinding(for elementIndex: Int) -> Binding<Bool> {
        let key = reasoningElementKey(for: elementIndex)
        return Binding(
            get: { expandedReasoningElements.contains(key) },
            set: { isExpanded in
                if isExpanded {
                    expandedReasoningElements.insert(key)
                }
                else {
                    expandedReasoningElements.remove(key)
                }
            }
        )
    }
    private func toolElementKey(for elementIndex: Int) -> String {
        guard let messageID = message?.objectID else {
            return "tool_\(elementIndex)"
        }
        return "\(messageID.uriRepresentation().absoluteString)_tool_\(elementIndex)"
    }

    private func toolExpansionBinding(for elementIndex: Int) -> Binding<Bool> {
        let key = toolElementKey(for: elementIndex)
        return Binding(
            get: { expandedToolElements.contains(key) },
            set: { isExpanded in
                if isExpanded {
                    expandedToolElements.insert(key)
                }
                else {
                    expandedToolElements.remove(key)
                }
            }
        )
    }

    @ViewBuilder
    private func renderElement(
        _ element: MessageElements,
        elementIndex: Int,
        attachmentElements: [MessageElements],
        attachmentIndexMap: [Int?]
    ) -> some View {
        switch element {
        case .thinking(let content, _):
            ThinkingProcessView(
                content: content,
                duration: reasoningDuration,
                isActive: isActiveReasoning,
                isExpanded: reasoningExpansionBinding(for: elementIndex)
            )
            .padding(.vertical, 4)

        case .toolActivity(let activity):
            ToolActivityView(
                activity: activity,
                isExpanded: toolExpansionBinding(for: elementIndex)
            )
            .padding(.vertical, 3)

        case .text(let text):
            renderText(text, elementIndex: elementIndex)

        case .table(let header, let alignments, let data):
            TableView(
                header: header,
                alignments: alignments,
                tableData: data,
                searchText: $searchText,
                message: message,
                currentSearchOccurrence: currentSearchOccurrence,
                elementIndex: elementIndex
            )
            .padding(.bottom, 12)

        case .horizontalRule:
            Divider()
                .overlay(Color.secondary.opacity(0.35))
                .padding(.vertical, 10)

        case .footnotes(let footnotes):
            renderFootnotes(footnotes)

        case .code(let code, let lang, let indent):
            if lang.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "mermaid",
                !isStreaming
            {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Text("Mermaid")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        mermaidCopyButton(title: "SVG", itemID: "svg-\(elementIndex)") {
                            copyMermaidSVG(code)
                        }
                        mermaidCopyButton(title: "Source", itemID: "source-\(elementIndex)") {
                            copyMermaidSource(code)
                        }
                    }

                    MermaidView(code, spacing: .regular)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
                .contextMenu {
                    Button("Copy SVG") { copyMermaidSVG(code) }
                    Button("Copy Mermaid Source") { copyMermaidSource(code) }
                }
            }
            else {
                renderCode(
                    code: code,
                    lang: lang,
                    indent: indent,
                    isStreaming: isStreaming,
                    elementIndex: elementIndex
                )
            }

        case .formula(let formula):
            if isStreaming {
                Text(formula).textSelection(.enabled)
            }
            else {
                AdaptiveMathView(equation: formula, fontSize: NSFont.systemFontSize + CGFloat(2))
                    .padding(.vertical, 16)
            }

        case .image(let image, let imageID):
            if inlineAttachments {
                renderImage(
                    image,
                    imageID: imageID,
                    elementIndex: elementIndex,
                    attachmentElements: attachmentElements,
                    attachmentIndexMap: attachmentIndexMap,
                    isOwn: own
                )
            }

        case .file(let fileInfo):
            if inlineAttachments {
                renderFile(
                    fileInfo,
                    elementIndex: elementIndex,
                    attachmentElements: attachmentElements,
                    attachmentIndexMap: attachmentIndexMap
                )
            }
        }
    }

    @ViewBuilder
    private func renderFootnotes(_ footnotes: [MarkdownFootnote]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().padding(.bottom, 2)
            ForEach(footnotes) { footnote in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(footnote.index).")
                        .font(.system(size: max(10, effectiveFontSize - 2), weight: .semibold))
                        .foregroundStyle(.secondary)
                    MarkdownFootnoteText(
                        source: footnote.text,
                        fontSize: max(10, effectiveFontSize - 1)
                    )
                }
                .id("footnote-\(footnote.identifier)")
            }
        }
        .padding(.top, 8)
    }

    private func renderText(_ text: String, elementIndex: Int = 0) -> some View {
        SelectableRichText(renderedText(text, elementIndex: elementIndex).text, fitsContentWidth: own)
            .frame(maxWidth: own ? nil : .infinity, alignment: .leading)
    }

    private func renderedText(_ text: String, elementIndex: Int) -> MessageTextRenderCache.Entry {
        let key = MessageTextRenderCache.Key(
            source: text, fontSize: effectiveFontSize, own: own,
            fontWeight: chatFontWeight, dark: colorScheme == .dark,
            search: searchText, messageID: message?.objectID, occurrence: currentSearchOccurrence
        )
        if let cached = textRenderCache.entry(for: elementIndex, key: key) { return cached }
        let normalizedText = MarkdownParagraphLayout.prepareSource(text.replacingOccurrences(
            of: "(?i)<br\\s*/?>",
            with: "\u{2028}",
            options: .regularExpression
        ).replacingOccurrences(of: " {2,}\\n", with: "\u{2028}", options: .regularExpression))
        let inlineMath = PreparedInlineMath(source: normalizedText)
        let inlineScripts = PreparedInlineScripts(source: inlineMath.markdownSource)
        let attributedString: NSAttributedString = {
            let options = AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
            let initialAttributedString =
                (try? NSAttributedString(markdown: inlineScripts.markdownSource, options: options))
                ?? NSAttributedString(string: inlineScripts.markdownSource)

            let mutableAttributedString = NSMutableAttributedString(
                attributedString: initialAttributedString
            )
            MarkdownLinkTitleSupport.apply(to: mutableAttributedString)
            let fullRange = NSRange(location: 0, length: mutableAttributedString.length)
            let systemFont = NSFont.systemFont(
                ofSize: effectiveFontSize,
                weight: own ? .regular : preferredFontWeight.nsFontWeight
            )
            applyMarkdownFontStyles(to: mutableAttributedString, baseFont: systemFont)

            let resolvedLabelColor = NSColor(
                deviceWhite: colorScheme == .dark ? 1 : 0,
                alpha: 1
            )
            let textColor =
                own
                ? resolvedLabelColor
                : resolvedLabelColor.withAlphaComponent(
                    colorScheme == .dark
                        ? ChatTypography.assistantTextOpacityDark
                        : ChatTypography.assistantTextOpacityLight
                )
            mutableAttributedString.addAttribute(
                .foregroundColor,
                value: textColor,
                range: fullRange
            )
            let paragraphStyle = ChatTypography.paragraphStyle(fontSize: effectiveFontSize, own: own)
            mutableAttributedString.addAttribute(.paragraphStyle, value: paragraphStyle, range: fullRange)

            // Setext headings use an underline on the following source line.
            if let setextRegex = try? NSRegularExpression(
                pattern: "^([^\\n]+)\\n(=+|-+)[ \\t]*$",
                options: .anchorsMatchLines
            ) {
                let matches = setextRegex.matches(
                    in: mutableAttributedString.string,
                    range: NSRange(location: 0, length: mutableAttributedString.length)
                )
                for match in matches.reversed() {
                    let fullRange = match.range(at: 0)
                    let titleRange = match.range(at: 1)
                    let markerRange = match.range(at: 2)
                    let marker = (mutableAttributedString.string as NSString).substring(with: markerRange)
                    let level = marker.first == "=" ? 1 : 2
                    let headingFontSize = ChatTypography.headingSize(level: level, bodySize: effectiveFontSize)
                    mutableAttributedString.addAttribute(
                        .font,
                        value: NSFont.systemFont(
                            ofSize: headingFontSize,
                            weight: .semibold
                        ),
                        range: titleRange
                    )
                    mutableAttributedString.addAttribute(
                        .foregroundColor,
                        value: resolvedLabelColor.withAlphaComponent(
                            colorScheme == .dark
                                ? ChatTypography.headingTextOpacityDark
                                : ChatTypography.headingTextOpacityLight
                        ),
                        range: titleRange
                    )
                    let headingStyle = paragraphStyle.mutableCopy() as? NSMutableParagraphStyle
                    headingStyle?.minimumLineHeight = effectiveFontSize * 32 / 15
                    headingStyle?.paragraphSpacingBefore =
                        effectiveFontSize * ChatTypography.majorHeadingSpacingBeforeEm
                    headingStyle?.paragraphSpacing = effectiveFontSize * ChatTypography.headingSpacingAfterEm
                    if let headingStyle {
                        mutableAttributedString.addAttribute(
                            .paragraphStyle,
                            value: headingStyle,
                            range: titleRange
                        )
                    }
                    mutableAttributedString.deleteCharacters(
                        in: NSRange(
                            location: NSMaxRange(titleRange),
                            length: NSMaxRange(fullRange) - NSMaxRange(titleRange)
                        )
                    )
                }
            }

            // Handle headers
            guard let headerRegex = try? NSRegularExpression(pattern: "^(#{1,6})\\s+(.*)", options: .anchorsMatchLines)
            else { return mutableAttributedString }
            let headerMatches = headerRegex.matches(
                in: mutableAttributedString.string,
                options: [],
                range: NSRange(location: 0, length: mutableAttributedString.string.utf16.count)
            )

            for match in headerMatches.reversed() {
                let fullMatchRange = match.range(at: 0)
                let prefixHashesRange = match.range(at: 1)
                let contentTextRange = match.range(at: 2)

                let level = prefixHashesRange.length
                let fontSize = ChatTypography.headingSize(level: level, bodySize: effectiveFontSize)
                let font = NSFont.systemFont(
                    ofSize: fontSize,
                    weight: .semibold
                )

                mutableAttributedString.addAttribute(.font, value: font, range: contentTextRange)
                mutableAttributedString.addAttribute(
                    .foregroundColor,
                    value: resolvedLabelColor.withAlphaComponent(
                        colorScheme == .dark
                            ? ChatTypography.headingTextOpacityDark
                            : ChatTypography.headingTextOpacityLight
                    ),
                    range: contentTextRange
                )
                let headingStyle = paragraphStyle.mutableCopy() as? NSMutableParagraphStyle
                headingStyle?.minimumLineHeight = effectiveFontSize * (level <= 3 ? 32.0 / 15 : 25.0 / 15)
                headingStyle?.paragraphSpacingBefore =
                    effectiveFontSize
                    * (level <= 2
                        ? ChatTypography.majorHeadingSpacingBeforeEm
                        : ChatTypography.minorHeadingSpacingBeforeEm)
                headingStyle?.paragraphSpacing = effectiveFontSize * ChatTypography.headingSpacingAfterEm
                if let headingStyle {
                    mutableAttributedString.addAttribute(.paragraphStyle, value: headingStyle, range: fullMatchRange)
                }

                let prefixToDeleteRange = NSRange(
                    location: fullMatchRange.location,
                    length: contentTextRange.location - fullMatchRange.location
                )
                mutableAttributedString.deleteCharacters(in: prefixToDeleteRange)
            }

            // Render every quote depth and replace GitHub callout markers with a styled label.
            guard let quoteRegex = try? NSRegularExpression(
                pattern: "^([ \\t]*)((?:>[ \\t]*)+)(.*)$",
                options: .anchorsMatchLines
            ) else { return mutableAttributedString }
            let quoteMatches = quoteRegex.matches(
                in: mutableAttributedString.string,
                range: NSRange(location: 0, length: mutableAttributedString.length)
            )
            let calloutStyles: [(marker: String, label: String, color: NSColor)] = [
                ("[!NOTE]", "NOTE", .systemBlue),
                ("[!TIP]", "TIP", .systemGreen),
                ("[!IMPORTANT]", "IMPORTANT", .systemPurple),
                ("[!WARNING]", "WARNING", .systemOrange),
                ("[!CAUTION]", "CAUTION", .systemRed),
            ]

            for match in quoteMatches.reversed() {
                let source = mutableAttributedString.string as NSString
                let fullMatchRange = match.range(at: 0)
                let markerRange = match.range(at: 2)
                let contentRange = match.range(at: 3)
                let quoteDepth = source.substring(with: markerRange).filter { $0 == ">" }.count
                let quoteBars = String(repeating: "│ ", count: quoteDepth)
                let prefixRange = NSRange(
                    location: fullMatchRange.location,
                    length: contentRange.location - fullMatchRange.location
                )
                mutableAttributedString.replaceCharacters(in: prefixRange, with: quoteBars)

                let barsRange = NSRange(location: fullMatchRange.location, length: quoteBars.utf16.count)
                let adjustedContentRange = NSRange(
                    location: NSMaxRange(barsRange),
                    length: contentRange.length
                )
                mutableAttributedString.addAttribute(
                    .foregroundColor,
                    value: NSColor.secondaryLabelColor,
                    range: adjustedContentRange
                )
                mutableAttributedString.addAttributes(
                    [
                        .font: NSFont.systemFont(ofSize: effectiveFontSize, weight: .semibold),
                        .foregroundColor: NSColor.tertiaryLabelColor,
                    ],
                    range: barsRange
                )

                let quoteStyle = paragraphStyle.mutableCopy() as? NSMutableParagraphStyle
                quoteStyle?.paragraphSpacing = effectiveFontSize * ChatTypography.listItemSpacingEm
                quoteStyle?.headIndent = (quoteBars as NSString).size(withAttributes: [.font: systemFont]).width
                if let quoteStyle {
                    let renderedLineRange = (mutableAttributedString.string as NSString)
                        .paragraphRange(for: NSRange(location: fullMatchRange.location, length: 0))
                    mutableAttributedString.addAttribute(
                        .paragraphStyle,
                        value: quoteStyle,
                        range: renderedLineRange
                    )
                }

                let content = source.substring(with: contentRange)
                if let callout = calloutStyles.first(where: {
                    content.uppercased().hasPrefix($0.marker)
                }) {
                    let renderedMarkerRange = NSRange(
                        location: adjustedContentRange.location,
                        length: callout.marker.utf16.count
                    )
                    mutableAttributedString.replaceCharacters(
                        in: renderedMarkerRange,
                        with: callout.label
                    )
                    mutableAttributedString.addAttributes(
                        [
                            .font: NSFont.systemFont(ofSize: effectiveFontSize - 1, weight: .semibold),
                            .foregroundColor: callout.color,
                        ],
                        range: NSRange(
                            location: renderedMarkerRange.location,
                            length: callout.label.utf16.count
                        )
                    )
                }
            }

            MarkdownParagraphLayout.apply(to: mutableAttributedString, baseStyle: paragraphStyle, font: systemFont)

            // Apply search highlighting if searchText is not empty
            if !searchText.isEmpty, let messageId = message?.objectID {
                let body = mutableAttributedString.string
                let originalBody = text
                var searchStartIndex = body.startIndex
                var originalSearchStartIndex = originalBody.startIndex

                while let range = body.range(
                    of: searchText,
                    options: .caseInsensitive,
                    range: searchStartIndex..<body.endIndex
                ),
                    let originalRange = originalBody.range(
                        of: searchText,
                        options: .caseInsensitive,
                        range: originalSearchStartIndex..<originalBody.endIndex
                    )
                {
                    let nsRange = NSRange(range, in: body)
                    let originalNSRange = NSRange(originalRange, in: originalBody)
                    let occurrence = SearchOccurrence(
                        messageID: messageId,
                        range: originalNSRange,
                        elementIndex: elementIndex,
                        elementType: "text"
                    )
                    let isCurrent = occurrence == self.currentSearchOccurrence
                    let color =
                        isCurrent
                        ? NSColor(Color(hex: AppConstants.currentHighlightColor) ?? Color.yellow)
                        : NSColor(Color(hex: AppConstants.defaultHighlightColor) ?? Color.gray).withAlphaComponent(0.3)
                    mutableAttributedString.addAttribute(.backgroundColor, value: color, range: nsRange)
                    searchStartIndex = range.upperBound
                    originalSearchStartIndex = originalRange.upperBound
                }
            }

            replaceInlineScriptPlaceholders(
                in: mutableAttributedString,
                prepared: inlineScripts,
                fallbackFont: systemFont,
                fallbackColor: textColor
            )

            replaceInlineMathPlaceholders(
                in: mutableAttributedString,
                prepared: inlineMath,
                fallbackFont: systemFont,
                fallbackColor: textColor
            )
            return mutableAttributedString
        }()

        let rendered = MessageTextRenderCache.Entry(key: key, text: attributedString)
        textRenderCache.store(rendered, at: elementIndex)
        return rendered
    }

    private func replaceInlineScriptPlaceholders(
        in attributedString: NSMutableAttributedString,
        prepared: PreparedInlineScripts,
        fallbackFont: NSFont,
        fallbackColor: NSColor
    ) {
        for script in prepared.scripts {
            let markerRange = (attributedString.string as NSString).range(of: script.marker)
            guard markerRange.location != NSNotFound else { continue }
            let attributes = attributedString.attributes(
                at: markerRange.location,
                effectiveRange: nil
            )
            let sourceFont = attributes[.font] as? NSFont ?? fallbackFont
            let sourceColor = attributes[.foregroundColor] as? NSColor ?? fallbackColor
            let scriptFont = NSFont(
                descriptor: sourceFont.fontDescriptor,
                size: max(sourceFont.pointSize * 0.75, 8)
            ) ?? sourceFont
            let baselineOffset: CGFloat
            switch script.kind {
            case .subscriptText:
                baselineOffset = -sourceFont.pointSize * 0.2
            case .superscriptText:
                baselineOffset = sourceFont.pointSize * 0.35
            }
            let replacement = NSMutableAttributedString(
                string: script.content,
                attributes: [
                    .font: scriptFont,
                    .foregroundColor: sourceColor,
                    .baselineOffset: baselineOffset,
                ]
            )
            attributedString.replaceCharacters(in: markerRange, with: replacement)
        }
    }

    private func replaceInlineMathPlaceholders(
        in attributedString: NSMutableAttributedString,
        prepared: PreparedInlineMath,
        fallbackFont: NSFont,
        fallbackColor: NSColor
    ) {
        for formula in prepared.formulas {
            let markerRange = (attributedString.string as NSString).range(of: formula.marker)
            guard markerRange.location != NSNotFound else { continue }

            let attributes = attributedString.attributes(
                at: markerRange.location,
                effectiveRange: nil
            )
            let font = attributes[.font] as? NSFont ?? fallbackFont
            let color = attributes[.foregroundColor] as? NSColor ?? fallbackColor

            let replacement: NSMutableAttributedString
            if let attachment = InlineMathRenderer.shared.attachment(
                latex: formula.latex,
                font: font,
                color: color
            ) {
                replacement = NSMutableAttributedString(attachment: attachment)
            }
            else {
                replacement = NSMutableAttributedString(string: formula.source)
            }

            for (key, value) in attributes where key != .attachment {
                replacement.addAttribute(
                    key,
                    value: value,
                    range: NSRange(location: 0, length: replacement.length)
                )
            }
            attributedString.replaceCharacters(in: markerRange, with: replacement)
        }
    }

    private func applyMarkdownFontStyles(
        to attributedString: NSMutableAttributedString,
        baseFont: NSFont
    ) {
        let fullRange = NSRange(location: 0, length: attributedString.length)
        attributedString.addAttribute(.font, value: baseFont, range: fullRange)

        attributedString.enumerateAttribute(
            .inlinePresentationIntent,
            in: fullRange
        ) { value, range, _ in
            guard let rawValue = value as? Int else { return }
            let intent = InlinePresentationIntent(rawValue: UInt(rawValue))
            if intent.contains(.strikethrough) {
                attributedString.addAttribute(
                    .strikethroughStyle,
                    value: NSUnderlineStyle.single.rawValue,
                    range: range
                )
            }


            if intent.contains(.code) {
                let codeFont = NSFont.monospacedSystemFont(
                    ofSize: max(effectiveFontSize - 1, 10),
                    weight: .regular
                )
                attributedString.addAttribute(.font, value: codeFont, range: range)
                return
            }

            let weight: NSFont.Weight
            if intent.contains(.stronglyEmphasized) {
                weight = own ? .semibold : preferredFontWeight.emphasizedNSFontWeight
            }
            else {
                weight = own ? .regular : preferredFontWeight.nsFontWeight
            }
            var font = NSFont.systemFont(ofSize: effectiveFontSize, weight: weight)
            if intent.contains(.emphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            attributedString.addAttribute(.font, value: font, range: range)
        }
    }

    @ViewBuilder
    private func renderCode(code: String, lang: String, indent: Int, isStreaming: Bool, elementIndex: Int) -> some View
    {
        CodeView(
            code: code,
            lang: lang,
            isStreaming: isStreaming,
            message: message,
            searchText: $searchText,
            currentSearchOccurrence: currentSearchOccurrence,
            elementIndex: elementIndex
        )
        .padding(.bottom, 8)
        .padding(.leading, CGFloat(indent) * 4)
        .onAppear {
            NotificationCenter.default.post(name: NSNotification.Name("CodeBlockRendered"), object: nil)
        }
    }

    @ViewBuilder
    private func renderImage(
        _ image: NSImage,
        imageID _: UUID,
        elementIndex: Int,
        attachmentElements: [MessageElements],
        attachmentIndexMap: [Int?],
        isOwn: Bool
    ) -> some View {
        let previewSize: CGFloat = isOwn ? 160 : 300
        let cornerRadius: CGFloat = 8

        let imageView = Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .cornerRadius(cornerRadius)
            .padding(.bottom, 3)
            .onTapGesture {
                if elementIndex < attachmentIndexMap.count,
                    let attachmentIndex = attachmentIndexMap[elementIndex]
                {
                    openAttachmentPreview(
                        attachmentElements: attachmentElements,
                        selectedAttachmentIndex: attachmentIndex
                    )
                }
                else {
                    QuickLookPreviewer.shared.preview(image: image, filename: "Image.jpg")
                }
            }
            .contextMenu {
                Button("Copy") {
                    AttachmentActionHelper.copyImage(image)
                }
                Button("Save") {
                    AttachmentActionHelper.saveImage(image, suggestedName: "Image.jpg")
                }
            }

        if isOwn {
            imageView
                .frame(width: previewSize, height: previewSize)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
        else {
            let aspectRatio = image.size.width / image.size.height
            let displayHeight = previewSize / aspectRatio

            imageView
                .frame(maxWidth: previewSize, maxHeight: displayHeight)
        }
    }

    @ViewBuilder
    private func renderFile(
        _ fileInfo: FileAttachmentInfo,
        elementIndex: Int,
        attachmentElements: [MessageElements],
        attachmentIndexMap: [Int?]
    ) -> some View {
        let displayName = fileInfo.filename.isEmpty ? "Document.pdf" : fileInfo.filename
        HStack(spacing: 10) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.system(size: effectiveFontSize, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("PDF document")
                    .font(.system(size: max(10, effectiveFontSize - 2)))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        .cornerRadius(10)
        .frame(maxWidth: 320, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Copy") {
                withDocumentData(fileInfo) { data in
                    AttachmentActionHelper.copyPDF(id: fileInfo.id, filename: displayName, data: data)
                }
            }
            Button("Save") {
                withDocumentData(fileInfo) { data in
                    AttachmentActionHelper.savePDF(filename: displayName, data: data)
                }
            }
        }
        .onTapGesture {
            if elementIndex < attachmentIndexMap.count,
                let attachmentIndex = attachmentIndexMap[elementIndex]
            {
                openAttachmentPreview(
                    attachmentElements: attachmentElements,
                    selectedAttachmentIndex: attachmentIndex
                )
            }
            else {
                previewFile(fileInfo)
            }
        }
    }

    private func previewFile(_ fileInfo: FileAttachmentInfo) {
        let request = makePreviewRequest(for: .file(fileInfo))
        QuickLookPreviewer.shared.preview(requests: [request], selectedIndex: 0)
    }

    private func withDocumentData(_ fileInfo: FileAttachmentInfo, completion: @escaping (Data) -> Void) {
        PersistenceController.shared.container.performBackgroundTask { context in
            let fetchRequest: NSFetchRequest<DocumentEntity> = DocumentEntity.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "id == %@", fileInfo.id as CVarArg)
            fetchRequest.fetchLimit = 1

            guard let documentEntity = try? context.fetch(fetchRequest).first,
                let fileData = documentEntity.fileData
            else {
                return
            }

            DispatchQueue.main.async {
                completion(fileData)
            }
        }
    }

    private func openAttachmentPreview(
        attachmentElements: [MessageElements],
        selectedAttachmentIndex: Int
    ) {
        guard !attachmentElements.isEmpty else { return }
        let requests = attachmentElements.map(makePreviewRequest)
        let clampedIndex = max(0, min(selectedAttachmentIndex, requests.count - 1))
        QuickLookPreviewer.shared.preview(requests: requests, selectedIndex: clampedIndex)
    }

    private func makePreviewRequest(for element: MessageElements) -> QuickLookPreviewer.PreviewItemRequest {
        switch element {
        case .image(_, let id):
            if let cached = PreviewFileHelper.cachedPreviewURL(for: id) {
                return QuickLookPreviewer.PreviewItemRequest(
                    id: id,
                    title: cached.lastPathComponent,
                    url: cached
                )
            }
            return QuickLookPreviewer.PreviewItemRequest(id: id, title: "Image.jpg") { completion in
                PersistenceController.shared.container.performBackgroundTask { context in
                    let fetchRequest: NSFetchRequest<ImageEntity> = ImageEntity.fetchRequest()
                    fetchRequest.predicate = NSPredicate(format: "id == %@", id as CVarArg)
                    fetchRequest.fetchLimit = 1

                    guard let imageEntity = try? context.fetch(fetchRequest).first,
                        let imageData = imageEntity.image
                    else {
                        completion(nil)
                        return
                    }

                    let rawExtension =
                        (imageEntity.imageFormat?.isEmpty == false)
                        ? imageEntity.imageFormat!.lowercased()
                        : "jpg"
                    let fileExtension = (rawExtension == "jpeg") ? "jpg" : rawExtension
                    let filename = "Image.\(fileExtension)"
                    let url = PreviewFileHelper.previewURL(
                        for: id,
                        data: imageData,
                        filename: filename,
                        defaultExtension: fileExtension
                    )
                    completion(url)
                }
            }
        case .file(let fileInfo):
            let displayName = fileInfo.filename.isEmpty ? "Document.pdf" : fileInfo.filename
            if let cached = PreviewFileHelper.cachedPreviewURL(for: fileInfo.id) {
                return QuickLookPreviewer.PreviewItemRequest(
                    id: fileInfo.id,
                    title: displayName,
                    url: cached
                )
            }
            return QuickLookPreviewer.PreviewItemRequest(id: fileInfo.id, title: displayName) { completion in
                PersistenceController.shared.container.performBackgroundTask { context in
                    let fetchRequest: NSFetchRequest<DocumentEntity> = DocumentEntity.fetchRequest()
                    fetchRequest.predicate = NSPredicate(format: "id == %@", fileInfo.id as CVarArg)
                    fetchRequest.fetchLimit = 1

                    guard let documentEntity = try? context.fetch(fetchRequest).first,
                        let fileData = documentEntity.fileData
                    else {
                        completion(nil)
                        return
                    }

                    let suggestedName = fileInfo.filename.isEmpty ? "Document.pdf" : fileInfo.filename
                    let baseName = URL(fileURLWithPath: suggestedName).deletingPathExtension().lastPathComponent
                    let name = "\(baseName).pdf"
                    let url = PreviewFileHelper.previewURL(
                        for: fileInfo.id,
                        data: fileData,
                        filename: name,
                        defaultExtension: "pdf"
                    )
                    completion(url)
                }
            }
        default:
            return QuickLookPreviewer.PreviewItemRequest(id: UUID(), title: nil, url: nil)
        }
    }

    private func extractAttachmentElements(from elements: [MessageElements]) -> [MessageElements] {
        elements.compactMap { element in
            switch element {
            case .image, .file:
                return element
            default:
                return nil
            }
        }
    }

    private func buildAttachmentIndexMap(for elements: [MessageElements]) -> [Int?] {
        var index = 0
        return elements.map { element in
            switch element {
            case .image, .file:
                defer { index += 1 }
                return index
            default:
                return nil
            }
        }
    }

    private func filterInlineAttachments(_ elements: [MessageElements]) -> [MessageElements] {
        guard !inlineAttachments else { return elements }

        var result: [MessageElements] = []
        var previousWasAttachment = false

        for element in elements {
            switch element {
            case .image, .file:
                previousWasAttachment = true
                continue
            case .text(let text):
                if previousWasAttachment,
                    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    previousWasAttachment = false
                    continue
                }
                previousWasAttachment = false
                result.append(.text(text))
            default:
                previousWasAttachment = false
                result.append(element)
            }
        }

        return result
    }

    private func copyMermaidSource(_ source: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(source, forType: .string)
    }

    private func copyMermaidSVG(_ source: String) {
        let theme = DiagramTheme(prefersDark: colorScheme == .dark)
        guard let svg = MermaidRenderer.svg(source: source, theme: theme, spacing: .regular) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(svg, forType: NSPasteboard.PasteboardType("public.svg-image"))
        pasteboard.setString(svg, forType: .string)
    }

    private func mermaidCopyButton(
        title: String,
        itemID: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
            copiedMermaidItem = itemID
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if copiedMermaidItem == itemID {
                    copiedMermaidItem = nil
                }
            }
        } label: {
            Label(
                copiedMermaidItem == itemID ? "Copied" : title,
                systemImage: copiedMermaidItem == itemID ? "checkmark" : "doc.on.doc"
            )
            .font(.system(size: 10, weight: .medium))
        }
        .buttonStyle(.plain)
        .help("Copy Mermaid \(title.lowercased())")
    }
}

private struct StreamingMarkdownContentView: View {
    let message: MessageEntity?
    let content: String
    let effectiveFontSize: Double
    let colorScheme: ColorScheme
    let reasoningDuration: TimeInterval?
    let isStreaming: Bool
    let isActiveReasoning: Bool
    @Binding var searchText: String
    let currentSearchOccurrence: SearchOccurrence?

    var body: some View {
        let parts = StreamingMarkdownSplitter.split(content)
        let visibleTail = StreamingMarkdownSplitter.liveText(from: parts.tail)
        VStack(alignment: .leading, spacing: ChatTypography.contentBlockSpacing) {
            ForEach(Array(parts.blocks.enumerated()), id: \.offset) { _, block in
                StableStreamingMarkdownBlock(
                    message: message,
                    content: block,
                    effectiveFontSize: effectiveFontSize,
                    colorScheme: colorScheme,
                    reasoningDuration: reasoningDuration,
                    isActiveReasoning: isActiveReasoning,
                    isStreaming: isStreaming,
                    searchText: $searchText,
                    currentSearchOccurrence: currentSearchOccurrence
                )
                .equatable()
            }

            if !parts.tail.isEmpty {
                StableStreamingMarkdownBlock(
                    message: message,
                    content: isStreaming ? visibleTail : parts.tail,
                    effectiveFontSize: effectiveFontSize,
                    colorScheme: colorScheme,
                    reasoningDuration: reasoningDuration,
                    isActiveReasoning: isActiveReasoning,
                    isStreaming: isStreaming,
                    searchText: $searchText,
                    currentSearchOccurrence: currentSearchOccurrence
                )
            }
        }
    }
}

private struct StableStreamingMarkdownBlock: View, Equatable {
    let message: MessageEntity?
    let content: String
    let effectiveFontSize: Double
    let colorScheme: ColorScheme
    let reasoningDuration: TimeInterval?
    let isActiveReasoning: Bool
    let isStreaming: Bool
    @Binding var searchText: String
    let currentSearchOccurrence: SearchOccurrence?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.message?.objectID == rhs.message?.objectID
            && lhs.content == rhs.content
            && lhs.effectiveFontSize == rhs.effectiveFontSize
            && lhs.colorScheme == rhs.colorScheme
            && lhs.reasoningDuration == rhs.reasoningDuration
            && lhs.isActiveReasoning == rhs.isActiveReasoning
            && lhs.isStreaming == rhs.isStreaming
            && lhs.searchText == rhs.searchText
            && lhs.currentSearchOccurrence == rhs.currentSearchOccurrence
    }

    var body: some View {
        MessageContentView(
            message: message,
            content: content,
            isStreaming: isStreaming,
            own: false,
            effectiveFontSize: effectiveFontSize,
            colorScheme: colorScheme,
            inlineAttachments: true,
            reasoningDuration: reasoningDuration,
            isActiveReasoning: isActiveReasoning,
            prefetchedElements: nil,
            searchText: $searchText,
            currentSearchOccurrence: currentSearchOccurrence,
            allowsStreamingLayout: false
        )
    }
}

enum StreamingMarkdownSplitter {
    struct Parts {
        let blocks: [String]
        let tail: String
    }

    static func split(_ content: String) -> Parts {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        var blocks: [String] = []
        var current = ""

        for (index, line) in lines.enumerated() {
            current += line
            if index < lines.count - 1 {
                current += "\n"
            }

            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let endsStructuredRecord =
                trimmedLine.hasPrefix(ToolActivityRecord.openingTag)
                && trimmedLine.hasSuffix(ToolActivityRecord.closingTag)
            if trimmedLine.isEmpty || endsStructuredRecord, isCompleteBlock(current) {
                if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blocks.append(current)
                }
                current = ""
            }
        }

        return Parts(blocks: blocks, tail: current)
    }

    static func liveText(from tail: String) -> String {
        var visible = tail
        while let openingRange = visible.range(of: ToolActivityRecord.openingTag) {
            let suffix = visible[openingRange.upperBound...]
            guard let closingRange = suffix.range(of: ToolActivityRecord.closingTag) else {
                visible.removeSubrange(openingRange.lowerBound...)
                break
            }
            visible.removeSubrange(openingRange.lowerBound..<closingRange.upperBound)
        }

        return
            visible
            .replacingOccurrences(of: "<think>", with: "")
            .replacingOccurrences(of: "</think>", with: "")
    }

    private static func isCompleteBlock(_ block: String) -> Bool {
        let fenceCount = block.components(separatedBy: "```").count - 1
        guard fenceCount.isMultiple(of: 2) else { return false }
        guard occurrences(of: "<think>", in: block) == occurrences(of: "</think>", in: block) else { return false }
        guard
            occurrences(of: ToolActivityRecord.openingTag, in: block)
                == occurrences(of: ToolActivityRecord.closingTag, in: block)
        else { return false }
        return true
    }

    private static func occurrences(of marker: String, in text: String) -> Int {
        text.components(separatedBy: marker).count - 1
    }
}

enum ToolActivityPresentationState: Equatable {
    case awaitingApproval
    case running
    case completed
    case failed

    var accentColor: Color {
        switch self {
        case .awaitingApproval: return .orange
        case .running: return .purple
        case .completed: return .green
        case .failed: return .red
        }
    }

    var badge: String {
        switch self {
        case .awaitingApproval: return "Approval"
        case .running: return "Running"
        case .completed: return "Completed"
        case .failed: return "Failed"
        }
    }

    var symbolName: String {
        switch self {
        case .awaitingApproval: return "hand.raised.fill"
        case .running, .completed: return "terminal.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    var canExpand: Bool {
        switch self {
        case .completed, .failed: return true
        case .awaitingApproval, .running: return false
        }
    }

    var showsProgress: Bool { self == .running }

    func title(for toolName: String) -> String {
        switch self {
        case .awaitingApproval: return "Waiting to run \(toolName)"
        case .running: return "Running \(toolName)"
        case .completed: return "Ran \(toolName)"
        case .failed: return "Failed \(toolName)"
        }
    }
}

struct ToolActivityView: View {
    let activity: ToolActivityRecord
    let state: ToolActivityPresentationState
    @Binding var isExpanded: Bool
    @State private var copied = false

    init(activity: ToolActivityRecord, isExpanded: Binding<Bool>) {
        self.activity = activity
        self.state = activity.isError ? .failed : .completed
        self._isExpanded = isExpanded
    }

    init(name: String, input: String, state: ToolActivityPresentationState) {
        self.activity = ToolActivityRecord(name: name, input: input, output: "", isError: false)
        self.state = state
        self._isExpanded = .constant(false)
    }

    var body: some View {
        let storedImage = activity.storedImage
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard state.canExpand else { return }
                isExpanded.toggle()
            } label: {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(state.accentColor.opacity(0.14))
                        if state.showsProgress {
                            ProgressView()
                                .controlSize(.small)
                                .tint(state.accentColor)
                        }
                        else {
                            Image(systemName: state.symbolName)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(state.accentColor)
                        }
                    }
                    .frame(width: 28, height: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.title(for: activity.name))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(activity.input)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 8)

                    Text(state.badge)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(state.accentColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(state.accentColor.opacity(0.12), in: Capsule())

                    if state.canExpand && storedImage == nil {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .animation(.easeInOut(duration: 0.18), value: isExpanded)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .allowsHitTesting(state.canExpand && storedImage == nil)

            if let image = storedImage {
                Divider()
                    .opacity(0.6)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("SCREENSHOT")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.writeObjects([image])
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                copied = false
                            }
                        } label: {
                            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }

                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 520, maxHeight: 360)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .padding(10)
                .background(Color.black.opacity(0.08))
            }
            else if isExpanded && state.canExpand {
                Divider()
                    .opacity(0.6)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("OUTPUT")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(activity.output, forType: .string)
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                copied = false
                            }
                        } label: {
                            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }

                    ScrollView(.vertical) {
                        Text(activity.output)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.primary.opacity(0.88))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                }
                .padding(10)
                .background(Color.black.opacity(0.08))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.78))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(state.accentColor.opacity(0.24), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .fixedSize(horizontal: false, vertical: true)
    }
}
