//
//  TabMCPServersView.swift
//  Chatmice
//
//  Settings tab for managing Model Context Protocol (MCP) servers (stdio & HTTP/SSE).
//

import SwiftUI

enum MCPFormMode: String, CaseIterable, Identifiable {
    case form = "Visual Form"
    case json = "Raw JSON"

    var id: String { rawValue }
}

private struct MCPToolInspector: Identifiable {
    let serverName: String
    let tools: [MCPToolSummary]

    var id: String { serverName }
}

struct TabMCPServersView: View {
    @AppStorage("mcpServersJSON") private var mcpServersJSON: String = "[]"
    @State private var servers: [MCPServerConfig] = []
    @State private var showingEditSheet = false
    @State private var editingServer: MCPServerConfig? = nil
    @State private var toolInspector: MCPToolInspector?
    @State private var reconnectingServerNames: Set<String> = []

    @State private var formMode: MCPFormMode = .form
    @State private var formKind: MCPServerConfig.Kind = .stdio
    @State private var formName = ""
    @State private var formCommand = "npx"
    @State private var formURL = "http://localhost:8000/sse"
    @State private var formEnv = ""
    @State private var rawJSON = ""
    @State private var jsonError: String? = nil
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
                    Text("Add an MCP server (Local stdio command or Remote HTTP/SSE endpoint) to give your assistant tool capabilities.")
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
        .sheet(item: $toolInspector) { inspector in
            toolInspectorSheet(inspector)
        }
    }

    private func serverRow(_ server: MCPServerConfig) -> some View {
        let status = statuses.first(where: { $0.name == server.name })
        let isConnected = status?.connected ?? false
        let toolCount = status?.toolCount ?? 0
        let lastError = status?.lastError

        let commandDisplay: String = {
            if server.kind == .stdio {
                let full = ([server.command ?? ""] + server.args).filter { !$0.isEmpty }.joined(separator: " ")
                return full
            } else {
                return server.url ?? ""
            }
        }()

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

                Text(commandDisplay)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

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

            Button(action: {
                showTools(for: server)
            }) {
                Image(systemName: "eye")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(isConnected ? "View Available Tools" : "Connect the server to view its tools")
            .disabled(!isConnected)
            .padding(.trailing, 2)

            // Reconnect button
            Button(action: {
                reconnect(server)
            }) {
                if reconnectingServerNames.contains(server.name) {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 11, height: 11)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .help("Reconnect / Refresh Server")
            .padding(.trailing, 2)
            .disabled(!server.enabled || reconnectingServerNames.contains(server.name))

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

    private func toolInspectorSheet(_ inspector: MCPToolInspector) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(inspector.serverName)
                        .font(.headline)
                    Text("\(inspector.tools.count) available tools")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Done") {
                    toolInspector = nil
                }
                .keyboardShortcut(.cancelAction)
            }

            Divider()

            if inspector.tools.isEmpty {
                ContentUnavailableView(
                    "No Tools Available",
                    systemImage: "wrench.and.screwdriver",
                    description: Text("This server did not advertise any tools.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(inspector.tools) { tool in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(tool.name)
                                    .font(.system(.body, design: .monospaced, weight: .semibold))
                                    .textSelection(.enabled)

                                if !tool.description.isEmpty {
                                    Text(tool.description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 10)

                            if tool.id != inspector.tools.last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 560, height: 500)
    }

    private func showTools(for server: MCPServerConfig) {
        Task {
            let tools = await MCPService.shared.tools(forServer: server.name)
            await MainActor.run {
                toolInspector = MCPToolInspector(serverName: server.name, tools: tools)
            }
        }
    }

    private var isSaveDisabled: Bool {
        if formMode == .json {
            return rawJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || jsonError != nil
        }
        if formName.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        if formKind == .stdio {
            return formCommand.trimmingCharacters(in: .whitespaces).isEmpty
        } else {
            return formURL.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private var serverFormSheet: some View {
        VStack(spacing: 16) {
            HStack {
                Text(editingServer == nil ? "Add MCP Server" : "Edit MCP Server")
                    .font(.headline)
                Spacer()
                Picker("", selection: $formMode) {
                    ForEach(MCPFormMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                .onChange(of: formMode) { _, newMode in
                    if newMode == .json {
                        syncFormToJSON()
                    } else {
                        syncJSONToForm()
                    }
                }
            }

            if formMode == .form {
                visualFormView
            } else {
                rawJSONView
            }

            if let err = jsonError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("Cancel") {
                    showingEditSheet = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save") {
                    if saveServerForm() {
                        showingEditSheet = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaveDisabled)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 520)
    }

    private var visualFormView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Transport Type", selection: $formKind) {
                Text("Local (stdio)").tag(MCPServerConfig.Kind.stdio)
                Text("Remote (HTTP / SSE)").tag(MCPServerConfig.Kind.http)
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 4) {
                Text("Server Name:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Server Name", text: $formName, prompt: Text(formKind == .stdio ? "e.g. filesystem" : "e.g. jira"))
                    .textFieldStyle(.roundedBorder)
            }

            if formKind == .stdio {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Command (executable + arguments):")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Full Command", text: $formCommand, prompt: Text("e.g. volta run --node 20 npx -y aha-mcp@latest"))
                        .textFieldStyle(.roundedBorder)
                    Text("Enter the complete command line as you would run it in the terminal.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Environment Variables (KEY=VALUE per line):")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $formEnv)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 80)
                        .padding(4)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(6)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                    Text("One variable per line: e.g. AHA_API_TOKEN=xyz\\nAHA_DOMAIN=company.aha.io")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Server URL (SSE or HTTP):")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Server URL", text: $formURL, prompt: Text("http://127.0.0.1:7766/mcp/jira or http://.../sse"))
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Custom Headers / Auth (KEY=VALUE per line):")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $formEnv)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 80)
                        .padding(4)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(6)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                    Text("One header per line: e.g. Authorization=Bearer token\\nX-Custom=value")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var rawJSONView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Paste MCP configuration JSON (supports Claude Desktop format):")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $rawJSON)
                .font(.system(.body, design: .monospaced))
                .frame(height: 220)
                .padding(4)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                .onChange(of: rawJSON) {
                    validateJSON()
                }

            Text("Example: {\"name\": \"aha\", \"command\": \"volta run ...\", \"env\": {\"AHA_API_TOKEN\": \"...\"}}")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func syncFormToJSON() {
        var envObj: [String: String] = [:]
        for line in formEnv.components(separatedBy: CharacterSet.newlines.union(CharacterSet(charactersIn: ";"))) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let kv = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 {
                envObj[kv[0].trimmingCharacters(in: .whitespaces)] = kv[1].trimmingCharacters(in: .whitespaces)
            }
        }

        var dict: [String: Any] = [
            "name": formName
        ]
        if formKind == .stdio {
            dict["command"] = formCommand
            if !envObj.isEmpty { dict["env"] = envObj }
        } else {
            dict["url"] = formURL
            if !envObj.isEmpty { dict["headers"] = envObj }
        }

        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            rawJSON = str
        }
        jsonError = nil
    }

    private func syncJSONToForm() {
        guard let data = rawJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        // Check if wrapped in mcpServers dictionary
        var targetObj = obj
        if let mcpServers = obj["mcpServers"] as? [String: Any], let first = mcpServers.first {
            formName = first.key
            targetObj = (first.value as? [String: Any]) ?? [:]
        } else if let name = obj["name"] as? String, !name.isEmpty {
            formName = name
        }

        if let url = targetObj["url"] as? String, !url.isEmpty {
            formKind = .http
            formURL = url
            if let headers = (targetObj["headers"] as? [String: String]) ?? (targetObj["env"] as? [String: String]) {
                formEnv = headers.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
            }
        } else {
            formKind = .stdio
            var cmd = targetObj["command"] as? String ?? ""
            if let args = targetObj["args"] as? [String], !args.isEmpty {
                cmd = ([cmd] + args).joined(separator: " ")
            }
            formCommand = cmd
            if let env = targetObj["env"] as? [String: String] {
                formEnv = env.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
            }
        }
        jsonError = nil
    }

    private func validateJSON() {
        let trimmed = rawJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            jsonError = nil
            return
        }
        do {
            _ = try JSONSerialization.jsonObject(with: Data(trimmed.utf8))
            jsonError = nil
        } catch {
            jsonError = "JSON Syntax Error: \(error.localizedDescription)"
        }
    }

    private func openAddServer() {
        editingServer = nil
        formMode = .form
        formKind = .stdio
        formName = ""
        formCommand = ""
        formURL = "http://localhost:8000/sse"
        formEnv = ""
        rawJSON = ""
        jsonError = nil
        showingEditSheet = true
    }

    private func openEditServer(_ server: MCPServerConfig) {
        editingServer = server
        formMode = .form
        formKind = server.kind
        formName = server.name
        formCommand = ([server.command ?? ""] + server.args).filter { !$0.isEmpty }.joined(separator: " ")
        formURL = server.url ?? ""
        formEnv = server.env.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n")
        rawJSON = ""
        jsonError = nil
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

    private func saveServerForm() -> Bool {
        if formMode == .json {
            return saveFromRawJSON()
        }

        var envMap: [String: String] = [:]
        for line in formEnv.components(separatedBy: CharacterSet.newlines.union(CharacterSet(charactersIn: ";"))) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let kv = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 {
                envMap[kv[0].trimmingCharacters(in: .whitespaces)] = kv[1].trimmingCharacters(in: .whitespaces)
            }
        }

        let name = formName.trimmingCharacters(in: .whitespaces)
        let config: MCPServerConfig
        if formKind == .stdio {
            config = MCPServerConfig(
                name: name,
                kind: .stdio,
                command: formCommand.trimmingCharacters(in: .whitespaces),
                args: [],
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
        return true
    }

    private func saveFromRawJSON() -> Bool {
        guard let data = rawJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            jsonError = "Invalid JSON"
            return false
        }

        var newConfigs: [MCPServerConfig] = []

        // Format 1: {"mcpServers": { "name": { "command": "...", "args": [...], "env": {...} } }}
        if let mcpServers = obj["mcpServers"] as? [String: Any] {
            for (name, val) in mcpServers {
                if let serverDict = val as? [String: Any] {
                    if let cfg = parseServerDict(name: name, dict: serverDict) {
                        newConfigs.append(cfg)
                    }
                }
            }
        }
        // Format 2: Single server dict: {"name": "...", "command": "...", "env": {...}}
        else if let name = obj["name"] as? String, !name.isEmpty {
            if let cfg = parseServerDict(name: name, dict: obj) {
                newConfigs.append(cfg)
            }
        } else {
            jsonError = "Missing server name or 'mcpServers' object"
            return false
        }

        guard !newConfigs.isEmpty else {
            jsonError = "No valid server configuration found"
            return false
        }

        var updated = servers
        for cfg in newConfigs {
            updated.removeAll { $0.name == cfg.name }
            updated.append(cfg)
        }
        saveServers(updated)
        return true
    }

    private func parseServerDict(name: String, dict: [String: Any]) -> MCPServerConfig? {
        if let url = dict["url"] as? String, !url.isEmpty {
            let env = (dict["headers"] as? [String: String]) ?? (dict["env"] as? [String: String]) ?? [:]
            return MCPServerConfig(name: name, kind: .http, env: env, url: url, enabled: true)
        } else if let cmd = dict["command"] as? String, !cmd.isEmpty {
            let args = dict["args"] as? [String] ?? []
            let env = dict["env"] as? [String: String] ?? [:]
            return MCPServerConfig(name: name, kind: .stdio, command: cmd, args: args, env: env, enabled: true)
        }
        return nil
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

    private func reconnect(_ server: MCPServerConfig) {
        reconnectingServerNames.insert(server.name)
        Task {
            await MCPService.shared.reconnect(server)
            let updatedStatuses = await MCPService.shared.statuses()
            await MainActor.run {
                statuses = updatedStatuses
                reconnectingServerNames.remove(server.name)
            }
        }
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
