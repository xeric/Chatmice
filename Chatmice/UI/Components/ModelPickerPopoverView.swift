//
//  ModelPickerPopoverView.swift
//  Chatmice
//
//  Interactive Provider & Model picker popover matching Reference Image #2:
//  - Search bar + All / Favorites filter chips
//  - Grouped by Provider with brand icons
//  - Model row with active checkmark, favorite star, vision eye icon, reasoning brain icon
//  - 1-click synchronous switch of both Provider and Model
//

import AppKit
import CoreData
import SwiftUI

struct ProviderBrandIcon: View {
    let name: String
    let type: String

    private var identifier: String {
        "\(name) \(type)".lowercased()
    }

    var body: some View {
        if identifier.contains("anthropic") || identifier.contains("claude") {
            brandImage("logo_claude", color: Color(red: 0.94, green: 0.42, blue: 0.16))
        }
        else if identifier.contains("gemini") || identifier.contains("google") {
            brandImage("logo_gemini", color: Color(red: 0.20, green: 0.76, blue: 0.42))
        }
        else if identifier.contains("openai") || identifier.contains("chatgpt") || identifier.contains("gpt") {
            brandImage("logo_openai-responses", color: Color(red: 0.18, green: 0.55, blue: 0.96))
        }
        else if identifier.contains("deepseek") {
            Image(systemName: "bolt.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color.cyan)
        }
        else if identifier.contains("ollama") {
            Image(systemName: "terminal.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color.purple)
        }
        else {
            Image(systemName: "network")
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color.accentColor)
        }
    }

    private func brandImage(_ name: String, color: Color) -> some View {
        Image(name)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .foregroundStyle(color)
    }
}

struct ModelPickerPopoverView: View {
    let apiServices: [APIServiceEntity]
    let selectedChat: ChatEntity?
    let onSelect: (APIServiceEntity, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var testedCapabilitiesByService: [UUID: [String: ModelCapabilityTestResult]] = [:]
    @Environment(\.openWindow) private var openWindow

    @State private var searchQuery = ""
    @State private var filterMode: FilterMode = .all
    @AppStorage("favoriteModelIDsJSON") private var favoriteModelIDsJSON: String = "[]"
    @State private var favorites: Set<String> = []

    enum FilterMode {
        case all
        case favorites
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top Search & Filter Bar
            HStack(spacing: 8) {
                // Search field
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.45))

                    TextField("Search models", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white)

                    if !searchQuery.isEmpty {
                        Button(action: { searchQuery = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.white.opacity(0.4))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(red: 0.18, green: 0.18, blue: 0.20))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                        )
                )

