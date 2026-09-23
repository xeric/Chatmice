//
//  PreferencesView.swift
//  Chatmice / macai
//
//  1:1 Pixel-accurate implementation of Bartender 5 Settings window (Reference Image #2):
//  - Traffic lights top-left in sidebar
//  - Top toolbar in detail pane: [ ◫ ] <Page Title> at exact same height as traffic lights
//  - Translucent icon badges (24x24) with white symbols
//  - Solid blue pill (cornerRadius: 8) on selected row with white text
//  - Compact top hero card (52x52 icon, bold title, subtitle)
//  - Inset rounded cards below
//

import AppKit
import Foundation
import SwiftUI

enum SettingsGroup: String, CaseIterable {
    case configuration = "Configuration"
    case services = "AI Services"
    case application = "Application"

    var pages: [SettingsPage] {
        switch self {
        case .configuration:
            return [.general, .appearance]
        case .services:
            return [.providers, .assistants, .mcp, .skills]
        case .application:
            return [.backup, .dangerZone]
        }
    }
}

enum SettingsPage: String, CaseIterable, Identifiable {
    case general = "General"
    case appearance = "Appearance"
    case providers = "Providers"
    case assistants = "AI Assistants"
    case mcp = "MCP Servers"
    case skills = "Skills & Tools"
    case backup = "Backup & Restore"
    case dangerZone = "Danger Zone"

    var id: String { rawValue }
    var title: String { rawValue }

    var subtitle: String {
        switch self {
        case .general:
            return "Configure app startup, notifications, and general preferences."
        case .appearance:
            return "Customize themes, font sizes, and code typography."
        case .providers:
            return "Configure endpoint connection parameters and models."
        case .assistants:
            return "Manage system instructions, avatars, and AI personas."
        case .mcp:
            return "Configure Model Context Protocol external tool servers."
        case .skills:
            return "Configure local skills discovery and bash automation."
        case .backup:
            return "Export and restore Chatmice database and chat history."
        case .dangerZone:
            return "Purge application data and reset system configurations."
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintpalette"
        case .providers: return "cpu"
        case .assistants: return "person.2"
        case .mcp: return "hammer"
        case .skills: return "arrow.triangle.branch"
        case .backup: return "externaldrive"
        case .dangerZone: return "flame"
        }
    }
}

struct PreferencesView: View {
    @StateObject private var store = ChatStore(persistenceController: PersistenceController.shared)
    @State private var selectedPage: SettingsPage = .providers

    var body: some View {
        HStack(spacing: 0) {
            // MARK: - Left Sidebar (matching Bartender 5)
            VStack(alignment: .leading, spacing: 0) {
                // Top area reserved for macOS traffic lights (height 52)
                Color.clear
                    .frame(height: 52)

                // Scrollable sidebar categories
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(SettingsGroup.allCases, id: \.self) { group in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(group.rawValue)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Color.secondary.opacity(0.8))
                                    .padding(.horizontal, 10)
                                    .padding(.bottom, 2)

                                ForEach(group.pages) { page in
                                    sidebarButton(page)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 16)
                }
            }
            .frame(width: 215)
            .background(Color(NSColor.controlBackgroundColor))

            // Vertical 1px Divider
            Rectangle()
                .fill(Color(NSColor.separatorColor).opacity(0.4))
                .frame(width: 1)

            // MARK: - Right Detail Pane (matching Bartender 5)
            VStack(alignment: .leading, spacing: 0) {
                // Top Toolbar Bar: [ ◫ ]  <Page Title> (height 52, exactly on same horizontal line as traffic lights!)
                HStack(spacing: 10) {
                    Image(systemName: "sidebar.leading")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(Color.primary.opacity(0.9))

                    Text(selectedPage.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.primary)

                    Spacer()
                }
                .padding(.horizontal, 24)
                .frame(height: 52)

                // Detail Content ScrollView
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Compact Top Hero Card (matching Bartender 5 Image #2)
                        heroCard(for: selectedPage)

                        // Page Detail Form / Cards
                        pageBody(for: selectedPage)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 4)
                    .padding(.bottom, 28)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(SettingsWindowConfigurator { window in
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true
        })
        .frame(minWidth: 860, idealWidth: 940, maxWidth: 1150, minHeight: 600, idealHeight: 680, maxHeight: 900)
        .onAppear {
            store.saveInCoreData()
        }
    }

    // MARK: - Sidebar Button (matching Bartender 5)

    private func sidebarButton(_ page: SettingsPage) -> some View {
        let isSelected = selectedPage == page
        return Button(action: { selectedPage = page }) {
            HStack(spacing: 10) {
                // Translucent Icon Badge (24x24)
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.25) : Color.white.opacity(0.12))
                        .frame(width: 24, height: 24)

                    Image(systemName: page.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.white)
                }

                Text(page.title)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color(red: 0.08, green: 0.44, blue: 0.96) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Compact Hero Card (matching Bartender 5 Image #2)

    private func heroCard(for page: SettingsPage) -> some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 48, height: 48)

                Image(systemName: page.symbol)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Color.white)
            }

            Text(page.title)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Color.primary)

            Text(page.subtitle)
                .font(.system(size: 12))
                .foregroundStyle(Color.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color(NSColor.separatorColor).opacity(0.35), lineWidth: 0.5)
                )
        )
    }

    // MARK: - Page Body

    @ViewBuilder
    private func pageBody(for page: SettingsPage) -> some View {
        switch page {
        case .general:
            TabGeneralSettingsView()

        case .appearance:
            TabGeneralSettingsView()

        case .providers:
            TabAPIServicesView()

        case .assistants:
            TabAIPersonasView()

        case .mcp:
            TabMCPServersView()

        case .skills:
            TabSkillsView()

        case .backup:
            BackupRestoreView(store: store)

        case .dangerZone:
            DangerZoneView(store: store)
        }
    }
}

// MARK: - Window Accessor for Seamless Unified Titlebar

private struct SettingsWindowConfigurator: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                configure(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                configure(window)
            }
        }
    }
}
