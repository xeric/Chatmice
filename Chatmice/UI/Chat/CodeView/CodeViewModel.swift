//
//  CodeViewModel.swift
//  Chatmice
//
//  Created by Renat Notfullin on 17.11.2024.
//

import SwiftUI

@MainActor
final class CodeViewModel: ObservableObject {
    @Published private(set) var highlightedCode: NSAttributedString
    @Published var isCopied = false
    @AppStorage("chatFontSize") private var chatFontSize: Double = 15.0
    @AppStorage("codeFont") private var codeFont: String = AppConstants.firaCode

    private(set) var code: String
    private var language: String
    private var isStreaming: Bool

    init(code: String, language: String, isStreaming: Bool) {
        self.code = code
        self.language = language
        self.isStreaming = isStreaming
        highlightedCode = Self.plainText(code, fontName: AppConstants.firaCode, fontSize: 14)
    }

    func updateSource(code: String, language: String, isStreaming: Bool) {
        self.code = code
        self.language = language
        self.isStreaming = isStreaming
    }

    func updateHighlighting(colorScheme: ColorScheme) {
        if isStreaming {
            highlightedCode = Self.plainText(code, fontName: codeFont, fontSize: chatFontSize - 1)
            return
        }
        let theme = colorScheme == .dark ? "monokai-sublime" : "color-brewer"
        let highlighted = HighlighterManager.shared.highlight(
            code: code,
            language: language,
            theme: theme,
            fontSize: chatFontSize,
            isStreaming: false
        )
        highlightedCode = highlighted ?? Self.plainText(code, fontName: codeFont, fontSize: chatFontSize - 1)
    }

    private static func plainText(_ code: String, fontName: String, fontSize: Double) -> NSAttributedString {
        NSAttributedString(
            string: code,
            attributes: [
                .font: NSFont(name: fontName, size: fontSize)
                    ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            ]
        )
    }

    func copyToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)

        withAnimation {
            isCopied = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            withAnimation {
                self.isCopied = false
            }
        }
    }
}