                // Filter chips: All / Favorites
                HStack(spacing: 2) {
                    filterChip("All", mode: .all)
                    filterChip("Favorites", mode: .favorites)
                }
                .padding(2)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(red: 0.18, green: 0.18, blue: 0.20))
                )

                Button {
                    UserDefaults.standard.set(SettingsPage.providers.rawValue, forKey: "requestedSettingsPage")
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(
                            name: NSNotification.Name("OpenSettingsPage"),
                            object: SettingsPage.providers.rawValue
                        )
                    }
                    dismiss()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.white.opacity(0.65))
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(red: 0.18, green: 0.18, blue: 0.20))
                )
                .help("Configure Models and Providers")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(red: 0.14, green: 0.14, blue: 0.15))

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)

            // Scrollable grouped models list
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(apiServices, id: \.objectID) { service in
                        let models = modelsForService(service)
                        if !models.isEmpty {
                            providerSection(service: service, models: models)
                        }
                    }
                }
                .padding(.leading, 8)
                .padding(.trailing, 8)
                .padding(.vertical, 8)
            }
            .frame(height: 380)
        }
        .frame(width: 320)
        .background(Color(red: 0.14, green: 0.14, blue: 0.15))
        .onAppear {
            loadFavorites()
            testedCapabilitiesByService = Dictionary(uniqueKeysWithValues: apiServices.compactMap { service in
                guard let id = service.id else { return nil }
                return (id, ModelCapabilityTestStore.results(for: id))
            })
        }
    }

    private func filterChip(_ title: String, mode: FilterMode) -> some View {
        Button(action: { filterMode = mode }) {
            Text(title)
                .font(.system(size: 11, weight: filterMode == mode ? .semibold : .regular))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(filterMode == mode ? Color.white.opacity(0.15) : Color.clear)
                )
                .foregroundStyle(filterMode == mode ? Color.white : Color.white.opacity(0.6))
        }
        .buttonStyle(.plain)
    }

    private func providerSection(service: APIServiceEntity, models: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // Section Header
            HStack(spacing: 6) {
                ProviderBrandIcon(name: service.name ?? "", type: service.type ?? "")
                    .frame(width: 13, height: 13)

                Text(service.name ?? "Provider")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.75))

                Spacer()

                Text("\(models.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.35))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)

            // Model Rows
            ForEach(models, id: \.self) { modelID in
                modelRow(service: service, modelID: modelID)
            }
        }
    }

    private func modelRow(service: APIServiceEntity, modelID: String) -> some View {
        let isSelected = selectedChat?.apiService == service && selectedChat?.gptModel == modelID
        let isFav = favorites.contains(modelID)
        let testedCapabilities = service.id.flatMap { testedCapabilitiesByService[$0]?[modelID] }
        let isVision = testedCapabilities?.visionSupported ?? isVisionModel(modelID)
        let isReasoning = testedCapabilities?.reasoningSupported ?? isReasoningModel(modelID)

        return Button(action: {
            onSelect(service, modelID)
        }) {
            HStack(spacing: 6) {
                // Model ID text
                Text(modelID)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.85))
                    .lineLimit(1)

                Spacer()

                // Active checkmark ✓
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.green)
                }

                // Favorite star ★
                Button(action: { toggleFavorite(modelID) }) {
                    Image(systemName: isFav ? "star.fill" : "star")
                        .font(.system(size: 10))
                        .foregroundStyle(isFav ? Color.orange : Color.white.opacity(0.25))
                }
                .buttonStyle(.plain)

                // Vision icon 👁
                if isVision {
                    Image(systemName: "eye.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.blue)
                        .help("Supports vision / image input")
                }

                // Reasoning brain icon 🧠
                if isReasoning {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.purple)
                        .help("Reasoning / thinking model")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func modelsForService(_ service: APIServiceEntity) -> [String] {
        var list: [String] = []

        // Load custom models from UserDefaults
        if let id = service.id {
            let key = "service_models_\(id.uuidString)"
            if let data = UserDefaults.standard.string(forKey: key)?.data(using: .utf8),
                let items = try? JSONDecoder().decode([ServiceModelRow].self, from: data)
            {
                list = items.map(\.modelID).filter { !$0.isEmpty }
            }
        }

        // Fallback to defaults
        if list.isEmpty {
            list = AppConstants.defaultApiConfigurations[service.type ?? ""]?.models ?? []
        }
        if list.isEmpty, let m = service.model, !m.isEmpty {
            list = [m]
        }

        // Apply search query
        if !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            let q = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
            list = list.filter { $0.lowercased().contains(q) }
        }

        // Apply Favorites filter
        if filterMode == .favorites {
            list = list.filter { favorites.contains($0) }
        }

        return list
    }

    private func isReasoningModel(_ id: String) -> Bool {
        let lower = id.lowercased()
        return lower.contains("o1") || lower.contains("o3") || lower.contains("r1") || lower.contains("reason")
            || lower.contains("luna") || lower.contains("think") || lower.contains("opus")
    }

    private func isVisionModel(_ id: String) -> Bool {
        let lower = id.lowercased()
        return lower.contains("4o") || lower.contains("vl") || lower.contains("vision") || lower.contains("gemini")
            || lower.contains("sonnet") || lower.contains("claude")
    }

    private func toggleFavorite(_ id: String) {
        if favorites.contains(id) {
            favorites.remove(id)
        }
        else {
            favorites.insert(id)
        }
        saveFavorites()
    }

    private func loadFavorites() {
        if let data = favoriteModelIDsJSON.data(using: .utf8),
            let arr = try? JSONDecoder().decode([String].self, from: data)
        {
            favorites = Set(arr)
        }
    }

    private func saveFavorites() {
        if let data = try? JSONEncoder().encode(Array(favorites)),
            let str = String(data: data, encoding: .utf8)
        {
            favoriteModelIDsJSON = str
        }
    }

}
