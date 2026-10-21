import CoreData
//
//  MessageParser.swift
//  Chatmice
//
//  Created by Renat Notfullin on 25.04.2023.
//
import Foundation
import Highlightr
import SwiftUI

private struct PreparedMarkdownDocument {
    let body: String
    let footnotes: [MarkdownFootnote]
}

private enum MarkdownDocumentPreprocessor {
    private struct LinkDefinition {
        let destination: String
        let title: String?
    }

    private static let footnoteDefinitionRegex = try! NSRegularExpression(
        pattern: "^[ \\t]{0,3}\\[\\^([^]\\n]+)\\]:[ \\t]*(.*)$"
    )
    private static let linkDefinitionRegex = try! NSRegularExpression(
        pattern: #"^[ \t]{0,3}\[([^]^][^]]*)\]:[ \t]*(\S+)(?:[ \t]+(?:\"([^\"]*)\"|'([^']*)'|\(([^)]*)\)))?[ \t]*$"#
    )
    private static let footnoteReferenceRegex = try! NSRegularExpression(
        pattern: "\\[\\^([^]\\n]+)\\]"
    )
    private static let fullReferenceRegex = try! NSRegularExpression(
        pattern: "(?<!!)\\[([^]\\n]+)\\]\\[([^]\\n]*)\\]"
    )
    private static let shortcutReferenceRegex = try! NSRegularExpression(
        pattern: "(?<!!)(?<!\\])\\[([^]\\n]+)\\](?![\\[(])"
    )

    static func process(_ input: String) -> PreparedMarkdownDocument {
        let lines = input.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var linkDefinitions: [String: LinkDefinition] = [:]
        var footnoteDefinitions: [String: String] = [:]
        var hiddenLineIndices = Set<Int>()
        var isInsideCodeFence = false
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                isInsideCodeFence.toggle()
                index += 1
                continue
            }
            guard !isInsideCodeFence else {
                index += 1
                continue
            }

            if let match = firstMatch(of: footnoteDefinitionRegex, in: line),
                let identifier = capture(match, group: 1, in: line),
                let firstLine = capture(match, group: 2, in: line)
            {
                hiddenLineIndices.insert(index)
                var definitionLines = [firstLine]
                var continuationIndex = index + 1
                while continuationIndex < lines.count {
                    let continuation = lines[continuationIndex]
                    if continuation.hasPrefix("    ") {
                        definitionLines.append(String(continuation.dropFirst(4)))
                    }
                    else if continuation.hasPrefix("\t") {
                        definitionLines.append(String(continuation.dropFirst()))
                    }
                    else {
                        break
                    }
                    hiddenLineIndices.insert(continuationIndex)
                    continuationIndex += 1
                }
                footnoteDefinitions[normalizedIdentifier(identifier)] = definitionLines.joined(separator: "\n")
                index = continuationIndex
                continue
            }

