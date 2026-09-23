//
//  TabSkillsView.swift
//  Chatmice / macai
//
//  Settings tab for managing Agent Skills and Capabilities.
//

import AppKit
import SwiftUI

struct TabSkillsView: View {
    @AppStorage("chatmiceToolsEnabled") private var toolsEnabled = true
    @AppStorage("chatmiceBashEnabled") private var bashEnabled = true
    @AppStorage("chatmiceSkillsEnabled") private var skillsEnabled = true
    @AppStorage("chatmiceBashApprovalMode") private var bashApprovalMode = BashApprovalMode.alwaysAsk
    @State private var detectedSkills: [SkillInfo] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Agent Capabilities") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Enable Agent Tools (MCP, Bash, Skills)", isOn: $toolsEnabled)
                        .toggleStyle(.switch)

                    if toolsEnabled {
                        Divider()

                        Toggle("Enable Local Bash Execution", isOn: $bashEnabled)
                            .toggleStyle(.switch)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Bash Approval")
                                .font(.subheadline.weight(.medium))

                            Picker("Bash Approval", selection: $bashApprovalMode) {
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

                        Toggle("Enable Skills Discovery (SKILL.md)", isOn: $skillsEnabled)
                            .toggleStyle(.switch)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

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
                        Text("No skills found. Place a folder containing SKILL.md in ~/Library/Application Support/Chatmice/skills/")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    } else {
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
