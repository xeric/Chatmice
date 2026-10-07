//
// TabWebSearchSettingsView.swift
// Chatmice
//

import SwiftUI

struct TabWebSearchSettingsView: View {
    @State private var settings = WebSearchSettings.load()
    @State private var expandedProvider: WebSearchProviderID?
    @State private var apiKeys: [WebSearchProviderID: String] = [:]
    @State private var passwords: [WebSearchProviderID: String] = [:]
    @State private var status: [WebSearchProviderID: CheckStatus] = [:]

    private enum CheckStatus: Equatable {
        case checking
        case success
        case failure(String)
    }

    private var enabledSearchProviders: [WebSearchProviderID] {
        WebSearchProviderID.allCases.filter {
            $0.supportsSearch && settings.provider($0).enabled
        }
    }

    private var enabledFetchProviders: [WebSearchProviderID] {
        WebSearchProviderID.allCases.filter {
            $0.supportsFetch && settings.provider($0).enabled
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Web Search Tools") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Enable Web Search", isOn: binding(\.enabled))
                        .toggleStyle(.switch)
                    Text(
                        "Makes web_search and web_fetch available to AI assistants. Provider credentials are stored in Apple Keychain."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if settings.enabled {
                        Divider()
                        providerPicker(
                            title: "Search provider",
                            selection: binding(\.defaultSearchProvider),
                            providers: enabledSearchProviders
                        )
                        providerPicker(
                            title: "URL retrieval provider",
                            selection: binding(\.defaultFetchProvider),
                            providers: enabledFetchProviders
                        )
                        HStack {
                            Text("Maximum search results")
                            Spacer()
                            Stepper(value: binding(\.maxResults), in: 1...100) {
                                Text("\(settings.maxResults)")
                                    .monospacedDigit()
                                    .frame(width: 28, alignment: .trailing)
                            }
                            .fixedSize()
                        }
                    }
                }
                .padding(8)
            }

