//
//  TabMCPServersView.swift
//  Chatmice / macai
//
//  Settings tab for managing Model Context Protocol (MCP) servers.
//

import SwiftUI

struct TabMCPServersView: View {
    @AppStorage("mcpServersJSON") private var mcpServersJSON: String = "[]"
    @State private var servers: [MCPServerConfig] = []
    @State private var showingAddSheet = false
    @State private var newServerName = ""
    @State private var newServerCommand = "node"
    @State private var newServerArgs = ""
    @State private var newServerEnv = ""
    @State private var statuses: [MCPStatus] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Configured MCP Servers")
                    .font(.headline)
                Spacer()
                Button(action: { showingAddSheet = true }) {
                    Label("Add Server", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }

            if servers.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "powerplug")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("No MCP servers configured")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Add an MCP server (e.g. SQLite, Git, Filesystem via npx or node) to give your assistant tool capabilities.")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(NSColor.controlBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color(NSColor.separatorColor).opacity(0.3), lineWidth: 1)
                        )
                )
            } else {
                VStack(spacing: 8) {
                    ForEach(servers) { server in
                        serverRow(server)
                    }
                }
            }
        }
        .onAppear {
            loadServers()
            refreshStatus()
        }
        .sheet(isPresented: $showingAddSheet) {
            addServerSheet
        }
    }

    private func serverRow(_ server: MCPServerConfig) -> some View {
        let status = statuses.first(where: { $0.name == server.name })
        let isConnected = status?.connected ?? false
        let toolCount = status?.toolCount ?? 0

        return HStack(spacing: 12) {
            Circle()
                .fill(isConnected ? Color.green : (server.enabled ? Color.orange : Color.gray))
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(server.name)
                        .font(.body.weight(.medium))
                    if isConnected {
                        Text("\(toolCount) tools")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.green.opacity(0.15)))
                            .foregroundStyle(.green)
                    }
                }

                Text("\(server.command ?? "") \(server.args.joined(separator: " "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { server.enabled },
                set: { val in
                    toggleServer(server, enabled: val)
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()

            Button(role: .destructive, action: { deleteServer(server) }) {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .padding(.leading, 4)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color(NSColor.separatorColor).opacity(0.3), lineWidth: 1)
                )
        )
    }

    private var addServerSheet: some View {
        VStack(spacing: 16) {
            Text("Add MCP Stdio Server")
                .font(.headline)

            Form {
                TextField("Server Name:", text: $newServerName, prompt: Text("e.g. filesystem"))
                TextField("Command:", text: $newServerCommand, prompt: Text("node or npx"))
                TextField("Arguments (space-separated):", text: $newServerArgs, prompt: Text("-y @modelcontextprotocol/server-..."))
                TextField("Environment (KEY=VAL;...):", text: $newServerEnv, prompt: Text("API_KEY=xyz"))
            }

            HStack {
                Button("Cancel") {
                    showingAddSheet = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save") {
                    addServer()
                    showingAddSheet = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(newServerName.trimmingCharacters(in: .whitespaces).isEmpty || newServerCommand.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 440)
    }

    private func loadServers() {
        if let data = mcpServersJSON.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([MCPServerConfig].self, from: data) {
            self.servers = decoded
        }
    }

    private func saveServers(_ list: [MCPServerConfig]) {
        self.servers = list
        if let data = try? JSONEncoder().encode(list),
           let str = String(data: data, encoding: .utf8) {
            self.mcpServersJSON = str
        }
        Task {
            await MCPService.shared.sync(servers: list)
            refreshStatus()
        }
    }

    private func addServer() {
        let args = newServerArgs.split(separator: " ").map(String.init)
        var envMap: [String: String] = [:]
        for pair in newServerEnv.split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 {
                envMap[kv[0].trimmingCharacters(in: .whitespaces)] = kv[1].trimmingCharacters(in: .whitespaces)
            }
        }
        let config = MCPServerConfig(
            name: newServerName.trimmingCharacters(in: .whitespaces),
            kind: .stdio,
            command: newServerCommand.trimmingCharacters(in: .whitespaces),
            args: args,
            env: envMap,
            enabled: true
        )
        var updated = servers
        updated.removeAll { $0.name == config.name }
        updated.append(config)
        saveServers(updated)
        newServerName = ""
        newServerArgs = ""
        newServerEnv = ""
    }

    private func toggleServer(_ server: MCPServerConfig, enabled: Bool) {
        var updated = servers
        if let idx = updated.firstIndex(where: { $0.id == server.id }) {
            updated[idx].enabled = enabled
            saveServers(updated)
        }
    }

    private func deleteServer(_ server: MCPServerConfig) {
        var updated = servers
        updated.removeAll { $0.id == server.id }
        saveServers(updated)
    }

    private func refreshStatus() {
        Task {
            let st = await MCPService.shared.statuses()
            await MainActor.run {
                self.statuses = st
            }
        }
    }
}
