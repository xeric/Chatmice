//
//  PreferencesView.swift
//  Chatmice / macai
//
//  Native macOS System Settings navigation split view matching modern Apple HIG.
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

    var symbol: String {
        switch self {
        case .general: return "slider.horizontal.3"
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
            List(selection: $selectedPage) {
                ForEach(SettingsGroup.allCases, id: \.self) { group in
                    Section(group.rawValue) {
                        ForEach(group.pages) { page in
                            Label(page.title, systemImage: page.symbol)
                                .tag(page)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 190, max: 220)
        } detail: {
            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 760, idealWidth: 840, maxWidth: 1100, minHeight: 540, idealHeight: 620, maxHeight: 850)
        .onAppear {
            store.saveInCoreData()
            if let window = NSApp.mainWindow {
                window.title = "Settings"
                window.standardWindowButton(.zoomButton)?.isEnabled = true
            }
        }
    }

    // MARK: - Detail Views

    @ViewBuilder
    private var detailView: some View {
        switch selectedPage ?? .providers {
        case .general:
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    TabGeneralSettingsView()
                }
                .padding(20)
            }

        case .appearance:
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    TabGeneralSettingsView()
                }
                .padding(20)
            }

        case .providers:
            TabAPIServicesView()

        case .assistants:
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    TabAIPersonasView()
                }
                .padding(20)
            }

        case .mcp:
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    TabMCPServersView()
                }
                .padding(20)
            }

        case .skills:
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    TabSkillsView()
                }
                .padding(20)
            }

        case .backup:
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    BackupRestoreView(store: store)
                }
                .padding(20)
            }

        case .dangerZone:
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    DangerZoneView(store: store)
                }
                .padding(20)
            }
        }
    }
}
