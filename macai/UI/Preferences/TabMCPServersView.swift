//
//  TabMCPServersView.swift
//  Chatmice / macai
//
//  Settings tab for managing Model Context Protocol (MCP) servers (stdio & HTTP/SSE).
//

import SwiftUI

struct TabMCPServersView: View {
    @AppStorage("mcpServersJSON") private var mcpServersJSON: String = "[]"
    @State private var servers: [MCPServerConfig] = []
    @State private var showingEditSheet = false
    @State private var editingServer: MCPServerConfig? = nil

    @State private var formKind: MCPServerConfig.Kind = .stdio
    @State private var formName = ""
    @State private var formCommand = "npx"
    @State private var formArgs = ""
    @State private var formURL = "http://localhost:8000/sse"
    @State private var formEnv = ""
    @State private var statuses: [MCPStatus] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Configured MCP Servers")
                    .font(.headline)
                Spacer()
                Button(action: openAddServer) {
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
                    Text("Add an MCP server (Local stdio via npx/node/uvx, or Remote HTTP/SSE) to give your assistant tool capabilities.")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
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
            Task {
                await MCPService.shared.sync(servers: servers)
                refreshStatus()
            }
        }
        .sheet(isPresented: $showingEditSheet) {
            serverFormSheet
        }
    }

    private func serverRow(_ server: MCPServerConfig) -> some View {
        let status = statuses.first(where: { $0.name == server.name })
        let isConnected = status?.connected ?? false
        let toolCount = status?.toolCount ?? 0
        let lastError = status?.lastError

        return HStack(spacing: 12) {
            Circle()
                .fill(isConnected ? Color.green : (server.enabled ? Color.orange : Color.gray))
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(server.name)
                        .font(.body.weight(.medium))

                    Text(server.kind == .stdio ? "stdio" : "http")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        .foregroundStyle(.secondary)

                    if isConnected {
                        Text("\(toolCount) tools")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.green.opacity(0.15)))
                            .foregroundStyle(.green)
                    }
                }

                if server.kind == .stdio {
                    Text("\(server.command ?? "") \(server.args.joined(separator: " "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(server.url ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let err = lastError, !isConnected && server.enabled {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                openEditServer(server)
            }

            Spacer()

            // Reconnect button
            Button(action: {
                Task {
                    await MCPService.shared.sync(servers: servers)
                    refreshStatus()
                }
            }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Reconnect / Refresh Server")
            .padding(.trailing, 2)

            // Edit button
            Button(action: {
                openEditServer(server)
            }) {
                Image(systemName: "pencil")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Edit Server Configuration")
            .padding(.trailing, 2)

            // Enable toggle
            Toggle("", isOn: Binding(
                get: { server.enabled },
                set: { val in
                    toggleServer(server, enabled: val)
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()

            // Delete button
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

    private var isSaveDisabled: Bool {
        if formName.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        if formKind == .stdio {
            return formCommand.trimmingCharacters(in: .whitespaces).isEmpty
        } else {
            return formURL.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private var serverFormSheet: some View {
        VStack(spacing: 16) {
            Text(editingServer == nil ? "Add MCP Server" : "Edit MCP Server")
                .font(.headline)

            Picker("Transport Type", selection: $formKind) {
                Text("Local (stdio)").tag(MCPServerConfig.Kind.stdio)
                Text("Remote (HTTP / SSE)").tag(MCPServerConfig.Kind.http)
            }
            .pickerStyle(.segmented)
            .padding(.bottom, 4)

            Form {
                TextField("Server Name:", text: $formName, prompt: Text(formKind == .stdio ? "e.g. filesystem" : "e.g. jira"))

                if formKind == .stdio {
                    TextField("Command:", text: $formCommand, prompt: Text("e.g. npx, node, uvx, python3"))
                    TextField("Arguments (space-separated):", text: $formArgs, prompt: Text("-y @modelcontextprotocol/server-..."))
                    TextField("Environment (KEY=VAL;...):", text: $formEnv, prompt: Text("API_KEY=xyz;DEBUG=1"))
                } else {
                    TextField("Server URL (SSE or HTTP):", text: $formURL, prompt: Text("http://127.0.0.1:7766/mcp/jira or http://.../sse"))
                    TextField("Headers / Auth (KEY=VAL;...):", text: $formEnv, prompt: Text("Authorization=Bearer xyz;X-Custom=abc"))
                }
            }

            HStack {
                Button("Cancel") {
                    showingEditSheet = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save") {
                    saveServerForm()
                    showingEditSheet = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaveDisabled)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 480)
    }

    private func openAddServer() {
        editingServer = nil
        formKind = .stdio
        formName = ""
        formCommand = "npx"
        formArgs = ""
        formURL = "http://127.0.0.1:7766/mcp/"
        formEnv = ""
        showingEditSheet = true
    }

    private func openEditServer(_ server: MCPServerConfig) {
        editingServer = server
        formKind = server.kind
        formName = server.name
        formCommand = server.command ?? "npx"
        formArgs = server.args.joined(separator: " ")
        formURL = server.url ?? ""
        formEnv = server.env.map { "\($0.key)=\($0.value)" }.joined(separator: ";")
        showingEditSheet = true
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

    private func saveServerForm() {
        var envMap: [String: String] = [:]
        for pair in formEnv.split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 {
                envMap[kv[0].trimmingCharacters(in: .whitespaces)] = kv[1].trimmingCharacters(in: .whitespaces)
            }
        }

        let name = formName.trimmingCharacters(in: .whitespaces)
        let config: MCPServerConfig
        if formKind == .stdio {
            let args = formArgs.split(separator: " ").map(String.init)
            config = MCPServerConfig(
                name: name,
                kind: .stdio,
                command: formCommand.trimmingCharacters(in: .whitespaces),
                args: args,
                env: envMap,
                enabled: editingServer?.enabled ?? true
            )
        } else {
            config = MCPServerConfig(
                name: name,
                kind: .http,
                env: envMap,
                url: formURL.trimmingCharacters(in: .whitespaces),
                enabled: editingServer?.enabled ?? true
            )
        }

        var updated = servers
        if let old = editingServer, old.name != config.name {
            updated.removeAll { $0.name == old.name }
            Task {
                await MCPService.shared.disconnect(name: old.name)
            }
        } else {
            updated.removeAll { $0.name == config.name }
        }
        updated.append(config)
        saveServers(updated)
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