            if let match = firstMatch(of: linkDefinitionRegex, in: line),
                let identifier = capture(match, group: 1, in: line),
                var destination = capture(match, group: 2, in: line)
            {
                if destination.hasPrefix("<"), destination.hasSuffix(">") {
                    destination.removeFirst()
                    destination.removeLast()
                }
                let title = (3...5).lazy.compactMap { capture(match, group: $0, in: line) }.first
                linkDefinitions[normalizedIdentifier(identifier)] = LinkDefinition(
                    destination: destination,
                    title: title
                )
                hiddenLineIndices.insert(index)
            }
            index += 1
        }

        var footnoteIndices: [String: Int] = [:]
        var orderedFootnoteIDs: [String] = []
        isInsideCodeFence = false
        let renderedLines = lines.enumerated().map { lineIndex, line -> String in
            guard !hiddenLineIndices.contains(lineIndex) else { return "" }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                isInsideCodeFence.toggle()
                return line
            }
            guard !isInsideCodeFence else { return line }

            return transformOutsideCodeSpans(line) { segment in
                let withFootnotes = replaceFootnoteReferences(
                    in: segment,
                    definitions: footnoteDefinitions,
                    indices: &footnoteIndices,
                    orderedIDs: &orderedFootnoteIDs
                )
                return replaceReferenceLinks(in: withFootnotes, definitions: linkDefinitions)
            }
        }

        let footnotes = orderedFootnoteIDs.compactMap { identifier -> MarkdownFootnote? in
            guard let definition = footnoteDefinitions[identifier],
                let footnoteIndex = footnoteIndices[identifier]
            else { return nil }
            return MarkdownFootnote(
                index: footnoteIndex,
                identifier: identifier,
                text: replaceReferenceLinks(in: definition, definitions: linkDefinitions)
            )
        }
        return PreparedMarkdownDocument(body: renderedLines.joined(separator: "\n"), footnotes: footnotes)
    }

    private static func replaceFootnoteReferences(
        in source: String,
        definitions: [String: String],
        indices: inout [String: Int],
        orderedIDs: inout [String]
    ) -> String {
        let matches = footnoteReferenceRegex.matches(
            in: source,
            range: NSRange(location: 0, length: source.utf16.count)
        )
        guard !matches.isEmpty else { return source }
        let result = NSMutableString(string: source)
        for match in matches {
            guard let rawIdentifier = capture(match, group: 1, in: source) else { continue }
            let identifier = normalizedIdentifier(rawIdentifier)
            guard definitions[identifier] != nil, indices[identifier] == nil else { continue }
            indices[identifier] = orderedIDs.count + 1
            orderedIDs.append(identifier)
        }
        for match in matches.reversed() {
            guard let rawIdentifier = capture(match, group: 1, in: source) else { continue }
            let identifier = normalizedIdentifier(rawIdentifier)
            guard let index = indices[identifier], let definition = definitions[identifier] else { continue }
            let title = escapedTitle(definition.replacingOccurrences(of: "\n", with: " "))
            result.replaceCharacters(
                in: match.range,
                with: "[\(superscript(index))](chatmice-footnote:\(index) \"\(title)\")"
            )
        }
        return result as String
    }

    private static func replaceReferenceLinks(
        in source: String,
        definitions: [String: LinkDefinition]
    ) -> String {
        var result = source
        result = replacingMatches(in: result, regex: fullReferenceRegex) { match, current in
            guard let label = capture(match, group: 1, in: current) else { return nil }
            let explicitIdentifier = capture(match, group: 2, in: current) ?? ""
            let identifier = normalizedIdentifier(explicitIdentifier.isEmpty ? label : explicitIdentifier)
            guard let definition = definitions[identifier] else { return nil }
            return inlineLink(label: label, definition: definition)
        }
        result = replacingMatches(in: result, regex: shortcutReferenceRegex) { match, current in
            guard let label = capture(match, group: 1, in: current),
                let definition = definitions[normalizedIdentifier(label)]
            else { return nil }
            return inlineLink(label: label, definition: definition)
        }
        return result
    }

    private static func inlineLink(label: String, definition: LinkDefinition) -> String {
        let title = definition.title.map { " \"\(escapedTitle($0))\"" } ?? ""
        return "[\(label)](<\(definition.destination)>\(title))"
    }

    private static func replacingMatches(
        in source: String,
        regex: NSRegularExpression,
        replacement: (NSTextCheckingResult, String) -> String?
    ) -> String {
        let matches = regex.matches(
            in: source,
            range: NSRange(location: 0, length: source.utf16.count)
        )
        guard !matches.isEmpty else { return source }
        let result = NSMutableString(string: source)
        for match in matches.reversed() {
            if let value = replacement(match, source) {
                result.replaceCharacters(in: match.range, with: value)
            }
        }
        return result as String
    }

    private static func transformOutsideCodeSpans(
        _ line: String,
        transform: (String) -> String
    ) -> String {
        var output = ""
        var segment = ""
        var activeDelimiterLength: Int?
        var index = line.startIndex

        func flushSegment() {
            output += activeDelimiterLength == nil ? transform(segment) : segment
            segment = ""
        }

        while index < line.endIndex {
            guard line[index] == "`" else {
                segment.append(line[index])
                index = line.index(after: index)
                continue
            }
            flushSegment()
            var delimiterEnd = index
            var delimiterLength = 0
            while delimiterEnd < line.endIndex, line[delimiterEnd] == "`" {
                delimiterLength += 1
                delimiterEnd = line.index(after: delimiterEnd)
            }
            output += String(line[index..<delimiterEnd])
            if activeDelimiterLength == nil {
                activeDelimiterLength = delimiterLength
            }
            else if activeDelimiterLength == delimiterLength {
                activeDelimiterLength = nil
            }
            index = delimiterEnd
        }
        flushSegment()
        return output
    }

    private static func superscript(_ number: Int) -> String {
        let digits: [Character: Character] = [
            "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
            "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        ]
        return String(String(number).map { digits[$0] ?? $0 })
    }

    private static func normalizedIdentifier(_ identifier: String) -> String {
        identifier
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }

    private static func escapedTitle(_ title: String) -> String {
        title.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func firstMatch(
        of regex: NSRegularExpression,
        in source: String
    ) -> NSTextCheckingResult? {
        regex.firstMatch(in: source, range: NSRange(location: 0, length: source.utf16.count))
    }

    private static func capture(
        _ match: NSTextCheckingResult,
        group: Int,
        in source: String
    ) -> String? {
        guard group < match.numberOfRanges else { return nil }
        let range = match.range(at: group)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: source) else { return nil }
        return String(source[swiftRange])
    }
}

