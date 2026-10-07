//
//  PreferencesView.swift
//  Chatmice
//
//  Native macOS Settings using standard NavigationSplitView matching Bartender 5 & Apple HIG.
//

import Foundation
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case general = "General"
    case appearance = "Appearance"
    case providers = "Providers"
    case assistants = "AI Assistants"
    case mcp = "MCP Servers"
    case skills = "Skills"
    case webSearch = "Web Search"
    case tools = "Tools"
    case backup = "Backup & Restore"
    case dangerZone = "Danger Zone"
    case about = "About"

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
            return "Discover, install, enable, and manage reusable Agent Skills."
        case .webSearch:
            return "Connect search and URL retrieval providers for AI assistants."
        case .tools:
            return "Configure File Tool, Code Execution, and Computer Use."
        case .backup:
            return "Export and restore Chatmice database and chat history."
        case .dangerZone:
            return "Purge application data and reset system configurations."
        case .about:
            return "Version information, software updates, and project details."
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintpalette"
        case .providers: return "cpu"
        case .assistants: return "person.2"
        case .mcp: return "hammer"
        case .skills: return "puzzlepiece.extension"
        case .webSearch: return "globe"
        case .tools: return "wrench.and.screwdriver"
        case .backup: return "externaldrive"
        case .dangerZone: return "flame"
        case .about: return "info.circle"
        }
    }
}

struct PreferencesView: View {
    @StateObject private var store = ChatStore(persistenceController: PersistenceController.shared)
    @State private var selectedPage: SettingsPage? = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsPage.allCases, selection: $selectedPage) { page in
                settingsRow(for: page)
                    .tag(page)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 215, max: 240)
        } detail: {
            detailContent
                .navigationTitle(selectedPage?.title ?? "")
        }
        .navigationSplitViewStyle(.balanced)
        .frame(width: 960, height: 680)
        .onAppear {
            store.saveInCoreData()
            selectRequestedPage()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("OpenSettingsPage"))) { notification in
            guard let rawValue = notification.object as? String,
                  let page = SettingsPage(rawValue: rawValue)
            else { return }
            selectedPage = page
            UserDefaults.standard.removeObject(forKey: "requestedSettingsPage")
        }
    }

    private func selectRequestedPage() {
        guard let rawValue = UserDefaults.standard.string(forKey: "requestedSettingsPage"),
              let page = SettingsPage(rawValue: rawValue)
        else { return }
        selectedPage = page
        UserDefaults.standard.removeObject(forKey: "requestedSettingsPage")
    }

    private func settingsRow(for page: SettingsPage) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        page == selectedPage
                            ? Color.white.opacity(0.18)
                            : Color.primary.opacity(0.08)
                    )
                    .frame(width: 24, height: 24)

                Image(systemName: page.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(page == selectedPage ? Color.white : Color.primary.opacity(0.78))
            }

            Text(page.title)
                .font(.system(size: 13))
                .foregroundStyle(page == selectedPage ? Color.white : Color.primary)

            Spacer()
        }
    }

    // MARK: - Detail Content

    @ViewBuilder
    private var detailContent: some View {
        let page = selectedPage ?? .general
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Top Hero Card (matching Bartender 5)
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
            if page == .about {
                Image(nsImage: NSApp.applicationIconImage ?? NSImage(named: NSImage.applicationIconName) ?? NSImage())
                    .resizable()
                    .scaledToFit()
                    .frame(width: 58, height: 58)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.accentColor.opacity(0.14))
                        .frame(width: 52, height: 52)

                    Image(systemName: page.symbol)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
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
        .padding(.vertical, 20)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.055))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                )
        )
    }

    @ViewBuilder
    private func pageBody(for page: SettingsPage) -> some View {
        switch page {
        case .general:
            TabGeneralSettingsView()

        case .appearance:
            TabAppearanceSettingsView()

        case .providers:
            TabAPIServicesView()

        case .assistants:
            TabAIPersonasView()


        case .mcp:
            TabMCPServersView()

        case .skills:
            TabSkillsView()

        case .webSearch:
            TabWebSearchSettingsView()

        case .tools:
            TabToolsView()

        case .backup:
            BackupRestoreView(store: store)

        case .dangerZone:
            DangerZoneView(store: store)

        case .about:
            TabAboutView()
    }
}
}
