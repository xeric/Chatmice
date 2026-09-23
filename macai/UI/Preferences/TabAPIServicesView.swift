//
//  TabAPIServicesView.swift
//  Chatmice / macai
//
//  Native macOS 3-column settings view for AI Providers (matching Xcode Accounts pattern).
//  - Middle Column: List of configured providers with search, brand icons, and +/- toolbar
//  - Right Column: Detailed provider settings (URL, Wire API, Key, Models table)
//

import AppKit
import CoreData
import Foundation
import SwiftUI

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

    // Form fields for currently selected provider
    @State private var nameText = ""
    @State private var urlText = ""
    @State private var typeText = "chatgpt"
    @State private var apiKeyText = ""
    @State private var modelsList: [ServiceModelRow] = []
    @State private var activeModelID = ""

    // Model fetching
    @State private var isFetchingModels = false
    @State private var fetchError: String?
    @State private var showingModelSelectionSheet = false
    @State private var fetchedCandidateModels: [AIModel] = []
    @State private var selectedModelIDsForImport: Set<String> = []
    @State private var modelSearchQuery = ""

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
            // Column 2: Provider List (width: 230)
            providersListColumn
                .frame(width: 230)
                .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Column 3: Provider Detail Editor
            providerDetailColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor.windowBackgroundColor))
        }
        .onAppear {
            sanitizeDefaults()
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

    // MARK: - Column 2: Provider List

    private var providersListColumn: some View {
        VStack(spacing: 0) {
            // Search field at top
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondary)

                TextField("Search providers", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(NSColor.textBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color(NSColor.separatorColor), lineWidth: 0.8)
                    )
            )
            .padding(10)

            Divider()

            // Scrollable list of providers
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filteredServices, id: \.objectID) { service in
                        providerListRow(service)
                    }
                }
                .padding(.vertical, 6)
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
                        .foregroundStyle(Color.primary)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 22)

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
            HStack(spacing: 10) {
                providerBrandIcon(name: service.name ?? "", type: service.type ?? "")
                    .frame(width: 18, height: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(service.name ?? "Provider")
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)

                    Text(service.type ?? "chatgpt")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Column 3: Provider Detail Editor

    @ViewBuilder
    private var providerDetailColumn: some View {
        if selectedService != nil {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Header
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 10) {
                            providerBrandIcon(name: nameText, type: typeText)
                                .frame(width: 22, height: 22)

                            Text(nameText.isEmpty ? "Provider" : nameText)
                                .font(.title2.bold())
                                .foregroundStyle(Color.primary)
                        }

                        Text(providerSubtitle(name: nameText, type: typeText))
                            .font(.subheadline)
                            .foregroundStyle(Color.secondary)
                    }
                    .padding(.bottom, 2)

                    // Connection Settings GroupBox
                    GroupBox("Connection Settings") {
                        VStack(alignment: .leading, spacing: 14) {
                            LabeledContent("Provider Name") {
                                TextField("Name", text: $nameText)
                                    .textFieldStyle(.roundedBorder)
                                    .onChange(of: nameText) { _ in autoSave() }
                            }

                            Divider()

                            LabeledContent {
                                VStack(alignment: .leading, spacing: 3) {
                                    TextField("http://127.0.0.1:8899/v1", text: $urlText)
                                        .textFieldStyle(.roundedBorder)
                                        .onChange(of: urlText) { _ in autoSave() }

                                    Text("Do NOT include /chat/completions in the URL")
                                        .font(.caption2)
                                        .foregroundStyle(Color.secondary)
                                }
                            } label: {
                                Text("API Base URL")
                            }

                            Divider()

                            LabeledContent {
                                VStack(alignment: .leading, spacing: 3) {
                                    Picker("", selection: $typeText) {
                                        Text("Chat Completions").tag("chatgpt")
                                        Text("Responses").tag("openai-responses")
                                        Text("Anthropic Messages").tag("claude")
                                        Text("Google Gemini").tag("gemini")
                                        Text("Ollama").tag("ollama")
                                        Text("OpenRouter").tag("openrouter")
                                        Text("DeepSeek").tag("deepseek")
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                    .frame(maxWidth: 220, alignment: .leading)
                                    .onChange(of: typeText) { _ in autoSave() }

                                    Text("Select protocol format used by this endpoint")
                                        .font(.caption2)
                                        .foregroundStyle(Color.secondary)
                                }
                            } label: {
                                Text("Wire API")
                            }

                            Divider()

                            LabeledContent("API Key") {
                                HStack(spacing: 8) {
                                    if isShowingAPIKey {
                                        TextField("Enter API key", text: $apiKeyText)
                                            .textFieldStyle(.roundedBorder)
                                    } else {
                                        SecureField("••••••••••••••••••••••••••••••••", text: $apiKeyText)
                                            .textFieldStyle(.roundedBorder)
                                    }

                                    Button(action: { isShowingAPIKey.toggle() }) {
                                        Image(systemName: isShowingAPIKey ? "eye.slash" : "eye")
                                            .font(.system(size: 12))
                                            .foregroundStyle(Color.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .onChange(of: apiKeyText) { _ in autoSave() }
                            }

                            Divider()

                            if let service = selectedService {
                                VStack(alignment: .leading, spacing: 4) {
                                    Toggle("Default for New Chats", isOn: Binding(
                                        get: { service.isDefault },
                                        set: { if $0 { setDefaultService(service) } }
                                    ))
                                    .toggleStyle(.switch)

                                    Text("Used automatically when starting a new conversation if no specific assistant is chosen.")
                                        .font(.caption2)
                                        .foregroundStyle(Color.secondary)
                                }
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // Models GroupBox
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Configured Models (\(modelsList.count))")
                                    .font(.headline)

                                Spacer()

                                Button(action: addNewModelRow) {
                                    Label("New", systemImage: "plus")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)

                                Button(action: fetchModelsFromAPI) {
                                    HStack(spacing: 4) {
                                        if isFetchingModels {
                                            ProgressView().controlSize(.mini)
                                        } else {
                                            Image(systemName: "arrow.clockwise")
                                        }
                                        Text("Fetch Models")
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }

                            if let err = fetchError {
                                Text(err)
                                    .font(.caption)
                                    .foregroundStyle(Color.red)
                            }

                            // Table of models
                            VStack(spacing: 6) {
                                HStack {
                                    Text("Nickname")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(Color.secondary)
                                        .frame(width: 140, alignment: .leading)

                                    Text("Model ID")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(Color.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)

                                    Spacer().frame(width: 50)
                                }
                                .padding(.horizontal, 4)

                                if modelsList.isEmpty {
                                    Text("No models configured. Click '+ New' or 'Fetch Models'.")
                                        .font(.subheadline)
                                        .foregroundStyle(Color.secondary)
                                        .padding(.vertical, 16)
                                        .frame(maxWidth: .infinity, alignment: .center)
                                } else {
                                    ForEach($modelsList) { $row in
                                        modelTableRow($row)
                                    }
                                }
                            }

                            Divider()

                            quickAddChipsView
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Text("Models")
                            .font(.headline)
                    }
                }
                .padding(24)
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "server.rack")
                    .font(.system(size: 40))
                    .foregroundStyle(Color.secondary.opacity(0.4))
                Text("Select a Provider")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(Color.secondary)
                Text("Select an AI provider from the list on the left or click '+' to configure a new one.")
                    .font(.caption)
                    .foregroundStyle(Color.secondary.opacity(0.8))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func modelTableRow(_ row: Binding<ServiceModelRow>) -> some View {
        let isActive = activeModelID == row.wrappedValue.modelID
        return HStack(spacing: 8) {
            TextField("optional", text: row.nickname)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .frame(width: 140)
                .onChange(of: row.wrappedValue.nickname) { _ in autoSave() }

            TextField("model-id", text: row.modelID)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(isActive ? Color.accentColor : Color.primary)
                .onChange(of: row.wrappedValue.modelID) { _ in autoSave() }

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

            Button(action: {
                deleteModelRow(id: row.wrappedValue.id)
            }) {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
    }

    private var quickAddChipsView: some View {
        let presets = recommendedModels(for: typeText)
        return HStack(spacing: 6) {
            Text("Presets:")
                .font(.caption)
                .foregroundStyle(Color.secondary)

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
                        .foregroundStyle(Color.secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.top, 4)
    }

    // MARK: - Auto-Save & Actions

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

    private func setDefaultService(_ service: APIServiceEntity) {
        apiServices.forEach { s in
            s.isDefault = (s.objectID == service.objectID)
        }
        try? viewContext.save()
    }

    private func sanitizeDefaults() {
        let defaults = apiServices.filter { $0.isDefault }
        if defaults.count > 1 {
            for extra in defaults.dropFirst() {
                extra.isDefault = false
            }
            try? viewContext.save()
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

    private func loadModels(for serviceID: UUID) {
        let key = "service_models_\(serviceID.uuidString)"
        if let data = UserDefaults.standard.string(forKey: key)?.data(using: .utf8),
           let list = try? JSONDecoder().decode([ServiceModelRow].self, from: data) {
            self.modelsList = list
            if activeModelID.isEmpty, let first = list.first {
                activeModelID = first.modelID
            }
            return
        }
        let defaults = recommendedModels(for: typeText)
        self.modelsList = defaults.map { ServiceModelRow(nickname: "optional", modelID: $0) }
        if activeModelID.isEmpty, let first = modelsList.first {
            activeModelID = first.modelID
        }
        saveModels(for: serviceID)
    }

    private func saveModels(for serviceID: UUID) {
        let key = "service_models_\(serviceID.uuidString)"
        if let data = try? JSONEncoder().encode(modelsList),
           let str = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(str, forKey: key)
        }
    }

    // MARK: - Model Fetching & Selection Sheet

    private func fetchModelsFromAPI() {
        guard let service = selectedService, let id = service.id else { return }
        let config = APIServiceConfig(
            name: nameText,
            apiUrl: URL(string: urlText) ?? URL(fileURLWithPath: ""),
            apiKey: apiKeyText,
            model: activeModelID,
            type: typeText
        )
        let handler = APIServiceFactory.createAPIService(config: config, imageGenerationSupported: false)
        isFetchingModels = true
        fetchError = nil

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
                        .foregroundStyle(Color.secondary)
                }
                Spacer()
                // Search field
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondary)
                    TextField("Filter models...", text: $modelSearchQuery)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                }
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
                .foregroundStyle(Color.secondary)

                Spacer()

                Text("\(effectiveSelected.count) selected")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
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
                                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                                        .foregroundStyle(Color.secondary)
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
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(NSColor.separatorColor), lineWidth: 1))
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

    // MARK: - Initial Roster & Brand Icons

    private func populateRoster() {
        let proxyKey = ProcessInfo.processInfo.environment["LOCAL_SAP_AI_CORE_PROXY_KEY"] ?? ""
        let cpa = createRosterEntity(
            name: "CPA OpenAI", type: "chatgpt", url: "http://127.0.0.1:8899/v1", model: "gpt-5.6-terra",
            apiKey: proxyKey, isDefault: true,
            models: [
                ServiceModelRow(nickname: "optional", modelID: "gpt-5.6-terra"),
                ServiceModelRow(nickname: "optional", modelID: "gpt-5.6-luna"),
                ServiceModelRow(nickname: "optional", modelID: "gpt-4o"),
                ServiceModelRow(nickname: "optional", modelID: "gpt-4o-mini")
            ]
        )
        _ = createRosterEntity(name: "SAP Anthropic", type: "claude", url: "http://127.0.0.1:8899/v1", model: "anthropic--claude-4.8-opus")
        _ = createRosterEntity(name: "SAP Gemini", type: "gemini", url: "https://generativelanguage.googleapis.com/v1beta", model: "gemini-2.5-flash")
        _ = createRosterEntity(name: "SAP OpenAI", type: "chatgpt", url: "http://127.0.0.1:9988/openai/v1", model: "qwen3.8-27b-dev-preview")
        selectService(cpa)
    }

    private func createRosterEntity(name: String, type: String, url: String, model: String, apiKey: String = "", isDefault: Bool = false, models: [ServiceModelRow] = []) -> APIServiceEntity {
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
            if !models.isEmpty {
                if let data = try? JSONEncoder().encode(models), let str = String(data: data, encoding: .utf8) {
                    UserDefaults.standard.set(str, forKey: "service_models_\(id.uuidString)")
                }
            }
        }
        try? viewContext.save()
        return entity
    }

    private func recommendedModels(for type: String) -> [String] {
        switch type {
        case "chatgpt":
            return ["gpt-5.6-terra", "gpt-5.6-luna", "gpt-4o", "gpt-4o-mini", "qwen3.8-27b-dev-preview"]
        case "openai-responses":
            return ["gpt-4o", "gpt-4o-mini", "o1", "o3-mini"]
        case "claude":
            return ["claude-3-5-sonnet-latest", "claude-3-5-haiku-latest", "anthropic--claude-4.8-opus"]
        case "gemini":
            return ["gemini-2.5-flash", "gemini-2.5-pro", "gemini-3.8-flash"]
        case "deepseek":
            return ["deepseek-chat", "deepseek-reasoner"]
        case "ollama":
            return ["llama3.1", "qwen2.5:7b", "mistral"]
        default:
            return ["gpt-4o", "claude-3-5-sonnet-latest"]
        }
    }

    private func providerSubtitle(name: String, type: String) -> String {
        switch type {
        case "chatgpt":
            return "OpenAI-compatible Chat Completions endpoint"
        case "openai-responses":
            return "OpenAI-compatible Responses endpoint"
        case "claude":
            return "Anthropic Messages protocol endpoint"
        case "gemini":
            return "Google Gemini generative API endpoint"
        case "ollama":
            return "Local Ollama server API endpoint"
        case "openrouter":
            return "OpenRouter multi-model gateway"
        case "deepseek":
            return "DeepSeek direct API endpoint"
        default:
            return "AI service provider endpoint"
        }
    }

    @ViewBuilder
    private func providerBrandIcon(name: String, type: String) -> some View {
        let low = (name + " " + type).lowercased()
        if low.contains("openai") || low.contains("chatgpt") || low.contains("gpt") {
            Image(systemName: "cpu")
                .foregroundStyle(Color.green)
        } else if low.contains("claude") || low.contains("anthropic") {
            Image(systemName: "brain")
                .foregroundStyle(Color.orange)
        } else if low.contains("gemini") || low.contains("google") {
            Image(systemName: "sparkles")
                .foregroundStyle(Color.blue)
        } else if low.contains("deepseek") {
            Image(systemName: "bolt.fill")
                .foregroundStyle(Color.cyan)
        } else if low.contains("ollama") {
            Image(systemName: "terminal.fill")
                .foregroundStyle(Color.purple)
        } else {
            Image(systemName: "network")
                .foregroundStyle(Color.accentColor)
        }
    }
}