struct MessageParser {
    @State var colorScheme: ColorScheme

    enum BlockType {
        case text
        case codeBlock
        case formulaBlock
        case formulaLine
        case dollarFormulaDelimiter
        case thinking
        case toolActivity
        case imageUUID
        case fileUUID
    }

    func detectBlockType(line: String) -> BlockType {
        let trimmedLine = line.trimmingCharacters(in: .whitespaces)

        if trimmedLine.hasPrefix(ToolActivityRecord.openingTag) {
            return .toolActivity
        }
        else if trimmedLine.hasPrefix("<think>") {
            return .thinking
        }
        else if trimmedLine.hasPrefix("```") {
            return .codeBlock
        }
        else if trimmedLine == "$$" {
            return .dollarFormulaDelimiter
        }
        else if trimmedLine.hasPrefix("$$"), trimmedLine.hasSuffix("$$"), trimmedLine.count > 4 {
            return .formulaLine
        }
        else if trimmedLine.hasPrefix("\\[") {
            return trimmedLine.replacingOccurrences(of: " ", with: "") == "\\[" ? .formulaBlock : .formulaLine
        }
        else if trimmedLine.hasPrefix("\\]") {
            return .formulaLine
        }
        else if trimmedLine.hasPrefix("<file-uuid>") {
            return .fileUUID
        }
        else if trimmedLine.hasPrefix("<image-uuid>") {
            return .imageUUID
        }
        else {
            return .text
        }
    }

    func parseMessageFromString(input: String) -> [MessageElements] {

        let document = MarkdownDocumentPreprocessor.process(input)
        let lines = document.body.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
        var elements: [MessageElements] = []
        var currentHeader: [String] = []
        var currentTableAlignments: [MarkdownTableAlignment] = []
        var currentTableData: [[String]] = []
        var isTableOpen = false
        var tableDelimiterLineIndex: Int?
        var textLines: [String] = []
        var codeLines: [String] = []
        var formulaLines: [String] = []
        var isCodeBlockOpened = false
        var isFormulaBlockOpened = false
        var codeBlockLanguage = ""
        var leadingSpaces = 0

        func toggleCodeBlock(line: String) {
            if isCodeBlockOpened {
                appendCodeBlockIfNeeded()
                isCodeBlockOpened = false
                codeBlockLanguage = ""
                leadingSpaces = 0
            }
            else {
                // extract codeBlockLanguage and remove leading spaces
                codeBlockLanguage = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "```", with: "")
                isCodeBlockOpened = true
            }
        }

