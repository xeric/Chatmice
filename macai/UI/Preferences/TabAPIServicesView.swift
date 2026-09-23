//
//  TabAPIServicesView.swift
//  Chatmice / macai
//
//  Pixel-accurate implementation of modern AI Provider Settings (Reference Image #1):
//  - Middle Column: Search bar, rich provider list with brand icons, +/- bottom bar.
//  - Right Column: Title & Subtitle, Inset Provider Name, Inset API Base URL,
//    Wire API Dropdown, API Key with Eye Reveal, Models Management Table with
//    Nick name / Model ID inset fields, gear and trash actions, and instant auto-save.
//

import AppKit
import CoreData
import SwiftUI

struct ServiceModelRow: Identifiable, Codable, Equatable {
    var id: String
    var nickname: String
    var modelID: String

    init(id: String = UUID().uuidString, nickname: String = "", modelID: String) {
        self.id = id
        self.nickname = nickname
        self.modelID = modelID
    }
}

// Preset Provider template used for populating the rich provider list
struct ProviderPresetItem: Identifiable {
    var id: String { name }
    let name: String
    let type: String
    let defaultURL: String
    let defaultModel: String
    let subtitle: String
    let models: [ServiceModelRow]
}

struct TabAPIServicesView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \APIServiceEntity.name, ascending: true)],
        animation: .default
    )
    private var apiServices: FetchedResults<APIServiceEntity>

    @State private var selectedServiceID: NSManagedObjectID?
    @State private var searchText = ""
    @State private var isShowingAPIKey = false

    // Form fields
    @State private var nameText = ""
    @State private var urlText = ""
    @State private var typeText = "chatgpt"
    @State private var apiKeyText = ""
    @State private var modelsList: [ServiceModelRow] = []
    @State private var activeModelID = ""
    @State private var isFetchingModels = false
    @State private var fetchError: String?
    @State private var showingModelSelectionSheet = false
    @State private var fetchedCandidateModels: [AIModel] = []
    @State private var selectedModelIDsForImport: Set<String> = []
    @State private var modelSearchQuery = ""

    // macOS Native HIG semantic colors
    private let paneBackground = Color(NSColor.windowBackgroundColor)
    private let listBackground = Color(NSColor.controlBackgroundColor)
    private let dividerColor = Color(NSColor.separatorColor)
    private let fieldBackground = Color(NSColor.controlBackgroundColor)
    private let fieldBorder = Color(NSColor.separatorColor)
    private let selectedRowBackground = Color.accentColor.opacity(0.18)
    private var filteredServices: [APIServiceEntity] {
        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            return Array(apiServices)
        } else {
            return apiServices.filter {
                ($0.name ?? "").localizedCaseInsensitiveContains(searchText) ||
                ($0.type ?? "").localizedCaseInsensitiveContains(searchText)
            }
        }
    }

    private var selectedService: APIServiceEntity? {
        guard let id = selectedServiceID else { return nil }
        return apiServices.first(where: { $0.objectID == id })
    }

    var body: some View {
        HStack(spacing: 0) {
            // Middle Column: Provider List (width: 220)
            providersListColumn
                .frame(width: 220)
                .background(listBackground)

            Rectangle()
                .fill(dividerColor)
                .frame(width: 1)

            // Right Column: Provider Detail Editor
            providerEditorColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(paneBackground)
        }
        .frame(minHeight: 560)
        .onAppear {
            if apiServices.isEmpty {
                populateRoster()
            } else if selectedServiceID == nil, let first = apiServices.first {
                selectService(first)
            }
        }
        .sheet(isPresented: $showingModelSelectionSheet) {
            modelSelectionSheetView
        }
    }

    // MARK: - Middle Column (Provider List)

    private var providersListColumn: some View {
        VStack(spacing: 0) {
            // Top Bar: Providers Title + Search Field
            HStack {
                Text("Providers")
                    .font(.headline)
                    .foregroundStyle(.primary)

                Spacer()

                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    TextField("Search", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(fieldBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(fieldBorder, lineWidth: 1)
                        )
                )
                .frame(width: 110)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            // Scrollable list of providers with brand icons
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filteredServices, id: \.objectID) { service in
                        providerListRow(service)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
            }
            .frame(maxHeight: .infinity)

            Divider()

            // Bottom Toolbar: + / -
            HStack(spacing: 8) {
                Menu {
                    Button("CPA OpenAI") { addNewService(name: "CPA OpenAI", type: "chatgpt", url: "http://127.0.0.1:8899/v1", model: "gpt-5.6-terra") }
                    Button("CPA Anthropic") { addNewService(name: "CPA Anthropic", type: "claude", url: "http://127.0.0.1:8899/v1", model: "anthropic--claude-4.8-opus") }
                    Divider()
                    Button("OpenAI") { addNewService(name: "OpenAI", type: "openai-responses", url: "https://api.openai.com/v1", model: "gpt-4o") }
                    Button("Anthropic") { addNewService(name: "Anthropic", type: "claude", url: "https://api.anthropic.com/v1", model: "claude-sonnet-4-5") }
                    Button("Google AI") { addNewService(name: "Google AI", type: "gemini", url: "https://generativelanguage.googleapis.com/v1beta", model: "gemini-2.5-flash") }
                    Button("DeepSeek") { addNewService(name: "DeepSeek", type: "deepseek", url: "https://api.deepseek.com/v1", model: "deepseek-chat") }
                    Button("Ollama") { addNewService(name: "Ollama", type: "ollama", url: "http://localhost:11434/api/chat", model: "llama3.1") }
                    Button("Azure OpenAI") { addNewService(name: "Azure OpenAI", type: "chatgpt", url: "https://your-resource.openai.azure.com", model: "gpt-4o") }
                    Button("Groq") { addNewService(name: "Groq", type: "chatgpt", url: "https://api.groq.com/openai/v1", model: "llama-3.3-70b-versatile") }
                    Button("OpenRouter") { addNewService(name: "OpenRouter", type: "openrouter", url: "https://openrouter.ai/api/v1", model: "anthropic/claude-sonnet-4.5") }
                    Button("Perplexity") { addNewService(name: "Perplexity", type: "perplexity", url: "https://api.perplexity.ai", model: "sonar") }
                    Divider()
                    Button("Custom Provider...") { addNewService(name: "New Provider", type: "chatgpt", url: "http://127.0.0.1:8899/v1", model: "custom-model") }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 20)

                Button(action: deleteSelectedService) {
                    Image(systemName: "minus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selectedService == nil ? Color.secondary.opacity(0.4) : Color.primary)
                }
                .buttonStyle(.plain)
                .disabled(selectedService == nil)

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private func providerListRow(_ service: APIServiceEntity) -> some View {
        let isSelected = selectedServiceID == service.objectID
        return Button(action: { selectService(service) }) {
            HStack(spacing: 8) {
                providerBrandIcon(name: service.name ?? "", type: service.type ?? "")
                    .frame(width: 16, height: 16)

                Text(service.name ?? "Provider")
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.85))
                    .lineLimit(1)

                Spacer()

                if service.isDefault {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? selectedRowBackground : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Right Column (Provider Detail Editor)

    @ViewBuilder
    private var providerEditorColumn: some View {
        if selectedService != nil {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Title & Subtitle Header
                    // Title & Subtitle Header
                    VStack(alignment: .leading, spacing: 3) {
                        Text(nameText.isEmpty ? "Provider" : nameText)
                            .font(.title2.bold())
                            .foregroundStyle(.primary)

                        Text(providerSubtitle(name: nameText, type: typeText))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)

                    // Section 1: Provider Name
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Provider name")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 8) {
                            providerBrandIcon(name: nameText, type: typeText)
                                .frame(width: 16, height: 16)

                            TextField("", text: $nameText)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 13))
                                .onChange(of: nameText) { _ in autoSave() }
                        }
                    }

                    // Section 2: API Base URL
                    VStack(alignment: .leading, spacing: 3) {
                        Text("API Base URL")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)

                        Text("Do NOT include /chat/completions in the URL")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        TextField("http://127.0.0.1:8899/v1", text: $urlText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13))
                            .onChange(of: urlText) { _ in autoSave() }
                    }

                    // Section 3: Wire API
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Wire API")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)

                        Text("Use Responses only if this provider supports /responses")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Picker("", selection: $typeText) {
                            Text("Responses").tag("openai-responses")
                            Text("Chat Completions").tag("chatgpt")
                            Text("Anthropic Messages").tag("claude")
                            Text("Google Gemini").tag("gemini")
                            Text("Ollama").tag("ollama")
                            Text("OpenRouter").tag("openrouter")
                            Text("DeepSeek").tag("deepseek")
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 200, alignment: .leading)
                        .onChange(of: typeText) { _ in autoSave() }
                    }
                    // Section 4: API Key
                    VStack(alignment: .leading, spacing: 5) {
                        Text("API Key")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 8) {
                            if isShowingAPIKey {
                                TextField("Enter API key", text: $apiKeyText)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 13))
                            } else {
                                SecureField("••••••••••••••••••••••••••••••••", text: $apiKeyText)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 13))
                            }

                            Button(action: { isShowingAPIKey.toggle() }) {
                                Image(systemName: isShowingAPIKey ? "eye.slash" : "eye")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .onChange(of: apiKeyText) { _ in autoSave() }
                    }

                    // Section 5: Models Table (Reference Image #1 exact design)
                    VStack(alignment: .leading, spacing: 6) {
                        // Header row with actions
                        HStack(spacing: 12) {
                            Text("Models")
                                .font(.headline)
                                .foregroundStyle(.primary)

                            Spacer()

                            Button(action: deleteAllModels) {
                                HStack(spacing: 3) {
                                    Image(systemName: "trash")
                                    Text("Delete all")
                                }
                                .font(.system(size: 11))
                                .foregroundStyle(Color.secondary)
                            }
                            .buttonStyle(.plain)
                            .disabled(modelsList.isEmpty)

                            Button(action: addNewModelRow) {
                                HStack(spacing: 3) {
                                    Image(systemName: "plus")
                                    Text("New")
                                }
                                .font(.system(size: 11))
                            }
                            .buttonStyle(.bordered)

                            Button(action: fetchModelsFromAPI) {
                                HStack(spacing: 3) {
                                    if isFetchingModels {
                                        ProgressView().controlSize(.mini)
                                    } else {
                                        Image(systemName: "arrow.clockwise")
                                    }
                                    Text("Fetch Models")
                                }
                                .font(.system(size: 11))
                            }
                            .buttonStyle(.bordered)
                            .accessibilityLabel("Fetch Models")
                        }

                        if let err = fetchError {
                            Text(err)
                                .font(.system(size: 10))
                                .foregroundStyle(Color.red.opacity(0.8))
                        }

                        // Table Container Box
                        VStack(spacing: 0) {
                            // Table Column Headers
                            HStack {
                                Text("Nick name")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 140, alignment: .leading)

                                Text("Model ID")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Spacer()
                                    .frame(width: 50)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)

                            // Rows
                            if modelsList.isEmpty {
                                Text("No models. Click '+ New' to add or 'Fetch Models'.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, 16)
                            } else {
                                ForEach($modelsList) { $row in
                                    modelTableRow($row)
                                }
                            }
                        }
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(fieldBackground)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(dividerColor, lineWidth: 1)
                                )
                        )
                        // Quick Add Popular Models chips
                        quickAddChipsView
                    }
                }
                .padding(20)
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "server.rack")
                    .font(.system(size: 36))
                    .foregroundStyle(.tertiary)
                Text("Select an AI Provider")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func modelTableRow(_ row: Binding<ServiceModelRow>) -> some View {
        let isActive = activeModelID == row.wrappedValue.modelID
        return HStack(spacing: 8) {
            // Nick name input box
            TextField("optional", text: row.nickname)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .frame(width: 140)
                .onChange(of: row.wrappedValue.nickname) { _ in autoSave() }

            // Model ID input box
            TextField("model-id", text: row.modelID)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(isActive ? Color.accentColor : Color.primary)
                .onChange(of: row.wrappedValue.modelID) { _ in autoSave() }

            // Gear/Check Action (Set as default active model)
            Button(action: {
                activeModelID = row.wrappedValue.modelID
                autoSave()
            }) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "gearshape")
                    .font(.system(size: 13))
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(isActive ? "Active Model" : "Set as Active Model")

            // Trash Action (Delete row)
            Button(action: {
                deleteModelRow(id: row.wrappedValue.id)
            }) {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private var quickAddChipsView: some View {
        let presets = recommendedModels(for: typeText)
        return HStack(spacing: 6) {
            Text("Presets:")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(presets, id: \.self) { mid in
                Button(action: {
                    if !modelsList.contains(where: { $0.modelID == mid }) {
                        modelsList.append(ServiceModelRow(nickname: "optional", modelID: mid))
                        autoSave()
                    }
                }) {
                    Text("+ \(mid)")
                        .font(.system(size: 11, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color(NSColor.controlBackgroundColor)))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.top, 2)
    }

    // MARK: - Auto-Save & State Synchronization

    private func autoSave() {
        guard let service = selectedService else { return }
        service.name = nameText
        service.type = typeText
        service.url = URL(string: urlText)
        service.model = activeModelID.isEmpty ? (modelsList.first?.modelID ?? "") : activeModelID

        if let id = service.id {
            try? TokenManager.setToken(apiKeyText, for: id.uuidString)
            saveModels(for: id)
        }
        try? viewContext.save()
    }

    private func selectService(_ service: APIServiceEntity) {
        selectedServiceID = service.objectID
        nameText = service.name ?? ""
        urlText = service.url?.absoluteString ?? ""
        typeText = service.type ?? "chatgpt"
        activeModelID = service.model ?? ""
        fetchError = nil

        if let serviceID = service.id {
            apiKeyText = (try? TokenManager.getToken(for: serviceID.uuidString)) ?? ""
            if apiKeyText.isEmpty {
                apiKeyText = ProcessInfo.processInfo.environment["LOCAL_SAP_AI_CORE_PROXY_KEY"] ?? ""
            }
            loadModels(for: serviceID)
        }
    }
    private func addNewService(name: String, type: String, url: String, model: String) {
        let manager = APIServiceManager(viewContext: viewContext)
        let entity = manager.createAPIService(
            name: name,
            type: type,
            url: URL(string: url) ?? URL(fileURLWithPath: ""),
            model: model,
            contextSize: 20,
            useStreamResponse: true,
            generateChatNames: true
        )
        entity.isDefault = apiServices.isEmpty
        try? viewContext.save()
        selectService(entity)
    }

    private func deleteSelectedService() {
        guard let service = selectedService else { return }
        if let id = service.id {
            try? TokenManager.deleteToken(for: id.uuidString)
            UserDefaults.standard.removeObject(forKey: "service_models_\(id.uuidString)")
        }
        viewContext.delete(service)
        try? viewContext.save()
        selectedServiceID = apiServices.first?.objectID
        if let first = apiServices.first {
            selectService(first)
        }
    }

    private func addNewModelRow() {
        let row = ServiceModelRow(nickname: "optional", modelID: "new-model")
        modelsList.append(row)
        if activeModelID.isEmpty { activeModelID = row.modelID }
        autoSave()
    }

    private func deleteModelRow(id: String) {
        modelsList.removeAll { $0.id == id }
        if !modelsList.contains(where: { $0.modelID == activeModelID }), let next = modelsList.first {
            activeModelID = next.modelID
        }
        autoSave()
    }

    private func deleteAllModels() {
        modelsList.removeAll()
        activeModelID = ""
        autoSave()
    }

    private func loadModels(for serviceID: UUID) {
        let key = "service_models_\(serviceID.uuidString)"
        if let data = UserDefaults.standard.string(forKey: key)?.data(using: .utf8),
           let list = try? JSONDecoder().decode([ServiceModelRow].self, from: data), !list.isEmpty {
            self.modelsList = list
        } else {
            let presets = recommendedModels(for: typeText).map { ServiceModelRow(nickname: "optional", modelID: $0) }
            self.modelsList = presets.isEmpty ? [ServiceModelRow(nickname: "optional", modelID: activeModelID)] : presets
            saveModels(for: serviceID)
        }
    }

    private func saveModels(for serviceID: UUID) {
        let key = "service_models_\(serviceID.uuidString)"
        if let data = try? JSONEncoder().encode(modelsList),
           let str = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(str, forKey: key)
        }
    }

    private func fetchModelsFromAPI() {
        guard let service = selectedService, let id = service.id else { return }
        isFetchingModels = true
        fetchError = nil

        let cfg = APIServiceConfig(name: nameText, apiUrl: URL(string: urlText) ?? URL(fileURLWithPath: ""), apiKey: apiKeyText, model: activeModelID, type: typeText)
        let handler = APIServiceFactory.createAPIService(config: cfg)

        Task {
            do {
                let models = try await handler.fetchModels()
                await MainActor.run {
                    self.isFetchingModels = false
                    if !models.isEmpty {
                        self.fetchedCandidateModels = models
                        self.modelSearchQuery = ""
                        self.updateSelectionForFilter(query: "")
                        self.showingModelSelectionSheet = true
                    } else {
                        self.fetchError = "No models returned from endpoint"
                    }
                }
            } catch {
                await MainActor.run {
                    self.isFetchingModels = false
                    self.fetchError = "Fetch failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private var modelSelectionSheetView: some View {
        let trimmedQuery = modelSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = fetchedCandidateModels.filter {
            trimmedQuery.isEmpty || $0.id.localizedCaseInsensitiveContains(trimmedQuery)
        }
        let filteredIDs = Set(filtered.map(\.id))
        let effectiveSelected = selectedModelIDsForImport.intersection(filteredIDs)

        return VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Select Models to Add")
                        .font(.headline)
                    Text("Found \(fetchedCandidateModels.count) models from \(nameText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                // Search field
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextField("Filter models...", text: $modelSearchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                    if !modelSearchQuery.isEmpty {
                        Button(action: { modelSearchQuery = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(NSColor.controlBackgroundColor))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                )
                .frame(width: 180)
            }

            // Quick select toolbar
            HStack(spacing: 12) {
                Button("Select All") {
                    selectedModelIDsForImport = Set(filtered.map(\.id))
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(Color.accentColor)

                Button("Deselect All") {
                    selectedModelIDsForImport.removeAll()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)

                Spacer()

                Text("\(effectiveSelected.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // List of models with checkboxes
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filtered, id: \.id) { m in
                        let isSelected = selectedModelIDsForImport.contains(m.id)
                        let alreadyAdded = modelsList.contains(where: { $0.modelID == m.id })

                        Button(action: {
                            if isSelected {
                                selectedModelIDsForImport.remove(m.id)
                            } else {
                                selectedModelIDsForImport.insert(m.id)
                            }
                        }) {
                            HStack(spacing: 10) {
                                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 14))
                                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                                Text(m.id)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(Color.primary)

                                Spacer()

                                if alreadyAdded {
                                    Text("Added")
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(Color.secondary.opacity(0.2)))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: 280)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.controlBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(NSColor.separatorColor).opacity(0.3), lineWidth: 1))
            )

            Divider()

            // Bottom action buttons
            HStack {
                Button("Cancel") {
                    showingModelSelectionSheet = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Add Selected (\(effectiveSelected.count))") {
                    importSelectedModels()
                    showingModelSelectionSheet = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(effectiveSelected.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540, height: 460)
        .onChange(of: modelSearchQuery) { newQuery in
            updateSelectionForFilter(query: newQuery)
        }
    }

    private func updateSelectionForFilter(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = fetchedCandidateModels.filter {
            trimmed.isEmpty || $0.id.localizedCaseInsensitiveContains(trimmed)
        }
        let unaddedFiltered = filtered.map(\.id).filter { mid in
            !modelsList.contains(where: { $0.modelID == mid })
        }
        selectedModelIDsForImport = Set(unaddedFiltered.isEmpty ? filtered.map(\.id) : unaddedFiltered)
    }

    private func importSelectedModels() {
        let trimmed = modelSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let filteredIDs = Set(fetchedCandidateModels.filter {
            trimmed.isEmpty || $0.id.localizedCaseInsensitiveContains(trimmed)
        }.map(\.id))
        let idsToImport = selectedModelIDsForImport.intersection(filteredIDs)

        for mid in idsToImport {
            if !modelsList.contains(where: { $0.modelID == mid }) {
                modelsList.append(ServiceModelRow(nickname: "optional", modelID: mid))
            }
        }
        if activeModelID.isEmpty, let first = modelsList.first {
            activeModelID = first.modelID
        }
        autoSave()
    }

    // Populate standard roster on first launch matching Image #1
    private func populateRoster() {
        let proxyKey = ProcessInfo.processInfo.environment["LOCAL_SAP_AI_CORE_PROXY_KEY"] ?? ""
        let cpa = createRosterEntity(
            name: "CPA OpenAI", type: "chatgpt", url: "http://127.0.0.1:8899/v1", model: "gpt-5.6-terra",
            apiKey: proxyKey, isDefault: true,
            models: [
                ServiceModelRow(nickname: "optional", modelID: "gpt-5.6-terra"),
                ServiceModelRow(nickname: "optional", modelID: "aicore/anthropic--claude-4.8-opus"),
                ServiceModelRow(nickname: "optional", modelID: "gpt-5.6-sol"),
                ServiceModelRow(nickname: "optional", modelID: "aicore/gemini-3.8-flash")
            ]
        )
        _ = createRosterEntity(name: "Anthropic", type: "claude", url: "https://api.anthropic.com/v1", model: "claude-sonnet-4-5")
        _ = createRosterEntity(name: "Azure OpenAI", type: "chatgpt", url: "https://your-resource.openai.azure.com", model: "gpt-4o")
        _ = createRosterEntity(name: "CPA Anthropic", type: "claude", url: "http://127.0.0.1:8899/v1", model: "anthropic--claude-4.8-opus")
        _ = createRosterEntity(name: "DeepSeek", type: "deepseek", url: "https://api.deepseek.com/v1", model: "deepseek-chat")
        _ = createRosterEntity(name: "GitHub Copilot", type: "chatgpt", url: "https://api.githubcopilot.com", model: "gpt-4o")
        _ = createRosterEntity(name: "Google AI", type: "gemini", url: "https://generativelanguage.googleapis.com/v1beta", model: "gemini-2.5-flash")
        _ = createRosterEntity(name: "Groq", type: "chatgpt", url: "https://api.groq.com/openai/v1", model: "llama-3.3-70b-versatile")
        _ = createRosterEntity(name: "Mistral", type: "chatgpt", url: "https://api.mistral.ai/v1", model: "mistral-large-latest")
        _ = createRosterEntity(name: "Ollama", type: "ollama", url: "http://localhost:11434/api/chat", model: "llama3.1")
        _ = createRosterEntity(name: "OpenAI", type: "openai-responses", url: "https://api.openai.com/v1", model: "gpt-4o")
        _ = createRosterEntity(name: "OpenAI Codex", type: "chatgpt", url: "https://api.openai.com/v1", model: "code-davinci-002")
        _ = createRosterEntity(name: "OpenRouter", type: "openrouter", url: "https://openrouter.ai/api/v1", model: "anthropic/claude-sonnet-4.5")
        _ = createRosterEntity(name: "Perplexity", type: "perplexity", url: "https://api.perplexity.ai", model: "sonar")

        if let cpa {
            selectService(cpa)
        }
    }

    private func createRosterEntity(name: String, type: String, url: String, model: String, apiKey: String = "", isDefault: Bool = false, models: [ServiceModelRow] = []) -> APIServiceEntity? {
        let manager = APIServiceManager(viewContext: viewContext)
        let entity = manager.createAPIService(
            name: name,
            type: type,
            url: URL(string: url) ?? URL(fileURLWithPath: ""),
            model: model,
            contextSize: 20,
            useStreamResponse: true,
            generateChatNames: true
        )
        entity.isDefault = isDefault
        if let id = entity.id {
            if !apiKey.isEmpty {
                try? TokenManager.setToken(apiKey, for: id.uuidString)
            }
            let list = models.isEmpty ? recommendedModels(for: type).map { ServiceModelRow(nickname: "optional", modelID: $0) } : models
            saveModels(for: id)
            let key = "service_models_\(id.uuidString)"
            if let data = try? JSONEncoder().encode(list), let str = String(data: data, encoding: .utf8) {
                UserDefaults.standard.set(str, forKey: key)
            }
        }
        try? viewContext.save()
        return entity
    }

    // MARK: - Helpers

    private func providerSubtitle(name: String, type: String) -> String {
        let lowerName = name.lowercased()
        let lowerType = type.lowercased()
        if lowerName.contains("cpa") || lowerName.contains("proxy") {
            return "OpenAI-compatible provider"
        }
        switch lowerType {
        case "claude": return "Anthropic Claude provider"
        case "gemini": return "Google Gemini provider"
        case "ollama": return "Local Ollama provider"
        case "deepseek": return "DeepSeek AI provider"
        case "openrouter": return "OpenRouter multi-model provider"
        case "openai-responses": return "OpenAI Responses API provider"
        default: return "OpenAI-compatible provider"
        }
    }

    @ViewBuilder
    private func providerBrandIcon(name: String, type: String) -> some View {
        let lower = (name + " " + type).lowercased()
        if lower.contains("cpa") || lower.contains("hai") || lower.contains("sap") {
            Image(systemName: "server.rack")
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.75))
        } else if lower.contains("anthropic") || lower.contains("claude") {
            Text("A\\")
                .font(.system(size: 11, weight: .black, design: .serif))
                .foregroundStyle(Color(red: 0.85, green: 0.45, blue: 0.35))
        } else if lower.contains("azure") {
            Image(systemName: "triangle.fill")
                .font(.system(size: 9))
                .foregroundStyle(Color.blue)
        } else if lower.contains("deepseek") {
            Image(systemName: "sparkles")
                .font(.system(size: 10))
                .foregroundStyle(Color.cyan)
        } else if lower.contains("copilot") {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.8))
        } else if lower.contains("google") || lower.contains("gemini") {
            Text("G")
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundStyle(Color(red: 0.3, green: 0.5, blue: 0.9))
        } else if lower.contains("groq") {
            Text("9")
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(Color.orange)
        } else if lower.contains("ollama") {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 10))
                .foregroundStyle(Color.white.opacity(0.8))
        } else if lower.contains("openrouter") {
            Text("<")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.8))
        } else if lower.contains("perplexity") {
            Image(systemName: "asterisk")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.teal)
        } else if lower.contains("codex") {
            Text(">_")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.green)
        } else if lower.contains("mistral") {
            Text("M")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.orange)
        } else {
            Image(systemName: "circle.hexagonpath.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.green)
        }
    }

    private func recommendedModels(for type: String) -> [String] {
        switch type.lowercased() {
        case "claude":
            return ["claude-sonnet-4-5", "claude-3-7-sonnet", "claude-3-5-haiku"]
        case "gemini":
            return ["gemini-2.5-flash", "gemini-3.8-flash", "gemini-2.5-pro"]
        case "ollama":
            return ["llama3.3", "llama3.1", "qwen2.5:14b"]
        case "deepseek":
            return ["deepseek-chat", "deepseek-reasoner"]
        default:
            return ["gpt-5.6-terra", "gpt-5.6-luna", "gpt-4o", "gpt-4o-mini"]
        }
    }
}
