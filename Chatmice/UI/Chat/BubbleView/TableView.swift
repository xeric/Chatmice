//
//  TableView.swift
//  Chatmice
//
//  Created by Renat Notfullin on 15.03.2023.
//

import AppKit
import Foundation
import SwiftUI

extension ChatFontWeightPreference {
    fileprivate var tableNSFontWeight: NSFont.Weight {
        switch self {
        case .light: .light
        case .regular: .regular
        case .medium: .medium
        }
    }

    fileprivate var emphasizedTableNSFontWeight: NSFont.Weight {
        switch self {
        case .light: .regular
        case .regular: .medium
        case .medium: .semibold
        }
    }
}

extension MarkdownTableAlignment {
    fileprivate var textAlignment: NSTextAlignment {
        switch self {
        case .leading: .left
        case .center: .center
        case .trailing: .right
        }
    }

    fileprivate var frameAlignment: Alignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

private struct MarkdownTableCellText: View {
    let source: String
    let searchText: String
    let message: MessageEntity?
    let currentSearchOccurrence: SearchOccurrence?
    let elementIndex: Int
    let cellPosition: Int
    let fontSize: CGFloat
    let baseWeight: NSFont.Weight
    let emphasizedWeight: NSFont.Weight
    let alignment: MarkdownTableAlignment
    @Environment(\.colorScheme) private var colorScheme

    private func renderedText() -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        let parsed =
            (try? NSAttributedString(markdown: source, options: options))
            ?? NSAttributedString(string: source)
        let result = NSMutableAttributedString(attributedString: parsed)
        let fullRange = NSRange(location: 0, length: result.length)
        result.addAttribute(
            .font,
            value: NSFont.systemFont(ofSize: fontSize, weight: baseWeight),
            range: fullRange
        )
        let style = ChatTypography.paragraphStyle(fontSize: fontSize)
        style.paragraphSpacing = 0
        style.alignment = alignment.textAlignment
        result.addAttribute(.paragraphStyle, value: style, range: fullRange)
        result.addAttribute(
            .foregroundColor,
            value: NSColor(deviceWhite: colorScheme == .dark ? 1 : 0,
                           alpha: colorScheme == .dark ? ChatTypography.assistantTextOpacityDark : ChatTypography.assistantTextOpacityLight),
            range: fullRange
        )

        result.enumerateAttribute(.inlinePresentationIntent, in: fullRange) { value, range, _ in
            guard let rawValue = value as? Int else { return }
            let intent = InlinePresentationIntent(rawValue: UInt(rawValue))
            if intent.contains(.code) {
                result.addAttribute(
                    .font,
                    value: NSFont.monospacedSystemFont(ofSize: max(fontSize - 1, 10), weight: .regular),
                    range: range
                )
            }
            else {
                let weight = intent.contains(.stronglyEmphasized) ? emphasizedWeight : baseWeight
                var font = NSFont.systemFont(ofSize: fontSize, weight: weight)
                if intent.contains(.emphasized) {
                    font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                }
                result.addAttribute(.font, value: font, range: range)
            }
            if intent.contains(.strikethrough) {
                result.addAttribute(
                    .strikethroughStyle,
                    value: NSUnderlineStyle.single.rawValue,
                    range: range
                )
            }
        }

        MarkdownLinkTitleSupport.apply(to: result)
        applySearchHighlights(to: result)
        return result
    }

    private func applySearchHighlights(to result: NSMutableAttributedString) {
        guard !searchText.isEmpty, let messageID = message?.objectID else { return }
        let rendered = result.string
        var renderedStart = rendered.startIndex
        var sourceStart = source.startIndex

        while let renderedRange = rendered.range(
            of: searchText,
            options: .caseInsensitive,
            range: renderedStart..<rendered.endIndex
        ), let sourceRange = source.range(
            of: searchText,
            options: .caseInsensitive,
            range: sourceStart..<source.endIndex
        ) {
            let sourceNSRange = NSRange(sourceRange, in: source)
            let adjustedRange = NSRange(
                location: sourceNSRange.location + cellPosition * 10_000,
                length: sourceNSRange.length
            )
            let occurrence = SearchOccurrence(
                messageID: messageID,
                range: adjustedRange,
                elementIndex: elementIndex,
                elementType: "table"
            )
            let color = occurrence == currentSearchOccurrence
                ? NSColor(Color(hex: AppConstants.currentHighlightColor) ?? .yellow)
                : NSColor(Color(hex: AppConstants.defaultHighlightColor) ?? .gray).withAlphaComponent(0.3)
            result.addAttribute(
                .backgroundColor,
                value: color,
                range: NSRange(renderedRange, in: rendered)
            )
            renderedStart = renderedRange.upperBound
            sourceStart = sourceRange.upperBound
        }
    }

    var body: some View {
        SelectableRichText(renderedText())
    }
}

struct TableHeaderView: View {
    let header: [String]
    let alignments: [MarkdownTableAlignment]
    @Binding var searchText: String
    var message: MessageEntity?
    var currentSearchOccurrence: SearchOccurrence?
    let elementIndex: Int
    @AppStorage("chatFontSize") private var chatFontSize: Double = 15.0
    @AppStorage("chatFontWeight") private var chatFontWeight = ChatFontWeightPreference.regular.rawValue

