//
//  TabSkillsView.swift
//  Chatmice
//
//  Settings tab for managing Agent Skills and Capabilities.
//

import AppKit
import SwiftUI

struct TabSkillsView: View {
    @AppStorage("chatmiceToolsEnabled") private var toolsEnabled = true
    @AppStorage("chatmiceFileToolsEnabled") private var fileToolsEnabled = true
    @AppStorage("chatmiceBashEnabled") private var bashEnabled = true
    @AppStorage("chatmiceSkillsEnabled") private var skillsEnabled = true
    @AppStorage("chatmiceComputerEnabled") private var computerEnabled = false
    @AppStorage("chatmiceBashApprovalMode") private var bashApprovalMode = BashApprovalMode.alwaysAsk
    @State private var detectedSkills: [SkillInfo] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Agent Tools") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Enable Agent Tools", isOn: $toolsEnabled)
                        .toggleStyle(.switch)
                    Text("Allows the assistant to call enabled tools while answering. Turn this off to run every chat as model-only conversation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("File Tool") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Enable File Tool", isOn: $fileToolsEnabled)
                        .toggleStyle(.switch)
                    Text("Lets the agent inspect files and folders you select, including reading file contents and listing directory entries.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(!toolsEnabled)

            GroupBox("Code Execution") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Enable Bash and Sandboxed Python", isOn: $bashEnabled)
                        .toggleStyle(.switch)
                    Text("Runs shell commands and isolated Python code for calculations, repository inspection, builds, and command-line tasks.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Execution Approval")
                            .font(.subheadline.weight(.medium))
                        Picker("Execution Approval", selection: $bashApprovalMode) {
                            ForEach(BashApprovalMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        Text(bashApprovalMode.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .disabled(!bashEnabled)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(!toolsEnabled)

            GroupBox("Skills Discovery") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Enable SKILL.md Discovery", isOn: $skillsEnabled)
                        .toggleStyle(.switch)
                    Text("Finds local SKILL.md instructions and exposes them to the agent as reusable task-specific workflows.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(!toolsEnabled)

            GroupBox("Computer Use") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Enable Screen, Mouse, and Keyboard Control", isOn: $computerEnabled)
                        .toggleStyle(.switch)
                    Text("Lets the agent capture the screen and operate apps with mouse and keyboard events. macOS may request Screen Recording and Accessibility permissions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(!toolsEnabled)

            DefaultToolListSettingsView(
                fileToolsEnabled: fileToolsEnabled,
                bashEnabled: bashEnabled,
                skillsEnabled: skillsEnabled,
                computerEnabled: computerEnabled
            )

            GroupBox("Detected Skills (\(detectedSkills.count))") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Local skills discovered in application support:")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer()

                        Button("Open in Finder") {
                            let fm = FileManager.default
                            let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                            let dir = appSupport.appendingPathComponent("Chatmice/skills", isDirectory: true)
                            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dir.path)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Divider()

                    if detectedSkills.isEmpty {
                        Text(
                            "No skills found. Place a folder containing SKILL.md in ~/Library/Application Support/Chatmice/skills/"
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                    }
                    else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(detectedSkills) { s in
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: "folder.fill")
                                            .foregroundStyle(Color.accentColor)
                                            .font(.system(size: 14))
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
                                    .padding(.vertical, 2)
                                    Divider()
                                }
                            }
                        }
                        .frame(maxHeight: 180)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minHeight: 340)
        .task {
            let store = SkillStore()
            self.detectedSkills = await store.skills()
        }
    }
}

private struct DefaultToolListSettingsView: View {
    let fileToolsEnabled: Bool
    let bashEnabled: Bool
    let skillsEnabled: Bool
    let computerEnabled: Bool

    @AppStorage("mcpServersJSON") private var mcpServersJSON = "[]"
    @State private var sources: [ToolSourceDescriptor] = []
    @State private var revision = 0

    var body: some View {
        GroupBox("Default Tool List") {
            VStack(alignment: .leading, spacing: 10) {
                Text("New chats inherit this list. Individual chats can override it from the input toolbar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                if sources.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: 56)
                }
                else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(sources) { source in
                                Toggle(isOn: sourceBinding(source)) {
                                    HStack(spacing: 8) {
                                        Image(systemName: source.kind.systemImage)
                                            .frame(width: 16)
                                            .foregroundStyle(source.isAvailable ? Color.accentColor : .secondary)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(source.name)
                                                .font(.system(size: 12, weight: .medium))
                                            Text(source.detail)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                    }
                                }
                                .toggleStyle(.checkbox)
                                .controlSize(.small)
                                .disabled(!source.isAvailable)
                                .padding(.vertical, 3)
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await loadSources() }
        .onChange(of: mcpServersJSON) { _, _ in reloadSources() }
        .onChange(of: fileToolsEnabled) { _, _ in reloadSources() }
        .onChange(of: bashEnabled) { _, _ in reloadSources() }
        .onChange(of: skillsEnabled) { _, _ in reloadSources() }
        .onChange(of: computerEnabled) { _, _ in reloadSources() }
    }

    private func sourceBinding(_ source: ToolSourceDescriptor) -> Binding<Bool> {
        Binding(
            get: {
                _ = revision
                return source.isAvailable
                    && !ToolSelectionStore.disabledSourceIDs(for: nil).contains(source.id)
            },
            set: { enabled in
                ToolSelectionStore.setSourceEnabled(enabled, sourceID: source.id, for: nil)
                revision += 1
            }
        )
    }

    private func reloadSources() {
        Task { await loadSources() }
    }

    @MainActor
    private func loadSources() async {
        sources = await ToolSourceCatalog.load(
            fileToolsEnabled: fileToolsEnabled,
            bashEnabled: bashEnabled,
            skillsEnabled: skillsEnabled,
            computerEnabled: computerEnabled
        )
    }
}
