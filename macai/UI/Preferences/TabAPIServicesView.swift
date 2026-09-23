//
//  TabAPIServicesView.swift
//  Chatmice / macai
//
//  Pixel-perfect native macOS Provider List & Edit Sheet (Apple HIG).
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

    @State private var editingService: APIServiceEntity?
    @State private var isShowingAddSheet = false
    @State private var initialAddPreset: ProviderPresetItem?

    var body: some View {
        Form {
            Section {
                if apiServices.isEmpty {
                    Text("No AI providers configured. Click '+ Add Provider' below to configure your first endpoint.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 12)
                } else {
                    ForEach(apiServices, id: \.objectID) { service in
                        providerRow(service)
                    }
                }

                // Toolbar at bottom of card
                HStack {
                    Menu {
                        Button("CPA OpenAI") {
                            presentAddSheet(preset: ProviderPresetItem(
                                name: "CPA OpenAI", type: "chatgpt", defaultURL: "http://127.0.0.1:8899/v1", defaultModel: "gpt-5.6-terra",
                                subtitle: "OpenAI-compatible local endpoint",
                                models: [
                                    ServiceModelRow(nickname: "", modelID: "gpt-5.6-terra"),
                                    ServiceModelRow(nickname: "", modelID: "gpt-5.6-luna"),
                                    ServiceModelRow(nickname: "", modelID: "gpt-4o"),
                                    ServiceModelRow(nickname: "", modelID: "gpt-4o-mini")
                                ]
                            ))
                        }
                        Button("CPA Anthropic") {
                            presentAddSheet(preset: ProviderPresetItem(
                                name: "CPA Anthropic", type: "claude", defaultURL: "http://127.0.0.1:8899/v1", defaultModel: "anthropic--claude-4.8-opus",
                                subtitle: "Claude local endpoint",
                                models: [ServiceModelRow(nickname: "", modelID: "anthropic--claude-4.8-opus")]
                            ))
                        }
                        Divider()
                        Button("OpenAI") {
                            presentAddSheet(preset: ProviderPresetItem(
                                name: "OpenAI", type: "openai-responses", defaultURL: "https://api.openai.com/v1", defaultModel: "gpt-4o",
                                subtitle: "Official OpenAI API",
                                models: [ServiceModelRow(nickname: "", modelID: "gpt-4o"), ServiceModelRow(nickname: "", modelID: "gpt-4o-mini")]
                            ))
                        }
                        Button("Anthropic") {
                            presentAddSheet(preset: ProviderPresetItem(
                                name: "Anthropic", type: "claude", defaultURL: "https://api.anthropic.com/v1", defaultModel: "claude-3-5-sonnet-latest",
                                subtitle: "Official Anthropic API",
                                models: [ServiceModelRow(nickname: "", modelID: "claude-3-5-sonnet-latest")]
                            ))
                        }
                        Button("Google AI") {
                            presentAddSheet(preset: ProviderPresetItem(
                                name: "Google AI", type: "gemini", defaultURL: "https://generativelanguage.googleapis.com/v1beta", defaultModel: "gemini-2.5-flash",
                                subtitle: "Google Gemini API",
                                models: [ServiceModelRow(nickname: "", modelID: "gemini-2.5-flash")]
                            ))
                        }
                        Button("DeepSeek") {
                            presentAddSheet(preset: ProviderPresetItem(
                                name: "DeepSeek", type: "deepseek", defaultURL: "https://api.deepseek.com/v1", defaultModel: "deepseek-chat",
                                subtitle: "DeepSeek Official API",
                                models: [ServiceModelRow(nickname: "", modelID: "deepseek-chat")]
                            ))
                        }
                        Button("Ollama") {
                            presentAddSheet(preset: ProviderPresetItem(
                                name: "Ollama", type: "ollama", defaultURL: "http://localhost:11434/api/chat", defaultModel: "llama3.1",
                                subtitle: "Local Ollama server",
                                models: [ServiceModelRow(nickname: "", modelID: "llama3.1")]
                            ))
                        }
                        Divider()
                        Button("Custom Provider...") {
                            presentAddSheet(preset: nil)
                        }
                    } label: {
                        Label("Add Provider...", systemImage: "plus")
                    }
                    .menuStyle(.borderlessButton)

                    Spacer()
                }
                .padding(.vertical, 4)
            } header: {
                Text("AI Providers")
            } footer: {
                Text("Click any provider to view and edit its connection settings and models.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            sanitizeDefaults()
            if apiServices.isEmpty {
                populateRoster()
            }
        }
        .sheet(item: $editingService) { (service: APIServiceEntity) in
            ProviderEditorSheet(
                service: service,
                initialPreset: nil,
                onSave: {
                    try? viewContext.save()
                    sanitizeDefaults()
                },
                onDelete: {
                    deleteService(service)
                }
            )
        }
        .sheet(isPresented: $isShowingAddSheet) {
            ProviderEditorSheet(
                service: nil,
                initialPreset: initialAddPreset,
                onSave: {
                    try? viewContext.save()
                    sanitizeDefaults()
                },
                onDelete: {}
            )
        }
    }

    // MARK: - Row View

    private func providerRow(_ service: APIServiceEntity) -> some View {
        Button(action: {
            editingService = service
        }) {
            HStack(spacing: 12) {
                providerBrandIcon(name: service.name ?? "", type: service.type ?? "")
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(service.name ?? "Provider")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.primary)

                        if service.isDefault {
                            Text("Default")
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                                .foregroundStyle(Color.accentColor)
                        }
                    }

                    let urlString = service.url?.absoluteString ?? "No URL"
                    let modelsCount = countModels(for: service)
                    Text("\(service.type ?? "chatgpt") • \(urlString) • \(modelsCount) \(modelsCount == 1 ? "model" : "models")")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.secondary.opacity(0.4))
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Edit...") {
                editingService = service
            }
            Button("Duplicate") {
                duplicateService(service)
            }
            Divider()
            Button("Delete", role: .destructive) {
                deleteService(service)
            }
        }
    }

    // MARK: - Helpers

    private func countModels(for service: APIServiceEntity) -> Int {
        guard let id = service.id else { return 0 }
        let key = "service_models_\(id.uuidString)"
        if let data = UserDefaults.standard.string(forKey: key)?.data(using: .utf8),
           let list = try? JSONDecoder().decode([ServiceModelRow].self, from: data) {
            return list.count
        }
        return 0
    }

    private func presentAddSheet(preset: ProviderPresetItem?) {
        initialAddPreset = preset
        isShowingAddSheet = true
    }

    private func duplicateService(_ service: APIServiceEntity) {
        let manager = APIServiceManager(viewContext: viewContext)
        let newService = manager.createAPIService(
            name: (service.name ?? "Provider") + " Copy",
            type: service.type ?? "chatgpt",
            url: service.url ?? URL(fileURLWithPath: ""),
            model: service.model ?? "",
            contextSize: service.contextSize,
            useStreamResponse: service.useStreamResponse,
            generateChatNames: service.generateChatNames
        )
        newService.isDefault = false

        if let oldID = service.id, let newID = newService.id {
            if let token = try? TokenManager.getToken(for: oldID.uuidString) {
                try? TokenManager.setToken(token, for: newID.uuidString)
            }
            let key = "service_models_\(oldID.uuidString)"
            if let data = UserDefaults.standard.string(forKey: key) {
                UserDefaults.standard.set(data, forKey: "service_models_\(newID.uuidString)")
            }
        }
        try? viewContext.save()
    }

    private func deleteService(_ service: APIServiceEntity) {
        if let id = service.id {
            try? TokenManager.deleteToken(for: id.uuidString)
            UserDefaults.standard.removeObject(forKey: "service_models_\(id.uuidString)")
        }
        viewContext.delete(service)
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

    private func populateRoster() {
        let proxyKey = ProcessInfo.processInfo.environment["LOCAL_SAP_AI_CORE_PROXY_KEY"] ?? ""
        let cpa = createRosterEntity(
            name: "CPA OpenAI", type: "chatgpt", url: "http://127.0.0.1:8899/v1", model: "gpt-5.6-terra",
            apiKey: proxyKey, isDefault: true,
            models: [
                ServiceModelRow(nickname: "", modelID: "gpt-5.6-terra"),
                ServiceModelRow(nickname: "", modelID: "gpt-5.6-luna"),
                ServiceModelRow(nickname: "", modelID: "gpt-4o"),
                ServiceModelRow(nickname: "", modelID: "gpt-4o-mini")
            ]
        )
        _ = createRosterEntity(name: "SAP Anthropic", type: "claude", url: "http://127.0.0.1:8899/v1", model: "anthropic--claude-4.8-opus")
        _ = createRosterEntity(name: "SAP Gemini", type: "gemini", url: "https://generativelanguage.googleapis.com/v1beta", model: "gemini-2.5-flash")
        _ = createRosterEntity(name: "SAP OpenAI", type: "chatgpt", url: "http://127.0.0.1:9988/openai/v1", model: "qwen3.8-27b-dev-preview")
        _ = cpa
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

// Preset Provider template used for populating the add menu
struct ProviderPresetItem: Identifiable {
    var id: String { name }
    let name: String
    let type: String
    let defaultURL: String
    let defaultModel: String
    let subtitle: String
    let models: [ServiceModelRow]
}

// MARK: - Native Edit / Add Sheet (Scheme A - Perfectly Aligned)

struct ProviderEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext

    let service: APIServiceEntity?
    let initialPreset: ProviderPresetItem?
    let onSave: () -> Void
    let onDelete: () -> Void

    @State private var nameText = ""
    @State private var urlText = ""
    @State private var typeText = "chatgpt"
    @State private var apiKeyText = ""
    @State private var isDefault = false
    @State private var modelsList: [ServiceModelRow] = []
    @State private var activeModelID = ""
    @State private var isShowingAPIKey = false

    // Add custom model alert
    @State private var showingAddModelSheet = false
    @State private var newModelInput = ""

    // Model fetching
    @State private var isFetchingModels = false
    @State private var fetchError: String?
    @State private var showingModelSelectionSheet = false
    @State private var fetchedCandidateModels: [AIModel] = []
    @State private var selectedModelIDsForImport: Set<String> = []
    @State private var modelSearchQuery = ""

    var isEditing: Bool { service != nil }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isEditing ? (nameText.isEmpty ? "Edit Provider" : nameText) : "Add AI Provider")
                        .font(.headline)
                        .foregroundStyle(Color.primary)

                    Text("Configure endpoint connection parameters and models.")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Done") {
                    saveChanges()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            // Scrollable Content
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Group 1: Connection Details
                    GroupBox("Connection Details") {
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                            GridRow {
                                Text("Provider Name")
                                    .font(.subheadline)
                                    .foregroundStyle(Color.secondary)
                                    .frame(width: 110, alignment: .trailing)

                                TextField("", text: $nameText, prompt: Text("e.g. OpenAI, Anthropic"))
                                    .textFieldStyle(.roundedBorder)
                            }

                            GridRow {
                                Text("API Base URL")
                                    .font(.subheadline)
                                    .foregroundStyle(Color.secondary)
                                    .frame(width: 110, alignment: .trailing)

                                VStack(alignment: .leading, spacing: 3) {
                                    TextField("", text: $urlText, prompt: Text("http://127.0.0.1:8899/v1"))
                                        .textFieldStyle(.roundedBorder)

                                    Text("Do not include /chat/completions in the URL")
                                        .font(.caption2)
                                        .foregroundStyle(Color.secondary)
                                }
                            }

                            GridRow {
                                Text("Wire API")
                                    .font(.subheadline)
                                    .foregroundStyle(Color.secondary)
                                    .frame(width: 110, alignment: .trailing)

                                Picker("", selection: $typeText) {
                                    Text("Chat Completions (OpenAI Compatible)").tag("chatgpt")
                                    Text("Responses (OpenAI)").tag("openai-responses")
                                    Text("Anthropic Messages").tag("claude")
                                    Text("Google Gemini").tag("gemini")
                                    Text("Ollama").tag("ollama")
                                    Text("OpenRouter").tag("openrouter")
                                    Text("DeepSeek").tag("deepseek")
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                            }

                            GridRow {
                                Text("API Key")
                                    .font(.subheadline)
                                    .foregroundStyle(Color.secondary)
                                    .frame(width: 110, alignment: .trailing)

                                HStack(spacing: 6) {
                                    if isShowingAPIKey {
                                        TextField("", text: $apiKeyText, prompt: Text("API Key / Token"))
                                            .textFieldStyle(.roundedBorder)
                                    } else {
                                        SecureField("", text: $apiKeyText, prompt: Text("API Key / Token"))
                                            .textFieldStyle(.roundedBorder)
                                    }

                                    Button(action: { isShowingAPIKey.toggle() }) {
                                        Image(systemName: isShowingAPIKey ? "eye.slash" : "eye")
                                            .font(.system(size: 12))
                                            .foregroundStyle(Color.secondary)
                                            .frame(width: 20)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }

                            GridRow {
                                Text("Default")
                                    .font(.subheadline)
                                    .foregroundStyle(Color.secondary)
                                    .frame(width: 110, alignment: .trailing)

                                VStack(alignment: .leading, spacing: 2) {
                                    Toggle("Use as default for new conversations", isOn: $isDefault)
                                        .toggleStyle(.checkbox)

                                    Text("Automatically selected when starting a new chat if no specific assistant is chosen.")
                                        .font(.caption2)
                                        .foregroundStyle(Color.secondary)
                                }
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // Group 2: Models Management
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            // Toolbar
                            HStack {
                                Text("Configured Models (\(modelsList.count))")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color.primary)

                                Spacer()

                                Button(action: { showingAddModelSheet = true }) {
                                    Label("Add Model", systemImage: "plus")
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
                                        Text("Fetch from API")
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

                            Divider()

                            // Models List
                            if modelsList.isEmpty {
                                Text("No models added. Click 'Fetch from API' or 'Add Model'.")
                                    .font(.subheadline)
                                    .foregroundStyle(Color.secondary)
                                    .padding(.vertical, 16)
                                    .frame(maxWidth: .infinity, alignment: .center)
                            } else {
                                ScrollView {
                                    LazyVStack(spacing: 2) {
                                        ForEach(modelsList, id: \.id) { m in
                                            let isActive = activeModelID == m.modelID
                                            HStack(spacing: 10) {
                                                Button(action: {
                                                    activeModelID = m.modelID
                                                }) {
                                                    Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                                                        .font(.system(size: 14))
                                                        .foregroundStyle(isActive ? Color.accentColor : Color.secondary.opacity(0.4))
                                                }
                                                .buttonStyle(.plain)
                                                .help(isActive ? "Active model for this provider" : "Click to set as active model")

                                                Text(m.modelID)
                                                    .font(.system(size: 12, design: .monospaced))
                                                    .foregroundStyle(Color.primary)

                                                Spacer()

                                                if isActive {
                                                    Text("Active")
                                                        .font(.caption2)
                                                        .padding(.horizontal, 6)
                                                        .padding(.vertical, 2)
                                                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                                                        .foregroundStyle(Color.accentColor)
                                                }

                                                Button(action: {
                                                    deleteModel(m.id)
                                                }) {
                                                    Image(systemName: "trash")
                                                        .font(.system(size: 11))
                                                        .foregroundStyle(Color.secondary.opacity(0.8))
                                                }
                                                .buttonStyle(.plain)
                                            }
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 5)
                                            .background(
                                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                    .fill(isActive ? Color.accentColor.opacity(0.08) : Color.clear)
                                            )
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                                .frame(height: 140)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(Color(NSColor.textBackgroundColor))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                .strokeBorder(Color(NSColor.separatorColor), lineWidth: 0.5)
                                        )
                                )
                            }

                            // Presets
                            let presets = recommendedModels(for: typeText)
                            if !presets.isEmpty {
                                Divider()

                                HStack(alignment: .center, spacing: 8) {
                                    Text("Popular:")
                                        .font(.caption)
                                        .foregroundStyle(Color.secondary)

                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 6) {
                                            ForEach(presets, id: \.self) { preset in
                                                Button(action: {
                                                    if !modelsList.contains(where: { $0.modelID == preset }) {
                                                        modelsList.append(ServiceModelRow(nickname: "", modelID: preset))
                                                        if activeModelID.isEmpty { activeModelID = preset }
                                                    }
                                                }) {
                                                    Text("+ \(preset)")
                                                        .font(.system(size: 11, design: .monospaced))
                                                        .padding(.horizontal, 6)
                                                        .padding(.vertical, 2)
                                                        .background(Capsule().fill(Color(NSColor.controlBackgroundColor)))
                                                        .foregroundStyle(Color.secondary)
                                                }
                                                .buttonStyle(.plain)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Text("Models")
                            .font(.headline)
                    }
                }
                .padding(20)
            }

            // Bottom Footer
            if isEditing {
                Divider()
                HStack {
                    Button(role: .destructive, action: {
                        onDelete()
                        dismiss()
                    }) {
                        Label("Delete Provider", systemImage: "trash")
                            .foregroundStyle(Color.red)
                    }
                    .buttonStyle(.borderless)

                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            }
        }
        .frame(width: 580, height: 560)
        .onAppear {
            loadInitialData()
        }
        .sheet(isPresented: $showingAddModelSheet) {
            addCustomModelSheet
        }
        .sheet(isPresented: $showingModelSelectionSheet) {
            modelSelectionSheetView
        }
    }

    // MARK: - Add Model Sheet

    private var addCustomModelSheet: some View {
        VStack(spacing: 14) {
            Text("Add Custom Model")
                .font(.headline)

            TextField("e.g. gpt-4o, claude-3-5-sonnet", text: $newModelInput)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 280)

            HStack(spacing: 12) {
                Button("Cancel") {
                    newModelInput = ""
                    showingAddModelSheet = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Add") {
                    let trimmed = newModelInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty && !modelsList.contains(where: { $0.modelID == trimmed }) {
                        modelsList.append(ServiceModelRow(nickname: "", modelID: trimmed))
                        if activeModelID.isEmpty { activeModelID = trimmed }
                    }
                    newModelInput = ""
                    showingAddModelSheet = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(newModelInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 340)
    }

    // MARK: - Save / Load

    private func loadInitialData() {
        if let service = service {
            nameText = service.name ?? ""
            urlText = service.url?.absoluteString ?? ""
            typeText = service.type ?? "chatgpt"
            activeModelID = service.model ?? ""
            isDefault = service.isDefault

            if let id = service.id {
                apiKeyText = (try? TokenManager.getToken(for: id.uuidString)) ?? ""
                let key = "service_models_\(id.uuidString)"
                if let data = UserDefaults.standard.string(forKey: key)?.data(using: .utf8),
                   let list = try? JSONDecoder().decode([ServiceModelRow].self, from: data) {
                    // Sanitize away any legacy "optional" nickname placeholder values
                    self.modelsList = list.map { ServiceModelRow(id: $0.id, nickname: ($0.nickname == "optional" ? "" : $0.nickname), modelID: $0.modelID) }
                }
            }
        } else if let preset = initialPreset {
            nameText = preset.name
            urlText = preset.defaultURL
            typeText = preset.type
            activeModelID = preset.defaultModel
            modelsList = preset.models.map { ServiceModelRow(id: $0.id, nickname: "", modelID: $0.modelID) }
            apiKeyText = ProcessInfo.processInfo.environment["LOCAL_SAP_AI_CORE_PROXY_KEY"] ?? ""
        }
    }

    private func saveChanges() {
        let targetService: APIServiceEntity
        if let existing = service {
            targetService = existing
        } else {
            let manager = APIServiceManager(viewContext: viewContext)
            targetService = manager.createAPIService(
                name: nameText,
                type: typeText,
                url: URL(string: urlText) ?? URL(fileURLWithPath: ""),
                model: activeModelID,
                contextSize: 20,
                useStreamResponse: true,
                generateChatNames: true
            )
        }

        targetService.name = nameText
        targetService.url = URL(string: urlText)
        targetService.type = typeText
        targetService.model = activeModelID.isEmpty ? (modelsList.first?.modelID ?? "") : activeModelID

        if isDefault {
            let fetchReq: NSFetchRequest<APIServiceEntity> = APIServiceEntity.fetchRequest()
            if let all = try? viewContext.fetch(fetchReq) {
                for s in all {
                    s.isDefault = (s.objectID == targetService.objectID)
                }
            }
            targetService.isDefault = true
        } else {
            targetService.isDefault = false
        }

        if let id = targetService.id {
            try? TokenManager.setToken(apiKeyText, for: id.uuidString)
            let key = "service_models_\(id.uuidString)"
            if let data = try? JSONEncoder().encode(modelsList),
               let str = String(data: data, encoding: .utf8) {
                UserDefaults.standard.set(str, forKey: key)
            }
        }

        onSave()
    }

    private func deleteModel(_ id: String) {
        modelsList.removeAll { $0.id == id }
        if !modelsList.contains(where: { $0.modelID == activeModelID }), let next = modelsList.first {
            activeModelID = next.modelID
        }
    }

    // MARK: - Fetch Models from API

    private func fetchModelsFromAPI() {
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
                modelsList.append(ServiceModelRow(nickname: "", modelID: mid))
            }
        }
        if activeModelID.isEmpty, let first = modelsList.first {
            activeModelID = first.modelID
        }
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
}
