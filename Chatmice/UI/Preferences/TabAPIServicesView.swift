//
//  TabAPIServicesView.swift
//  Chatmice
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
    @State private var addSheetRequest: ProviderAddSheetRequest?

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
                        Button("OpenAI") {
                            presentAddSheet(preset: ProviderPresetItem(
                                name: "OpenAI", type: "openai-responses", defaultURL: "https://api.openai.com/v1", defaultModel: "gpt-4o",
                                subtitle: "Official OpenAI API"
                            ))
                        }
                        Button("Anthropic") {
                            presentAddSheet(preset: ProviderPresetItem(
                                name: "Anthropic", type: "claude", defaultURL: "https://api.anthropic.com/v1", defaultModel: "claude-3-5-sonnet-latest",
                                subtitle: "Official Anthropic API"
                            ))
                        }
                        Button("Google AI") {
                            presentAddSheet(preset: ProviderPresetItem(
                                name: "Google AI", type: "gemini", defaultURL: "https://generativelanguage.googleapis.com/v1beta", defaultModel: "gemini-2.5-flash",
                                subtitle: "Google Gemini API"
                            ))
                        }
                        Button("DeepSeek") {
                            presentAddSheet(preset: ProviderPresetItem(
                                name: "DeepSeek", type: "deepseek", defaultURL: "https://api.deepseek.com/v1", defaultModel: "deepseek-chat",
                                subtitle: "DeepSeek Official API"
                            ))
                        }
                        Button("xAI") {
                            presentAddSheet(preset: ProviderPresetItem(
                                name: "xAI", type: "xai", defaultURL: "https://api.x.ai/v1", defaultModel: "grok-4",
                                subtitle: "Official xAI API"
                            ))
                        }
                        Button("Ollama") {
                            presentAddSheet(preset: ProviderPresetItem(
                                name: "Ollama", type: "ollama", defaultURL: "http://localhost:11434/api/chat", defaultModel: "llama3.1",
                                subtitle: "Local Ollama server"
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
        .sheet(item: $addSheetRequest) { request in
            ProviderEditorSheet(
                service: nil,
                initialPreset: request.preset,
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
                ProviderBrandIcon(name: service.name ?? "", type: service.type ?? "")
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(service.name ?? "Provider")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.primary)
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
        addSheetRequest = ProviderAddSheetRequest(preset: preset)
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
        let openAI = createRosterEntity(
            name: "OpenAI", type: "openai-responses", url: "https://api.openai.com/v1", model: "gpt-4o",
            isDefault: true,
            models: []
        )
        _ = createRosterEntity(name: "SAP Anthropic", type: "claude", url: "http://127.0.0.1:8899/v1", model: "anthropic--claude-4.8-opus", models: [])
        _ = createRosterEntity(name: "SAP Gemini", type: "gemini", url: "https://generativelanguage.googleapis.com/v1beta", model: "gemini-2.5-flash", models: [])
        _ = createRosterEntity(name: "SAP OpenAI", type: "chatgpt", url: "http://127.0.0.1:9988/openai/v1", model: "qwen3.8-27b-dev-preview", models: [])
        _ = openAI
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

}

private struct ProviderAddSheetRequest: Identifiable {
    let id = UUID()
    let preset: ProviderPresetItem?
}

// Preset Provider template used for populating the add menu
struct ProviderPresetItem: Identifiable {
    var id: String { name }
    let name: String
    let type: String
    let defaultURL: String
    let defaultModel: String
    let subtitle: String
}

struct ModelTrashButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "trash")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isHovered ? Color.red : Color.secondary)
                .padding(4)
                .background(
                    Circle()
                        .fill(isHovered ? Color.red.opacity(0.15) : Color.clear)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .help("Remove model")
    }
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
    @State private var modelsList: [ServiceModelRow] = []
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
    @State private var showingCapabilityTestSheet = false
    @State private var selectedModelIDsForTest: Set<String> = []
    @State private var capabilityResults: [String: ModelCapabilityTestResult] = [:]
    @State private var capabilityTestErrors: [String: String] = [:]
    @State private var currentlyTestingModel: String?
    @State private var isTestingCapabilities = false

    var isEditing: Bool { service != nil }

    private var apiBaseURLPrompt: String {
        switch typeText {
        case "claude":
            return "https://api.anthropic.com/v1"
        case "gemini":
            return "https://generativelanguage.googleapis.com/v1beta"
        case "ollama":
            return "http://localhost:11434/v1"
        case "openrouter":
            return "https://openrouter.ai/api/v1"
        case "deepseek":
            return "https://api.deepseek.com/v1"
        case "xai":
            return "https://api.x.ai/v1"
        default:
            return "https://api.openai.com/v1"
        }
    }

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
                                    TextField("", text: $urlText, prompt: Text(apiBaseURLPrompt))
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
                                    Text("xAI (OpenAI Compatible)").tag("xai")
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

                                Button(role: .destructive, action: {
                                    modelsList.removeAll()
                                }) {
                                    HStack(spacing: 3) {
                                        Image(systemName: "trash")
                                        Text("Remove All")
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(modelsList.isEmpty)
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
                                            HStack(spacing: 10) {
                                                Image(systemName: "cpu")
                                                    .font(.system(size: 12))
                                                    .foregroundStyle(Color.secondary)

                                                Text(m.modelID)
                                                    .font(.system(size: 12, design: .monospaced))
                                                    .foregroundStyle(Color.primary)

                                                Spacer()

                                                if let result = capabilityResults[m.modelID] {
                                                    Image(systemName: result.connectionSucceeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                                                        .foregroundStyle(result.connectionSucceeded ? Color.green : Color.red)
                                                        .help(result.connectionSucceeded ? "Connection test passed" : (result.errorMessage ?? "Connection test failed"))

                                                    if result.visionSupported == true {
                                                        Image(systemName: "eye.fill")
                                                            .foregroundStyle(Color.blue)
                                                            .help("Vision support verified")
                                                    }

                                                    if result.reasoningSupported == true {
                                                        Image(systemName: "brain.head.profile")
                                                            .foregroundStyle(Color.purple)
                                                            .help("Thinking support verified")
                                                    }
                                                }

                                                ModelTrashButton(action: {
                                                    deleteModel(m.id)
                                                })
                                            }
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6)
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
                            HStack(spacing: 8) {
                                if let currentlyTestingModel {
                                    ProgressView()
                                        .controlSize(.mini)
                                    Text("Testing \(currentlyTestingModel)…")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer()

                                Button(action: openCapabilityTestSheet) {
                                    Label("Test Connection", systemImage: "wave.3.right")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(
                                    modelsList.isEmpty
                                        || urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                )
                            }

                            // Presets
                            let presets = recommendedModels(for: typeText)
                            if !presets.isEmpty {
                                Divider()

                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Popular")
                                        .font(.caption)
                                        .foregroundStyle(Color.secondary)

                                    ModelPresetFlowLayout(spacing: 6) {
                                        ForEach(presets, id: \.self) { preset in
                                            Button(action: {
                                                if !modelsList.contains(where: { $0.modelID == preset }) {
                                                    modelsList.append(ServiceModelRow(nickname: "", modelID: preset))
                                                }
                                            }) {
                                                Text("+ \(preset)")
                                                    .font(.system(size: 11, design: .monospaced))
                                                    .padding(.horizontal, 7)
                                                    .padding(.vertical, 3)
                                                    .background(Capsule().fill(Color(NSColor.controlBackgroundColor)))
                                                    .foregroundStyle(Color.secondary)
                                            }
                                            .buttonStyle(.plain)
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
        .sheet(isPresented: $showingCapabilityTestSheet) {
            capabilityTestSheet
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

    private var capabilityTestSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Test Models")
                    .font(.headline)
                Text("Each selected model receives a connection request, a one-pixel image, and a thinking request.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Select All") {
                    selectedModelIDsForTest = Set(modelsList.map(\.modelID))
                }
                .buttonStyle(.plain)
                .disabled(isTestingCapabilities)

                Button("Deselect All") {
                    selectedModelIDsForTest.removeAll()
                }
                .buttonStyle(.plain)
                .disabled(isTestingCapabilities)

                Spacer()

                Text("\(selectedModelIDsForTest.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(modelsList, id: \.id) { model in
                        Button {
                            guard !isTestingCapabilities else { return }
                            if selectedModelIDsForTest.contains(model.modelID) {
                                selectedModelIDsForTest.remove(model.modelID)
                            } else {
                                selectedModelIDsForTest.insert(model.modelID)
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: selectedModelIDsForTest.contains(model.modelID) ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(selectedModelIDsForTest.contains(model.modelID) ? Color.accentColor : Color.secondary)

                                Text(model.modelID)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(Color.primary)

                                Spacer()

                                if currentlyTestingModel == model.modelID {
                                    ProgressView()
                                        .controlSize(.mini)
                                } else if let result = capabilityResults[model.modelID] {
                                    capabilityResultLabel(result)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if let error = capabilityTestErrors[model.modelID] {
                            Text(error)
                                .font(.caption2)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 36)
                        }
                    }
                }
            }
            .frame(height: 300)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.textBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(NSColor.separatorColor), lineWidth: 0.5))
            )

            HStack {
                Button("Close") {
                    showingCapabilityTestSheet = false
                }
                .disabled(isTestingCapabilities)

                Spacer()

                Button("Test Selected (\(selectedModelIDsForTest.count))") {
                    testSelectedModels()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isTestingCapabilities || selectedModelIDsForTest.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560, height: 460)
    }

    @ViewBuilder
    private func capabilityResultLabel(_ result: ModelCapabilityTestResult) -> some View {
        if result.connectionSucceeded {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.green)
                    .help("Connection successful")
                Image(systemName: result.visionSupported == true ? "eye.fill" : "eye.slash")
                    .foregroundStyle(result.visionSupported == true ? Color.blue : Color.secondary)
                    .help(result.visionSupported == true ? "Vision supported" : "Vision not supported")
                Image(systemName: "brain.head.profile")
                    .foregroundStyle(result.reasoningSupported == true ? Color.purple : Color.secondary.opacity(0.35))
                    .help(result.reasoningSupported == true ? "Thinking supported" : "Thinking not supported")
            }
        } else {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(Color.red)
                .help(result.errorMessage ?? "Connection failed")
        }
    }

    private func openCapabilityTestSheet() {
        selectedModelIDsForTest = Set(modelsList.map(\.modelID))
        capabilityTestErrors.removeAll()
        showingCapabilityTestSheet = true
    }

    private func testSelectedModels() {
        let selectedModels = modelsList.map(\.modelID).filter { selectedModelIDsForTest.contains($0) }
        guard !selectedModels.isEmpty else { return }

        isTestingCapabilities = true
        capabilityTestErrors.removeAll()
        let effectiveKey = apiKeyText.isEmpty
            ? (ProcessInfo.processInfo.environment["LOCAL_SAP_AI_CORE_PROXY_KEY"] ?? "")
            : apiKeyText

        Task {
            for modelID in selectedModels {
                await MainActor.run { currentlyTestingModel = modelID }
                let config = APIServiceConfig(
                    name: nameText,
                    apiUrl: URL(string: urlText) ?? URL(fileURLWithPath: ""),
                    apiKey: effectiveKey,
                    model: modelID,
                    type: typeText
                )
                let result = await ModelCapabilityProbe.test(config: config, modelID: modelID)
                await MainActor.run {
                    capabilityResults[modelID] = result
                    if let error = result.errorMessage {
                        capabilityTestErrors[modelID] = error
                    }
                    persistCapabilityResultsIfPossible()
                }
            }
            await MainActor.run {
                currentlyTestingModel = nil
                isTestingCapabilities = false
            }
        }
    }

    private func persistCapabilityResultsIfPossible() {
        guard let serviceID = service?.id else { return }
        ModelCapabilityTestStore.save(capabilityResults, for: serviceID)
    }

    // MARK: - Save / Load

    private func loadInitialData() {
        if let service = service {
            nameText = service.name ?? ""
            urlText = service.url?.absoluteString ?? ""
            typeText = service.type ?? "chatgpt"

            if let id = service.id {
                apiKeyText = (try? TokenManager.getToken(for: id.uuidString)) ?? ""
                capabilityResults = ModelCapabilityTestStore.results(for: id)
                let key = "service_models_\(id.uuidString)"
                if let data = UserDefaults.standard.string(forKey: key)?.data(using: .utf8),
                   let list = try? JSONDecoder().decode([ServiceModelRow].self, from: data) {
                    modelsList = list.map {
                        ServiceModelRow(id: $0.id, nickname: $0.nickname == "optional" ? "" : $0.nickname, modelID: $0.modelID)
                    }
                }
            }
            return
        }

        let defaultType = initialPreset?.type ?? AppConstants.defaultApiType
        let defaultConfiguration = AppConstants.defaultApiConfigurations[defaultType]
        nameText = initialPreset?.name ?? defaultConfiguration?.name ?? "Custom Provider"
        urlText = initialPreset?.defaultURL ?? defaultConfiguration?.url ?? ""
        typeText = defaultType
        let defaultModel = initialPreset?.defaultModel ?? defaultConfiguration?.defaultModel ?? ""
        modelsList = defaultModel.isEmpty ? [] : [ServiceModelRow(nickname: "", modelID: defaultModel)]
        apiKeyText = ProcessInfo.processInfo.environment["LOCAL_SAP_AI_CORE_PROXY_KEY"] ?? ""
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
                model: modelsList.first?.modelID ?? "",
                contextSize: 20,
                useStreamResponse: true,
                generateChatNames: true
            )
        }

        targetService.name = nameText
        targetService.url = URL(string: urlText)
        targetService.type = typeText
        targetService.model = modelsList.first?.modelID ?? ""
        if let id = targetService.id {
            let credentialIdentifier = id.uuidString
            targetService.tokenIdentifier = credentialIdentifier
            try? TokenManager.setToken(apiKeyText, for: credentialIdentifier)
            let key = "service_models_\(credentialIdentifier)"
            if let data = try? JSONEncoder().encode(modelsList),
               let str = String(data: data, encoding: .utf8) {
                UserDefaults.standard.set(str, forKey: key)
            }
            ModelCapabilityTestStore.save(capabilityResults, for: id)
        }

        onSave()
    }

    private func deleteModel(_ id: String) {
        modelsList.removeAll { $0.id == id }
    }

    // MARK: - Fetch Models from API

    private func fetchModelsFromAPI() {
        let config = APIServiceConfig(
            name: nameText,
            apiUrl: URL(string: urlText) ?? URL(fileURLWithPath: ""),
            apiKey: apiKeyText,
            model: modelsList.first?.modelID ?? "",
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
        .onChange(of: modelSearchQuery) { _, newQuery in
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
    }

    private func recommendedModels(for type: String) -> [String] {
        switch type {
        case "chatgpt":
            return ["gpt-4o", "gpt-4o-mini", "o3", "o3-mini"]
        case "openai-responses":
            return ["gpt-4o", "gpt-4o-mini", "o1", "o3-mini"]
        case "claude":
            return ["claude-sonnet-4-5", "claude-haiku-4-5", "claude-opus-4-1"]
        case "gemini":
            return ["gemini-2.5-flash", "gemini-2.5-pro"]
        case "deepseek":
            return ["deepseek-chat", "deepseek-reasoner"]
        case "xai":
            return ["grok-4", "grok-3", "grok-3-mini"]
        case "ollama":
            return ["llama3.1", "qwen2.5:7b", "mistral"]
        default:
            return ["gpt-4o", "claude-3-5-sonnet-latest"]
        }
    }
}

private struct ModelPresetFlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var position = CGPoint.zero
        var rowHeight: CGFloat = 0
        var contentWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let nextX = position.x == 0 ? 0 : position.x + spacing
            if nextX + size.width > maxWidth, position.x > 0 {
                position.x = 0
                position.y += rowHeight + spacing
                rowHeight = 0
            } else {
                position.x = nextX
            }
            contentWidth = max(contentWidth, position.x + size.width)
            position.x += size.width
            rowHeight = max(rowHeight, size.height)
        }

        return CGSize(
            width: proposal.width ?? contentWidth,
            height: subviews.isEmpty ? 0 : position.y + rowHeight
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var position = CGPoint(x: bounds.minX, y: bounds.minY)
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let nextX = position.x == bounds.minX ? bounds.minX : position.x + spacing
            if nextX + size.width > bounds.maxX, position.x > bounds.minX {
                position.x = bounds.minX
                position.y += rowHeight + spacing
                rowHeight = 0
            } else {
                position.x = nextX
            }
            subview.place(at: position, proposal: ProposedViewSize(size))
            position.x += size.width
            rowHeight = max(rowHeight, size.height)
        }
    }
}
