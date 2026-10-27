//
//  TabAppearanceSettingsView.swift
//  Chatmice
//

import AppKit
import SwiftUI

struct TabAppearanceSettingsView: View {
    @AppStorage("chatFontSize") private var chatFontSize: Double = 15.0
    @AppStorage("chatFontWeight") private var chatFontWeight = ChatFontWeightPreference.regular.rawValue
    @AppStorage("preferredColorScheme") private var preferredColorSchemeRaw: Int = 0
    @AppStorage("codeFont") private var codeFont: String = AppConstants.firaCode
    @AppStorage("mainWindowBackgroundOpacity") private var mainWindowBackgroundOpacity: Double = 75
    @AppStorage("mainWindowBlurLevel") private var mainWindowBlurLevel: Double = 10
    @State private var selectedColorSchemeRaw: Int = 0
    @Environment(\.colorScheme) private var colorScheme


    private var preferredColorScheme: Binding<ColorScheme?> {
        Binding(
            get: {
                switch preferredColorSchemeRaw {
                case 1: return .light
                case 2: return .dark
                default: return nil
                }
            },
            set: { newValue in
                if newValue == nil {
                    let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    preferredColorSchemeRaw = isDark ? 2 : 1
                    selectedColorSchemeRaw = 0
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        preferredColorSchemeRaw = 0
                    }
                } else {
                    switch newValue {
                    case .light: preferredColorSchemeRaw = 1
                    case .dark: preferredColorSchemeRaw = 2
                    case .none: preferredColorSchemeRaw = 0
                    case .some: preferredColorSchemeRaw = 0
                    }
                    selectedColorSchemeRaw = preferredColorSchemeRaw
                }
            }
        )
    }

    private var typographyPreview: some View {
        MessageContentView(
            message: nil,
            content: """
                ## Clear hierarchy

                Comfortable line spacing keeps body text and `inline code` easy to read. Use **emphasis** sparingly, with *italics* and ~~strikethrough~~ when needed.

                - Wrapped list items stay aligned with the text, making longer explanations and technical details easier to read.
                  - Nested details retain their indentation.
                - [x] Completed task

                > Keep quoted material distinct while preserving **emphasis** and `inline code`.

                Style | Purpose
                :--- | :---
                Heading | Establish hierarchy
                Body | Keep long-form text readable

                ```swift
                func greeting() -> String {
                    "Hello, world"
                }
                ```

                Inline formula: $a^2 + b^2 = c^2$
                """,
            isStreaming: false,
            own: false,
            effectiveFontSize: chatFontSize,
            colorScheme: colorScheme,
            inlineAttachments: true,
            reasoningDuration: nil,
            isActiveReasoning: false,
            prefetchedElements: nil,
            searchText: .constant(""),
            allowsStreamingLayout: false
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }


    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 0) {
                Divider()

                HStack(alignment: .center, spacing: 28) {
                    Text("Theme")
                        .font(.headline)

                    Spacer(minLength: 24)

                    HStack(spacing: 14) {
                        ThemeButton(
                            title: "macOS",
                            isSelected: selectedColorSchemeRaw == 0,
                            mode: .system
                        ) {
                            preferredColorScheme.wrappedValue = nil
                        }

                        ThemeButton(
                            title: "Light",
                            isSelected: selectedColorSchemeRaw == 1,
                            mode: .light
                        ) {
                            preferredColorScheme.wrappedValue = .light
                        }

                        ThemeButton(
                            title: "Dark",
                            isSelected: selectedColorSchemeRaw == 2,
                            mode: .dark
                        ) {
                            preferredColorScheme.wrappedValue = .dark
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 16)

                Divider()
            }

            GroupBox {
                VStack(spacing: 0) {
                    HStack(spacing: 16) {
                        Text("Glass Tint")
                        Spacer(minLength: 24)
                        Slider(value: $mainWindowBackgroundOpacity, in: 0...100, step: 1)
                            .frame(width: 260)
                        Text("\(Int(mainWindowBackgroundOpacity))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 88, alignment: .trailing)
                    }
                    .padding(.vertical, 12)

                    Divider()

                    HStack(spacing: 16) {
                        Text("Background Blur")
                        Spacer(minLength: 24)
                        Slider(value: $mainWindowBlurLevel, in: 1...10, step: 1)
                            .frame(width: 260)
                        Text("\(Int(mainWindowBlurLevel))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 88, alignment: .trailing)
                    }
                    .padding(.vertical, 12)

                    Text("All ten positions cover the high-strength range previously represented by levels 8–10. Glass Tint colors the material without covering the frosted backdrop.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 10)
                }
                .padding(.horizontal, 8)
            } label: {
                Label("Window Background", systemImage: "square.3.layers.3d")
            }

            GroupBox {
                ScrollView {
                    typographyPreview
                        .padding(16)
                }
                .frame(minHeight: 320, maxHeight: 420)
                .background(Color(NSColor.textBackgroundColor).opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color(NSColor.separatorColor).opacity(0.5), lineWidth: 0.5)
                }
                .padding(8)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Markdown Preview", systemImage: "doc.richtext")
                    Text("Preview common Markdown styles with the current typography.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            GroupBox {
                VStack(spacing: 0) {
                    HStack(spacing: 16) {
                        Text("Text Size")
                        Spacer(minLength: 24)
                        HStack(spacing: 10) {
                            Text("A")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Slider(value: $chatFontSize, in: 10...24, step: 1)
                                .frame(width: 260)
                            Text("A")
                                .font(.system(size: 20))
                                .foregroundStyle(.secondary)
                            Text("\(Int(chatFontSize)) pt")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 42, alignment: .trailing)
                        }
                    }
                    .padding(.vertical, 12)

                    Divider()

                    HStack(spacing: 16) {
                        Text("Text Weight")
                        Spacer(minLength: 24)
                        Picker("Text Weight", selection: $chatFontWeight) {
                            ForEach(ChatFontWeightPreference.allCases) { weight in
                                Text(weight.title).tag(weight.rawValue)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 280)
                    }
                    .padding(.vertical, 12)

                    Divider()

                    HStack(spacing: 16) {
                        Text("Code Font")
                        Spacer(minLength: 24)
                        Picker("Code Font", selection: $codeFont) {
                            Text("Fira Code").tag(AppConstants.firaCode)
                            Text("PT Mono").tag(AppConstants.ptMono)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 280)
                    }
                    .padding(.vertical, 12)
                }
                .padding(.horizontal, 8)
            } label: {
                Label("Typography", systemImage: "textformat")
            }


        }
        .padding()
        .onAppear {
            selectedColorSchemeRaw = preferredColorSchemeRaw
        }
    }
}
