//
//  PreferencesView.swift
//  Chatmice / macai
//
//  Native macOS System Settings (2-column layout matching Apple HIG).
//

import AppKit
import Foundation
import SwiftUI

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general = "General"
    case appearance = "Appearance"
    case providers = "Providers"
    case assistants = "AI Assistants"
    case mcp = "MCP Servers"
    case skills = "Skills & Tools"
    case advanced = "Advanced"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: return "gearshape.fill"
        case .appearance: return "paintpalette.fill"
        case .providers: return "cpu.fill"
        case .assistants: return "person.2.fill"
        case .mcp: return "hammer.fill"
        case .skills: return "puzzlepiece.extension.fill"
        case .advanced: return "ellipsis.circle.fill"
        }
    }

    var badgeColor: Color {
        switch self {
        case .general: return .gray
        case .appearance: return .blue
        case .providers: return .indigo
        case .assistants: return .purple
        case .mcp: return .teal
        case .skills: return .orange
        case .advanced: return .secondary
        }
    }
}

struct SettingsBadgeIcon: View {
    let icon: String
    let color: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(color.gradient)
                .frame(width: 24, height: 24)

            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}

struct PreferencesView: View {
    @StateObject private var store = ChatStore(persistenceController: PersistenceController.shared)
    @State private var selectedCategory: SettingsCategory? = .providers

    var body: some View {
        HStack(spacing: 0) {
            // Left Column: Native macOS System Settings Sidebar
            sidebarView
                .frame(width: 220)
                .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Right Column: Native Detail Panel
            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(minWidth: 800, idealWidth: 880, maxWidth: 1100, minHeight: 560, idealHeight: 640, maxHeight: 850)
        .onAppear {
            store.saveInCoreData()
            if let window = NSApp.mainWindow {
                window.title = "Settings"
                window.standardWindowButton(.zoomButton)?.isEnabled = true
            }
        }
    }

    // MARK: - Left Sidebar

    private var sidebarView: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(SettingsCategory.allCases, selection: $selectedCategory) { category in
                NavigationLink(value: category) {
                    HStack(spacing: 10) {
                        SettingsBadgeIcon(icon: category.icon, color: category.badgeColor)

                        Text(category.rawValue)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.primary)
                    }
                    .padding(.vertical, 3)
                }
                .tag(category)
            }
            .listStyle(.sidebar)
        }
    }

    // MARK: - Right Detail Panel

    @ViewBuilder
    private var detailView: some View {
        switch selectedCategory ?? .general {
        case .general:
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    detailHeader(title: "General", subtitle: "Configure app startup, notifications, and general preferences.")
                    TabGeneralSettingsView()
                }
                .padding(24)
            }

        case .appearance:
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    detailHeader(title: "Appearance", subtitle: "Customize application theme, font sizes, and typography.")
                    TabGeneralSettingsView()
                }
                .padding(24)
            }

        case .providers:
            TabAPIServicesView()

        case .assistants:
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    detailHeader(title: "AI Assistants", subtitle: "Manage system instructions, avatars, and AI personas.")
                    TabAIPersonasView()
                }
                .padding(24)
            }

        case .mcp:
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    detailHeader(title: "Model Context Protocol", subtitle: "Configure external tool servers for assistant integration.")
                    TabMCPServersView()
                }
                .padding(24)
            }

        case .skills:
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    detailHeader(title: "Skills & Tools", subtitle: "Configure local skills discovery and bash execution capabilities.")
                    TabSkillsView()
                }
                .padding(24)
            }

        case .advanced:
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    detailHeader(title: "Advanced", subtitle: "Backup, restore CoreData stores, and maintenance actions.")
                    BackupRestoreView(store: store)
                    Divider().padding(.vertical, 8)
                    DangerZoneView(store: store)
                }
                .padding(24)
            }
        }
    }

    private func detailHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.title2.bold())
                .foregroundStyle(Color.primary)

            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
        }
        .padding(.bottom, 6)
    }
}