        func openFormulaBlock() {
            isFormulaBlockOpened = true
        }

        func closeFormulaBlock() {
            isFormulaBlockOpened = false
        }

        func handleFormulaLine(line: String) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let formulaString: String
            if trimmed.hasPrefix("$$"), trimmed.hasSuffix("$$"), trimmed.count > 4 {
                formulaString = String(trimmed.dropFirst(2).dropLast(2))
            }
            else {
                formulaString = line
                    .replacingOccurrences(of: "\\[", with: "")
                    .replacingOccurrences(of: "\\]", with: "")
            }
            formulaLines.append(formulaString)
        }

        func appendFormulaLines() {
            let combinedLines = formulaLines.joined(separator: "\n")
            if !combinedLines.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                elements.append(.formula(combinedLines))
            }
            formulaLines = []
        }

        func parseTableRow(_ line: String) -> [String]? {
            var cells = [""]
            var sawSeparator = false
            var consecutiveBackslashes = 0

            for character in line {
                if character == "\\" {
                    cells[cells.count - 1].append(character)
                    consecutiveBackslashes += 1
                    continue
                }

                if character == "|" {
                    if consecutiveBackslashes.isMultiple(of: 2) == false {
                        cells[cells.count - 1].removeLast()
                        cells[cells.count - 1].append(character)
                    }
                    else {
                        cells.append("")
                        sawSeparator = true
                    }
                }
                else {
                    cells[cells.count - 1].append(character)
                }
                consecutiveBackslashes = 0
            }

            guard sawSeparator else { return nil }
            cells = cells.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if cells.first?.isEmpty == true { cells.removeFirst() }
            if cells.last?.isEmpty == true { cells.removeLast() }
            return cells
        }

        func alignment(for delimiter: String) -> MarkdownTableAlignment? {
            var marker = delimiter.trimmingCharacters(in: .whitespacesAndNewlines)
            let alignsLeading = marker.first == ":"
            let alignsTrailing = marker.last == ":"
            if alignsLeading { marker.removeFirst() }
            if alignsTrailing, !marker.isEmpty { marker.removeLast() }
            guard marker.count >= 3, marker.allSatisfy({ $0 == "-" }) else { return nil }
            if alignsLeading && alignsTrailing { return .center }
            return alignsTrailing ? .trailing : .leading
        }

        func parseTableDelimiter(_ line: String) -> [MarkdownTableAlignment]? {
            guard let cells = parseTableRow(line), !cells.isEmpty else { return nil }
            let alignments = cells.compactMap { alignment(for: $0) }
            return alignments.count == cells.count ? alignments : nil
        }

        func normalizedTableRow(_ cells: [String], columnCount: Int) -> [String] {
            if cells.count == columnCount { return cells }
            if cells.count > columnCount { return Array(cells.prefix(columnCount)) }
            return cells + Array(repeating: "", count: columnCount - cells.count)
        }

        func combineTextLinesIfNeeded() {
            if !textLines.isEmpty {
                let combinedText = textLines.reduce("") { (result, line) -> String in
                    if result.isEmpty {
                        return line
                    }
                    else {
                        return result + "\n" + line
                    }
                }
                elements.append(.text(combinedText))
                textLines = []
            }
        }

        func appendTableIfNeeded() {
            if isTableOpen {
                appendTable()
            }
        }

        func appendTable() {
            elements.append(
                .table(
                    header: currentHeader,
                    alignments: currentTableAlignments,
                    data: currentTableData
                )
            )
            currentHeader = []
            currentTableAlignments = []
            currentTableData = []
            isTableOpen = false
        }

        func appendCodeBlockIfNeeded() {
            if !codeLines.isEmpty {
                let combinedCode = codeLines.joined(separator: "\n")
                elements.append(.code(code: combinedCode, lang: codeBlockLanguage, indent: leadingSpaces))
                codeLines = []
            }
        }

        func handleLineWithInlineAttachments(_ line: String, isLastLine: Bool) {
            let imagePattern = "<image-uuid>(.*?)</image-uuid>"
            let filePattern = "<file-uuid>(.*?)</file-uuid>"

            guard let imageRegex = try? NSRegularExpression(pattern: imagePattern, options: []),
                let fileRegex = try? NSRegularExpression(pattern: filePattern, options: [])
            else {
                textLines.append(line)
                return
            }

            let nsString = line as NSString
            var currentLocation = 0
            var pendingText = ""

            func flushPendingText(allowEmptyNewline: Bool = false) {
                guard !pendingText.isEmpty || allowEmptyNewline else { return }
                elements.append(.text(pendingText))
                pendingText = ""
            }

            func nextMatch(after location: Int) -> (type: BlockType, match: NSTextCheckingResult)? {
                let searchRange = NSRange(location: location, length: nsString.length - location)
                let nextImage = imageRegex.firstMatch(in: line, options: [], range: searchRange)
                let nextFile = fileRegex.firstMatch(in: line, options: [], range: searchRange)

                switch (nextImage, nextFile) {
                case (let image?, let file?):
                    return image.range.location <= file.range.location
                        ? (.imageUUID, image)
                        : (.fileUUID, file)
                case (let image?, nil):
                    return (.imageUUID, image)
                case (nil, let file?):
                    return (.fileUUID, file)
                default:
                    return nil
                }
            }

            while let next = nextMatch(after: currentLocation) {
                let matchRange = next.match.range
                let textLength = matchRange.location - currentLocation
                if textLength > 0 {
                    let segment = nsString.substring(with: NSRange(location: currentLocation, length: textLength))
                    pendingText += segment
                }

                if !pendingText.isEmpty {
                    flushPendingText()
                }

                var appendedAttachment = false
                if next.match.numberOfRanges > 1 {
                    let uuidRange = next.match.range(at: 1)
                    let uuidString = nsString.substring(with: uuidRange)
                    if let uuid = UUID(uuidString: uuidString) {
                        switch next.type {
                        case .imageUUID:
                            if let image = loadImageFromCoreData(uuid: uuid) {
                                elements.append(.image(image, uuid))
                                appendedAttachment = true
                            }
                        case .fileUUID:
                            if let fileInfo = loadFileFromCoreData(uuid: uuid) {
                                elements.append(.file(fileInfo))
                                appendedAttachment = true
                            }
                        default:
                            break
                        }
                    }
                }

                if !appendedAttachment {
                    let placeholder = nsString.substring(with: matchRange)
                    pendingText += placeholder
                }

                currentLocation = matchRange.location + matchRange.length

                if !pendingText.isEmpty {
                    flushPendingText()
                }
            }

            if currentLocation < nsString.length {
                let trailing = nsString.substring(from: currentLocation)
                pendingText += trailing
            }

            if !pendingText.isEmpty {
                if !isLastLine {
                    pendingText += "\n"
                }
                flushPendingText()
            }
            else if !isLastLine {
                pendingText = "\n"
                flushPendingText(allowEmptyNewline: true)
            }
        }

        func extractImageUUID(_ line: String) -> UUID? {
            let pattern = "<image-uuid>(.*?)</image-uuid>"
            if let range = line.range(of: pattern, options: .regularExpression) {
                let uuidString = String(line[range])
                    .replacingOccurrences(of: "<image-uuid>", with: "")
                    .replacingOccurrences(of: "</image-uuid>", with: "")
                return UUID(uuidString: uuidString)
            }
            return nil
        }

        func extractFileUUID(_ line: String) -> UUID? {
            let pattern = "<file-uuid>(.*?)</file-uuid>"
            if let range = line.range(of: pattern, options: .regularExpression) {
                let uuidString = String(line[range])
                    .replacingOccurrences(of: "<file-uuid>", with: "")
                    .replacingOccurrences(of: "</file-uuid>", with: "")
                return UUID(uuidString: uuidString)
            }
            return nil
        }

        func loadImageFromCoreData(uuid: UUID) -> NSImage? {
            let viewContext = PersistenceController.shared.container.viewContext
            var imageData: Data?

            viewContext.performAndWait {
                let fetchRequest: NSFetchRequest<ImageEntity> = ImageEntity.fetchRequest()
                fetchRequest.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
                fetchRequest.fetchLimit = 1

                do {
                    let results = try viewContext.fetch(fetchRequest)
                    if let imageEntity = results.first {
                        imageData = imageEntity.image
                    }
                }
                catch {
                    print("Error fetching image from CoreData: \(error)")
                }
            }

            guard let imageData else { return nil }
            return NSImage(data: imageData)
        }

        func loadFileFromCoreData(uuid: UUID) -> FileAttachmentInfo? {
            let viewContext = PersistenceController.shared.container.viewContext
            var payload: FileAttachmentInfo?

            viewContext.performAndWait {
                let fetchRequest: NSFetchRequest<DocumentEntity> = DocumentEntity.fetchRequest()
                fetchRequest.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
                fetchRequest.fetchLimit = 1

                do {
                    let results = try viewContext.fetch(fetchRequest)
                    if let documentEntity = results.first {
                        let filename = documentEntity.filename ?? "Document.pdf"
                        payload = FileAttachmentInfo(
                            id: uuid,
                            filename: filename,
                            mimeType: documentEntity.mimeType
                        )
                    }
                }
                catch {
                    print("Error fetching file from CoreData: \(error)")
                }
            }

            return payload
        }

        var thinkingLines: [String] = []
        var isThinkingBlockOpened = false

        func appendThinkingBlockIfNeeded() {
            if !thinkingLines.isEmpty {
                let combinedThinking = thinkingLines.joined(separator: "\n")
                    .replacingOccurrences(of: "<think>", with: "")
                    .replacingOccurrences(of: "</think>", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                elements.append(.thinking(combinedThinking, isExpanded: false))
                thinkingLines = []
            }
        }

        func appendToolActivity(_ line: String) {
            combineTextLinesIfNeeded()
            appendTableIfNeeded()
            guard let activity = ToolActivityRecord.decode(markerLine: line) else {
                textLines.append(line)
                return
            }
            elements.append(.toolActivity(activity))
        }

        func finalizeParsing() {
            combineTextLinesIfNeeded()
            appendCodeBlockIfNeeded()
            appendTableIfNeeded()
            appendThinkingBlockIfNeeded()
        }

        func thematicBreakMarker(in line: String) -> Character? {
            let marker = line.filter { !$0.isWhitespace }
            guard marker.count >= 3, let first = marker.first,
                first == "-" || first == "*" || first == "_",
                marker.allSatisfy({ $0 == first })
            else { return nil }
            return first
        }

        for (index, line) in lines.enumerated() {
            let isLastLine = index == lines.count - 1

            if index == tableDelimiterLineIndex {
                tableDelimiterLineIndex = nil
                continue
            }

            let isInsideStructuredBlock = isCodeBlockOpened || isFormulaBlockOpened || isThinkingBlockOpened
            if !isInsideStructuredBlock {
                if isTableOpen {
                    if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        let row = parseTableRow(line)
                    {
                        currentTableData.append(
                            normalizedTableRow(row, columnCount: currentHeader.count)
                        )
                        continue
                    }
                    appendTable()
                }

                if index + 1 < lines.count,
                    let header = parseTableRow(line),
                    let alignments = parseTableDelimiter(lines[index + 1]),
                    !header.isEmpty,
                    header.count == alignments.count
                {
                    combineTextLinesIfNeeded()
                    currentHeader = header
                    currentTableAlignments = alignments
                    currentTableData = []
                    isTableOpen = true
                    tableDelimiterLineIndex = index + 1
                    continue
                }
            }

            if !isInsideStructuredBlock, let marker = thematicBreakMarker(in: line) {
                let previousLineIsSetextTitle = marker == "-"
                    && textLines.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                if !previousLineIsSetextTitle {
                    combineTextLinesIfNeeded()
                    elements.append(.horizontalRule)
                    continue
                }
            }

            let blockType = detectBlockType(line: line)

            switch blockType {

            case .toolActivity:
                appendToolActivity(line)

            case .codeBlock:
                leadingSpaces = line.count - line.trimmingCharacters(in: .whitespaces).count
                combineTextLinesIfNeeded()
                appendTableIfNeeded()
                toggleCodeBlock(line: line)

            case .formulaBlock:
                combineTextLinesIfNeeded()
                appendTableIfNeeded()
                openFormulaBlock()

            case .dollarFormulaDelimiter:
                combineTextLinesIfNeeded()
                appendTableIfNeeded()
                if isFormulaBlockOpened {
                    closeFormulaBlock()
                    appendFormulaLines()
                }
                else {
                    openFormulaBlock()
                }

            case .formulaLine:
                combineTextLinesIfNeeded()
                appendTableIfNeeded()
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("\\]") {
                    closeFormulaBlock()
                    appendFormulaLines()
                }
                else {
                    handleFormulaLine(line: line)
                    if !isFormulaBlockOpened {
                        appendFormulaLines()
                    }
                }

            case .thinking:
                if line.contains("</think>") {
                    let thinking =
                        line
                        .replacingOccurrences(of: "<think>", with: "")
                        .replacingOccurrences(of: "</think>", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    elements.append(.thinking(thinking, isExpanded: false))
                }
                else if line.contains("<think>") {
                    combineTextLinesIfNeeded()
                    appendTableIfNeeded()
                    isThinkingBlockOpened = true

                    let firstLine = line.replacingOccurrences(of: "<think>", with: "")
                    if !firstLine.isEmpty {
                        thinkingLines.append(firstLine)
                    }
                }

            case .imageUUID:
                if let uuid = extractImageUUID(line), let image = loadImageFromCoreData(uuid: uuid) {
                    combineTextLinesIfNeeded()
                    elements.append(.image(image, uuid))
                    if !isLastLine {
                        elements.append(.text("\n"))
                    }
                }
                else {
                    textLines.append(line)
                }

            case .fileUUID:
                if let uuid = extractFileUUID(line), let fileInfo = loadFileFromCoreData(uuid: uuid) {
                    combineTextLinesIfNeeded()
                    elements.append(.file(fileInfo))
                    if !isLastLine {
                        elements.append(.text("\n"))
                    }
                }
                else {
                    textLines.append(line)
                }

            case .text:
                if isThinkingBlockOpened {
                    if line.contains("</think>") {
                        let lastLine = line.replacingOccurrences(of: "</think>", with: "")
                        if !lastLine.isEmpty {
                            thinkingLines.append(lastLine)
                        }
                        isThinkingBlockOpened = false
                        appendThinkingBlockIfNeeded()
                    }
                    else {
                        thinkingLines.append(line)
                    }
                }
                else if isCodeBlockOpened {
                    if leadingSpaces > 0 {
                        codeLines.append(String(line.dropFirst(leadingSpaces)))
                    }
                    else {
                        codeLines.append(line)
                    }
                }
                else if isFormulaBlockOpened {
                    handleFormulaLine(line: line)
                }
                else {
                    if line.contains("<image-uuid>") || line.contains("<file-uuid>") {
                        combineTextLinesIfNeeded()
                        appendTableIfNeeded()
                        handleLineWithInlineAttachments(line, isLastLine: isLastLine)
                        continue
                    }
                    textLines.append(line)
                }
            }
        }

        finalizeParsing()
        if !document.footnotes.isEmpty {
            elements.append(.footnotes(document.footnotes))
        }
        return elements
    }
}