            GroupBox("Search & Retrieval Providers") {
                VStack(spacing: 0) {
                    Text("Enable providers here. Only enabled providers appear in the selectors above.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 10)

                    Divider()

                    ForEach(WebSearchProviderID.allCases) { provider in
                        providerRow(provider)
                        if provider != WebSearchProviderID.allCases.last { Divider() }
                    }
                }
                .padding(.horizontal, 8)
            }
        }
        .onAppear {
            loadSecrets()
            normalizeProviderSelections()
        }
    }

    private func providerPicker(
        title: String,
        selection: Binding<WebSearchProviderID>,
        providers: [WebSearchProviderID]
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            if providers.isEmpty {
                Text("No enabled providers")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            else {
                Picker(title, selection: selection) {
                    ForEach(providers) { provider in
                        Text(provider.name).tag(provider)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .frame(width: 190, alignment: .trailing)
            }
        }
    }

    @ViewBuilder
    private func providerRow(_ provider: WebSearchProviderID) -> some View {
        let config = settings.provider(provider)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: icon(for: provider))
                    .frame(width: 22)
                    .foregroundStyle(isActive(provider) ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(provider.name).fontWeight(.medium)
                        capabilityBadge(provider.supportsSearch ? "Search" : "MCP")
                        if provider.supportsFetch { capabilityBadge("Fetch") }
                        if isActive(provider) { capabilityBadge("Active") }
                    }
                    Text(provider.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if provider == .exaMCP {
                    Text("Managed in MCP Servers")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                else {
                    Toggle(
                        settings.provider(provider).enabled ? "Enabled" : "Disabled",
                        isOn: providerEnabledBinding(provider)
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .toggleStyle(.switch)
                    .fixedSize()
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        expandedProvider = expandedProvider == provider ? nil : provider
                    }
                } label: {
                    Image(systemName: expandedProvider == provider ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.plain)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 10)

            if expandedProvider == provider {
                providerEditor(provider, config: config)
                    .padding(.leading, 32)
                    .padding(.bottom, 12)
            }
        }
    }

    @ViewBuilder
    private func providerEditor(_ provider: WebSearchProviderID, config: WebSearchProviderConfig) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if provider == .exaMCP {
                Text(
                    "Add this endpoint as an HTTP MCP server under MCP Servers. Exa MCP tools will then appear automatically in assistant tool selection."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if provider != .fetch {
                formRow("API host") {
                    TextField(provider.defaultHost, text: providerHostBinding(provider))
                        .textFieldStyle(.roundedBorder)
                }
            }

            if provider.requiresAPIKey {
                formRow("API key") {
                    SecureField("Required", text: apiKeyBinding(provider))
                        .textFieldStyle(.roundedBorder)
                }
            }

            if provider == .searxng {
                formRow("Username") {
                    TextField("Optional", text: providerUsernameBinding(provider))
                        .textFieldStyle(.roundedBorder)
                }
                formRow("Password") {
                    SecureField("Optional", text: passwordBinding(provider))
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack {
                if provider != .exaMCP {
                    Button("Check Connection") { check(provider) }
                        .disabled(status[provider] == .checking || !config.enabled)
                }
                statusView(status[provider])
                Spacer()
                if provider.apiKeyURL != nil {
                    Link("Get API Key", destination: provider.apiKeyURL!)
                        .font(.caption)
                }
                if let website = provider.websiteURL {
                    Link("Website", destination: website)
                        .font(.caption)
                }
            }
        }
    }

    private func formRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).frame(width: 90, alignment: .leading)
            content()
        }
    }

    private func capabilityBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.12), in: Capsule())
    }

    @ViewBuilder
    private func statusView(_ value: CheckStatus?) -> some View {
        switch value {
        case .checking:
            ProgressView().controlSize(.small)
            Text("Checking…").font(.caption).foregroundStyle(.secondary)
        case .success:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .failure(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .font(.caption).foregroundStyle(.red).lineLimit(2)
        case nil:
            EmptyView()
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<WebSearchSettings, Value>) -> Binding<Value> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: {
                settings[keyPath: keyPath] = $0
                settings.save()
            }
        )
    }

    private func providerIndex(_ provider: WebSearchProviderID) -> Int {
        if let index = settings.providers.firstIndex(where: { $0.id == provider }) { return index }
        settings.providers.append(WebSearchProviderConfig(id: provider))
        return settings.providers.count - 1
    }

    private func providerEnabledBinding(_ provider: WebSearchProviderID) -> Binding<Bool> {
        Binding(
            get: { settings.provider(provider).enabled },
            set: { value in
                let index = providerIndex(provider)
                settings.providers[index].enabled = value
                normalizeProviderSelections()
                status[provider] = nil
            }
        )
    }

    private func providerHostBinding(_ provider: WebSearchProviderID) -> Binding<String> {
        Binding(
            get: { settings.provider(provider).apiHost },
            set: { value in
                let index = providerIndex(provider)
                settings.providers[index].apiHost = value
                settings.save()
                status[provider] = nil
            }
        )
    }

    private func providerUsernameBinding(_ provider: WebSearchProviderID) -> Binding<String> {
        Binding(
            get: { settings.provider(provider).username },
            set: { value in
                let index = providerIndex(provider)
                settings.providers[index].username = value
                settings.save()
                status[provider] = nil
            }
        )
    }

    private func apiKeyBinding(_ provider: WebSearchProviderID) -> Binding<String> {
        Binding(
            get: { apiKeys[provider, default: ""] },
            set: { value in
                apiKeys[provider] = value
                status[provider] = nil
                try? WebSearchSettings.setAPIKey(value, for: provider)
            }
        )
    }

    private func passwordBinding(_ provider: WebSearchProviderID) -> Binding<String> {
        Binding(
            get: { passwords[provider, default: ""] },
            set: { value in
                passwords[provider] = value
                status[provider] = nil
                try? WebSearchSettings.setPassword(value, for: provider)
            }
        )
    }

    private func loadSecrets() {
        for provider in WebSearchProviderID.allCases {
            apiKeys[provider] = WebSearchSettings.apiKey(for: provider)
            passwords[provider] = WebSearchSettings.password(for: provider)
        }
    }

    private func check(_ provider: WebSearchProviderID) {
        status[provider] = .checking
        let config = settings.provider(provider)
        Task {
            do {
                try await WebSearchClient().check(provider: provider, config: config)
                await MainActor.run { status[provider] = .success }
            }
            catch {
                let message = error.localizedDescription
                await MainActor.run { status[provider] = .failure(message) }
            }
        }
    }

    private func normalizeProviderSelections() {
        let searchProviders = enabledSearchProviders
        if !searchProviders.contains(settings.defaultSearchProvider),
            let fallback = searchProviders.first
        {
            settings.defaultSearchProvider = fallback
        }

        let fetchProviders = enabledFetchProviders
        if !fetchProviders.contains(settings.defaultFetchProvider),
            let fallback = fetchProviders.first
        {
            settings.defaultFetchProvider = fallback
        }

        settings.save()
    }

    private func isActive(_ provider: WebSearchProviderID) -> Bool {
        settings.enabled && settings.provider(provider).enabled
            && (provider == settings.defaultSearchProvider || provider == settings.defaultFetchProvider)
    }

    private func icon(for provider: WebSearchProviderID) -> String {
        switch provider {
        case .searxng: return "server.rack"
        case .fetch: return "doc.text.magnifyingglass"
        case .exaMCP: return "network"
        case .jina, .firecrawl: return "doc.richtext"
        default: return "globe"
        }
    }
}

extension WebSearchProviderID {
    fileprivate var websiteURL: URL? {
        let value: String
        switch self {
        case .zhipu: value = "https://bigmodel.cn"
        case .tavily: value = "https://tavily.com"
        case .searxng: value = "https://docs.searxng.org"
        case .exa, .exaMCP: value = "https://exa.ai"
        case .bocha: value = "https://bochaai.com"
        case .querit: value = "https://querit.ai"
        case .fetch: value = "https://developer.mozilla.org/en-US/docs/Web/HTTP"
        case .jina: value = "https://jina.ai"
        case .firecrawl: value = "https://firecrawl.dev"
        case .parallel: value = "https://parallel.ai"
        case .serply: value = "https://serply.io"
        }
        return URL(string: value)
    }

    fileprivate var apiKeyURL: URL? {
        guard requiresAPIKey else { return nil }
        let value: String
        switch self {
        case .zhipu: value = "https://bigmodel.cn/usercenter/proj-mgmt/apikeys"
        case .tavily: value = "https://app.tavily.com/home"
        case .exa: value = "https://dashboard.exa.ai/api-keys"
        case .bocha: value = "https://open.bochaai.com"
        case .querit: value = "https://querit.ai"
        case .jina: value = "https://jina.ai/api-dashboard"
        case .firecrawl: value = "https://www.firecrawl.dev/app/api-keys"
        case .parallel: value = "https://platform.parallel.ai"
        case .serply: value = "https://serply.io/dashboard"
        default: return nil
        }
        return URL(string: value)
    }
}
