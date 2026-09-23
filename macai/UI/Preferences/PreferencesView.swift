//
//  PreferencesView.swift
//  Chatmice / macai
//
//  Pixel-accurate macOS Settings window matching Bartender 5 & modern Apple HIG:
//  - Unified window with full-size content view and traffic lights in sidebar
//  - NavigationSplitView with [ ◫ ] <Title> toolbar navigation
//  - Translucent icon badges and solid blue pill selection
//  - Top hero card + grouped settings cards
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
    @State private var selectedPage: SettingsPage? = .providers

    var body: some View {
        NavigationSplitView {
            sidebarContent
                .navigationSplitViewColumnWidth(min: 200, ideal: 210, max: 240)
        } detail: {
            detailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .navigationTitle(selectedPage?.title ?? "Settings")
        }
        .navigationSplitViewStyle(.balanced)
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

    // MARK: - Sidebar

    private var sidebarContent: some View {
        List(selection: $selectedPage) {
            ForEach(SettingsGroup.allCases, id: \.self) { group in
                Section(group.rawValue) {
                    ForEach(group.pages) { page in
                        sidebarRow(page)
                            .tag(page)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func sidebarRow(_ page: SettingsPage) -> some View {
        let isSelected = selectedPage == page
        return HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.22) : Color.white.opacity(0.12))
                    .frame(width: 24, height: 24)

                Image(systemName: page.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            }

            Text(page.title)
                .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? Color.white : Color.primary)

            Spacer()
        }
        .padding(.vertical, 3)
    }

    // MARK: - Detail Content

    @ViewBuilder
    private var detailContent: some View {
        let page = selectedPage ?? .providers
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Top Hero Card (matching Bartender 5 Image #1)
                heroCard(for: page)

                // Page Specific Content
                pageBody(for: page)
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 28)
        }
    }

    private func heroCard(for page: SettingsPage) -> some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 52, height: 52)

                Image(systemName: page.symbol)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Color.white)
            }

            Text(page.title)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color.primary)

            Text(page.subtitle)
                .font(.system(size: 12))
                .foregroundStyle(Color.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color(NSColor.separatorColor).opacity(0.4), lineWidth: 0.5)
                )
        )
    }

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
