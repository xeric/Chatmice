//
//  PreferencesView.swift
//  Chatmice / macai
//
//  Native macOS Settings using standard NavigationSplitView matching Bartender 5 & Apple HIG.
//

import AppKit
import Foundation
import SwiftUI

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
    @State private var selectedPage: SettingsPage? = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsPage.allCases, selection: $selectedPage) { page in
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.12))
                            .frame(width: 24, height: 24)

                        Image(systemName: page.symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.white)
                    }

                    Text(page.title)
                        .font(.system(size: 13))

                    Spacer()
                }
                .tag(page)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 215, max: 240)
        } detail: {
            detailContent
                .navigationTitle(selectedPage?.title ?? "")
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 840, idealWidth: 920, maxWidth: 1100, minHeight: 560, idealHeight: 640, maxHeight: 850)
        .onAppear {
            store.saveInCoreData()
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
        .padding(.vertical, 20)
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
