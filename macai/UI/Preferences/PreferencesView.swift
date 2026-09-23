//
//  PreferencesView.swift
//  Chatmice / macai
//
//  Exact 3-pane macOS Settings interface matching Reference Image #1:
//  - Left: Clean category navigation (General, Appearance, Providers, Prompts, MCP, Extensions, Advanced)
//  - Middle: Provider list with search and +/- actions
//  - Right: Provider editor with Base URL, Wire API, API Key, and Models table
//

import AppKit
import Foundation
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case appearance = "Appearance"
    case providers = "Providers"
    case prompts = "Prompts"
    case mcp = "MCP"
    case extensions = "Extensions"
    case advanced = "Advanced"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .providers: return "cpu"
        case .prompts: return "text.bubble"
        case .mcp: return "hammer"
        case .extensions: return "puzzlepiece.extension"
        case .advanced: return "ellipsis.circle"
        }
    }
}

struct PreferencesView: View {
    @StateObject private var store = ChatStore(persistenceController: PersistenceController.shared)
    @State private var selectedTab: SettingsTab = .providers

    // Native macOS HIG semantic colors
    private let sidebarBackground = Color(NSColor.controlBackgroundColor)
    private let contentBackground = Color(NSColor.windowBackgroundColor)
    private let dividerColor = Color(NSColor.separatorColor)
    var body: some View {
        HStack(spacing: 0) {
            // Column 1: Leftmost Navigation Sidebar (width: 175)
            sidebarColumn
                .frame(width: 175)
                .background(sidebarBackground)

            Rectangle()
                .fill(dividerColor)
                .frame(width: 1)

            // Column 2 & 3: Main Content Area (Providers renders its own middle + right columns)
            contentArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 960, idealWidth: 1040, maxWidth: 1200, minHeight: 620, idealHeight: 700, maxHeight: 900)
        .background(contentBackground)
        .onAppear {
            store.saveInCoreData()
            if let window = NSApp.mainWindow {
                window.title = "Chatmice Settings"
                window.standardWindowButton(.zoomButton)?.isEnabled = true
            }
        }
    }

    // MARK: - Leftmost Navigation Sidebar

    private var sidebarColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header / Section title
            Text("Settings")
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 8)

            // Native sidebar items
            VStack(spacing: 2) {
                sidebarButton(.general)
                sidebarButton(.appearance)
                sidebarButton(.providers)
                sidebarButton(.prompts)
                sidebarButton(.mcp)
                sidebarButton(.extensions)
                sidebarButton(.advanced)
            }
            .padding(.horizontal, 8)

            Spacer()
        }
    }

    private func sidebarButton(_ tab: SettingsTab) -> some View {
        let isSelected = selectedTab == tab
        return Button(action: { selectedTab = tab }) {
            HStack(spacing: 10) {
                Image(systemName: tab.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                Text(tab.rawValue)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.85))

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Content Area

    @ViewBuilder
    private var contentArea: some View {
        switch selectedTab {
        case .providers:
            // Renders the Middle column + Right editor directly, filling 100% of height and width!
            TabAPIServicesView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .general:
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    headerView("General", icon: "gearshape", subtitle: "Configure app basics and global behavior.")
                    TabGeneralSettingsView()
                }
                .padding(24)
            }

        case .appearance:
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    headerView("Appearance", icon: "paintbrush", subtitle: "Customize themes, font sizes, and typography.")
                    TabGeneralSettingsView()
                }
                .padding(24)
            }

        case .prompts:
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    headerView("Prompts & Assistants", icon: "text.bubble", subtitle: "Manage system instructions and AI personas.")
                    TabAIPersonasView()
                }
                .padding(24)
            }

        case .mcp:
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    headerView("Model Context Protocol", icon: "hammer", subtitle: "Connect MCP servers via stdio or HTTP.")
                    TabMCPServersView()
                }
                .padding(24)
            }

        case .extensions:
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    headerView("Extensions & Skills", icon: "puzzlepiece.extension", subtitle: "Local skill discovery and safety controls.")
                    skillsSettingsView
                }
                .padding(24)
            }

        case .advanced:
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    headerView("Advanced", icon: "ellipsis.circle", subtitle: "Backup, restore, and application maintenance.")
                    BackupRestoreView(store: store)
                    Divider().padding(.vertical, 8)
                    DangerZoneView(store: store)
                }
                .padding(24)
            }
        }
    }

    private func headerView(_ title: String, icon: String, subtitle: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .bold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.bottom, 8)
    }

    // MARK: - Skills & Tools Section

    @AppStorage("chatmiceToolsEnabled") private var toolsEnabled = true
    @AppStorage("chatmiceBashEnabled") private var bashEnabled = true
    @AppStorage("chatmiceSkillsEnabled") private var skillsEnabled = true
    @AppStorage("chatmiceBashAutoConfirm") private var bashAutoConfirm = false
    @State private var detectedSkills: [SkillInfo] = []

    private var skillsSettingsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Agent Capabilities")
                    .font(.headline)

                Toggle("Enable Agent Tools (MCP, Bash, Skills)", isOn: $toolsEnabled)
                    .toggleStyle(.switch)

                if toolsEnabled {
                    Divider()

                    Toggle("Enable Local Bash Execution", isOn: $bashEnabled)
                        .toggleStyle(.switch)

                    Toggle("Auto-approve Bash Commands (Skip Confirmation Alert)", isOn: $bashAutoConfirm)
                        .toggleStyle(.switch)
                        .disabled(!bashEnabled)

                    Toggle("Enable Skills Discovery (SKILL.md)", isOn: $skillsEnabled)
                        .toggleStyle(.switch)
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(dividerColor.opacity(0.5), lineWidth: 1)
                    )
            )

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Detected Skills (\(detectedSkills.count))")
                        .font(.headline)
                    Spacer()
                    Button("Open in Finder") {
                        let fm = FileManager.default
                        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                        let dir = appSupport.appendingPathComponent("Chatmice/skills", isDirectory: true)
                        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dir.path)
                    }
                    .buttonStyle(.bordered)
                }

                if detectedSkills.isEmpty {
                    Text("No skills found. Place folder with SKILL.md in ~/Library/Application Support/Chatmice/skills/")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(detectedSkills) { s in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(Color.accentColor)
                                .font(.system(size: 16))
                                .padding(.top, 2)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.name)
                                    .font(.body.weight(.medium))
                                Text(s.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
                        Divider()
                    }
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(dividerColor.opacity(0.5), lineWidth: 1)
                    )
            )
        }
        .task {
            let store = SkillStore()
            self.detectedSkills = await store.skills()
        }
    }
}
