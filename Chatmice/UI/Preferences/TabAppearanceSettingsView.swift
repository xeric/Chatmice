//
//  TabAppearanceSettingsView.swift
//  Chatmice
//

import AppKit
import SwiftUI

struct TabAppearanceSettingsView: View {
    @AppStorage("chatFontSize") private var chatFontSize: Double = 15.0
    @AppStorage("chatFontWeight") private var chatFontWeight = ChatFontWeightPreference.light.rawValue
    @AppStorage("preferredColorScheme") private var preferredColorSchemeRaw: Int = 0
    @AppStorage("codeFont") private var codeFont: String = AppConstants.firaCode
    @AppStorage("showAssistantNameInSidebar") private var showAssistantNameInSidebar: Bool = true
    @AppStorage("mainWindowBackgroundOpacity") private var mainWindowBackgroundOpacity: Double = 75
    @AppStorage("mainWindowBlurLevel") private var mainWindowBlurLevel: Double = 10
    @State private var selectedColorSchemeRaw: Int = 0


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

    private var previewFontWeight: Font.Weight {
        switch ChatFontWeightPreference(rawValue: chatFontWeight) ?? .light {
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        }
    }

    private var previewEmphasisWeight: Font.Weight {
        switch ChatFontWeightPreference(rawValue: chatFontWeight) ?? .light {
        case .light: return .regular
        case .regular: return .medium
        case .medium: return .semibold
        }
    }

    private var typographyPreview: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Lorem Ipsum")
                .font(.system(size: chatFontSize + 8, weight: previewEmphasisWeight))

            Text("A compact preview with **bold text**, *italics*, ~~strikethrough~~, and `inline code`.")
                .font(.system(size: chatFontSize, weight: previewFontWeight))

            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.secondary.opacity(0.45))
                    .frame(width: 3)
                Text("Good typography keeps quoted material distinct without interrupting the reading flow.")
                    .italic()
                    .foregroundStyle(.secondary)
            }

            Text("Lists and hierarchy")
                .font(.system(size: chatFontSize + 4, weight: previewEmphasisWeight))

            VStack(alignment: .leading, spacing: 5) {
                Text("• Primary item")
                Text("    • Nested supporting detail")
                Text("• A second item with a sample link")
                    .foregroundStyle(.blue)
            }

            Text("func greeting(for name: String) -> String {\n    \"Hello, \\(name)\"\n}")
                .font(.custom(codeFont, size: max(chatFontSize - 1, 10)))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))

            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                GridRow {
                    Text("Style").fontWeight(previewEmphasisWeight)
                    Text("Purpose").fontWeight(previewEmphasisWeight)
                }
                Divider()
                GridRow {
                    Text("Heading")
                    Text("Establish hierarchy")
                }
                GridRow {
                    Text("Body")
                    Text("Keep long-form text readable")
                }
            }

            Text("Inline formula: a² + b² = c²")
                .italic()
        }
        .font(.system(size: chatFontSize, weight: previewFontWeight))
        .foregroundStyle(.primary)
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
                        Text("Background Opacity")
                        Spacer(minLength: 24)
                        Slider(value: $mainWindowBackgroundOpacity, in: 50...100, step: 1)
                            .frame(width: 260)
                        Text("\(Int(mainWindowBackgroundOpacity))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)
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
                            .frame(width: 38, alignment: .trailing)
                    }
                    .padding(.vertical, 12)
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

            GroupBox {
                HStack(spacing: 16) {
                    Text("Show assistant name in the sidebar")
                    Spacer(minLength: 24)
                    Toggle("Show assistant name in the sidebar", isOn: $showAssistantNameInSidebar)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                .padding(8)
            } label: {
                Label("Layout", systemImage: "sidebar.left")
            }

        }
        .padding()
        .onAppear {
            selectedColorSchemeRaw = preferredColorSchemeRaw
        }
    }
}