    private var preferredFontWeight: ChatFontWeightPreference {
        ChatFontWeightPreference(rawValue: chatFontWeight) ?? .regular
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(header.indices, id: \.self) { index in
                let alignment = alignments.indices.contains(index) ? alignments[index] : .leading
                MarkdownTableCellText(
                    source: header[index],
                    searchText: searchText,
                    message: message,
                    currentSearchOccurrence: currentSearchOccurrence,
                    elementIndex: elementIndex,
                    cellPosition: index,
                    fontSize: chatFontSize - 1,
                    baseWeight: preferredFontWeight.emphasizedTableNSFontWeight,
                    emphasizedWeight: .semibold,
                    alignment: alignment
                )
                .foregroundStyle(Color.primary.opacity(0.82))
                .tableCellStyle(alignment: alignment)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                if index < header.count - 1 {
                    Divider().frame(maxHeight: .infinity)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.gray.opacity(0.15))
    }
}

struct TableRowView: View {
    let rowData: [String]
    let rowIndex: Int
    let alignments: [MarkdownTableAlignment]
    @Binding var searchText: String
    var message: MessageEntity?
    var currentSearchOccurrence: SearchOccurrence?
    let elementIndex: Int
    @AppStorage("chatFontSize") private var chatFontSize: Double = 15.0
    @AppStorage("chatFontWeight") private var chatFontWeight = ChatFontWeightPreference.regular.rawValue

    private var preferredFontWeight: ChatFontWeightPreference {
        ChatFontWeightPreference(rawValue: chatFontWeight) ?? .regular
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(rowData.indices, id: \.self) { columnIndex in
                let alignment = alignments.indices.contains(columnIndex) ? alignments[columnIndex] : .leading
                MarkdownTableCellText(
                    source: rowData[columnIndex],
                    searchText: searchText,
                    message: message,
                    currentSearchOccurrence: currentSearchOccurrence,
                    elementIndex: elementIndex,
                    cellPosition: (rowIndex + 1) * 1000 + columnIndex,
                    fontSize: chatFontSize - 1,
                    baseWeight: preferredFontWeight.tableNSFontWeight,
                    emphasizedWeight: preferredFontWeight.emphasizedTableNSFontWeight,
                    alignment: alignment
                )
                .foregroundStyle(Color.primary.opacity(0.78))
                .tableCellStyle(alignment: alignment)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                if columnIndex < rowData.count - 1 {
                    Divider().frame(maxHeight: .infinity)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(rowIndex % 2 == 0 ? Color.gray.opacity(0.1) : Color.clear)
    }
}

private struct TableCellStyle: ViewModifier {
    let alignment: MarkdownTableAlignment

    func body(content: Content) -> some View {
        content
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: alignment.frameAlignment)
            .layoutPriority(1)
    }
}

extension View {
    fileprivate func tableCellStyle(alignment: MarkdownTableAlignment) -> some View {
        modifier(TableCellStyle(alignment: alignment))
    }
}

struct TableView: View {
    let header: [String]
    let alignments: [MarkdownTableAlignment]
    let tableData: [[String]]
    @Binding var searchText: String
    var message: MessageEntity?
    var currentSearchOccurrence: SearchOccurrence?
    let elementIndex: Int
    @State private var isCopied = false
    @State private var isCopiedJSON = false

    private func copyTableToClipboard() {
        let headerString = header.joined(separator: "\t")
        let tableDataString = tableData.map { $0.joined(separator: "\t") }.joined(separator: "\n")
        let tableString = "\(headerString)\n\(tableDataString)"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(tableString, forType: .string)
    }

    private func copyTableAsJSONToClipboard() {
        let tableDictArray = tableData.map { rowData -> [String: String] in
            var rowDict: [String: String] = [:]
            for index in header.indices {
                rowDict[header[index]] = rowData.indices.contains(index) ? rowData[index] : ""
            }
            return rowDict
        }

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: tableDictArray, options: .prettyPrinted)
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                #if os(macOS)
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(jsonString, forType: .string)
                #elseif os(iOS)
                    UIPasteboard.general.string = jsonString
                #endif
            }
        }
        catch {
            print("Failed to convert table data to JSON string: \(error)")
        }
    }

    var body: some View {
        VStack {
            HStack {
                Spacer()
                Button(action: {
                    copyTableAsJSONToClipboard()
                    withAnimation {
                        isCopiedJSON = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        withAnimation {
                            isCopiedJSON = false
                        }
                    }
                }) {
                    Image(systemName: isCopiedJSON ? "checkmark" : "doc.on.doc")
                    Text("JSON")
                }
                .padding(0)
                .padding(.trailing, 16)
                .buttonStyle(PlainButtonStyle())

                Button(action: {
                    copyTableToClipboard()
                    withAnimation {
                        isCopied = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        withAnimation {
                            isCopied = false
                        }
                    }
                }) {
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                }
                .padding(0)
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.bottom, 2)
            VStack(spacing: 0) {

                TableHeaderView(
                    header: header,
                    alignments: alignments,
                    searchText: $searchText,
                    message: message,
                    currentSearchOccurrence: currentSearchOccurrence,
                    elementIndex: elementIndex
                )

                // Add a horizontal line under the table header
                Divider()

                // Display the table body
                ForEach(0..<tableData.count, id: \.self) { rowIndex in
                    TableRowView(
                        rowData: tableData[rowIndex],
                        rowIndex: rowIndex,
                        alignments: alignments,
                        searchText: $searchText,
                        message: message,
                        currentSearchOccurrence: currentSearchOccurrence,
                        elementIndex: elementIndex
                    )

                    // Add a horizontal line between rows
                    if rowIndex < tableData.count - 1 {
                        Divider()
                    }
                }
            }
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
            )
            .padding(.top, 0)
        }

    }
}
