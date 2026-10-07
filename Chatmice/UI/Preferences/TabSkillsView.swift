//
//  TabSkillsView.swift
//  Chatmice
//
//  Settings tab for managing Agent Skills and Capabilities.
//

import AppKit
import SwiftUI

struct TabToolsView: View {
    @AppStorage("chatmiceToolsEnabled") private var toolsEnabled = true
    @AppStorage("chatmiceFileToolsEnabled") private var fileToolsEnabled = true
    @AppStorage("chatmiceBashEnabled") private var bashEnabled = true
    @AppStorage("chatmiceSkillsEnabled") private var skillsEnabled = true
    @AppStorage("chatmiceComputerEnabled") private var computerEnabled = false
    @AppStorage("chatmiceBashApprovalMode") private var bashApprovalMode = BashApprovalMode.alwaysAsk
    @Environment(\.scenePhase) private var scenePhase
    @State private var screenRecordingGranted = false
    @State private var accessibilityGranted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Agent Tools") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Enable Agent Tools", isOn: $toolsEnabled)
                        .toggleStyle(.switch)
                    Text(
                        "Allows the assistant to call enabled tools while answering. Turn this off to run every chat as model-only conversation."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("File Tool") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Enable File Tool", isOn: $fileToolsEnabled)
                        .toggleStyle(.switch)
                    Text(
                        "Lets the agent inspect files and folders you select, including reading file contents and listing directory entries."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(!toolsEnabled)

            GroupBox("Code Execution") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Enable Bash and Sandboxed Python", isOn: $bashEnabled)
                        .toggleStyle(.switch)
                    Text(
                        "Runs shell commands and isolated Python code for calculations, repository inspection, builds, and command-line tasks."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Divider()
                    Text("Execution Approval")
                        .font(.subheadline.weight(.medium))
                    Picker("Execution Approval", selection: $bashApprovalMode) {
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
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(!toolsEnabled)

            GroupBox("Computer Use") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Enable Screen, Mouse, and Keyboard Control", isOn: $computerEnabled)
                        .toggleStyle(.switch)
                        .disabled(!toolsEnabled)
                    Text("Lets the agent capture the screen and operate apps with mouse and keyboard events.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()

                    Text("System Permissions")
                        .font(.subheadline.weight(.medium))
                    permissionRow(
                        title: "Screen Recording",
                        detail: "Required to capture the contents of your displays.",
                        symbol: "rectangle.inset.filled.and.person.filled",
                        granted: screenRecordingGranted,
                        request: requestScreenRecording,
                        openSettings: ComputerUsePermissions.openScreenRecordingSettings
                    )
                    if !screenRecordingGranted {
                        Label(
                            "Restart Chatmice after granting Screen Recording access for the permission to take effect.",
                            systemImage: "arrow.clockwise"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 30)
                    }
                    permissionRow(
                        title: "Accessibility",
                        detail: "Required to control the mouse and keyboard.",
                        symbol: "accessibility",
                        granted: accessibilityGranted,
                        request: requestAccessibility,
                        openSettings: ComputerUsePermissions.openAccessibilitySettings
                    )

                    if !accessibilityGranted {
                        Divider()
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Manual Accessibility Setup")
                                .font(.subheadline.weight(.medium))
                            Text(
                                "If Chatmice does not appear automatically, open Accessibility settings and drag this app into the applications list."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            DraggableApplicationPermissionView()
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            DefaultToolListSettingsView(
                fileToolsEnabled: fileToolsEnabled,
                bashEnabled: bashEnabled,
                skillsEnabled: skillsEnabled,
                computerEnabled: computerEnabled
            )
        }
        .frame(minHeight: 340)
        .onAppear(perform: refreshPermissions)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshPermissions() }
        }
    }

    private func permissionRow(
        title: String,
        detail: String,
        symbol: String,
        granted: Bool,
        request: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .frame(width: 20)
                .foregroundStyle(granted ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label(
                granted ? "Granted" : "Required",
                systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(granted ? Color.green : Color.orange)
            if !granted {
                Button("Request Access", action: request)
                    .buttonStyle(.borderedProminent)
            }
            Button("Open Settings", action: openSettings)
                .buttonStyle(.bordered)
        }
        .controlSize(.small)
        .padding(.vertical, 2)
    }

    private func refreshPermissions() {
        screenRecordingGranted = ComputerUsePermissions.canRecordScreen
        accessibilityGranted = ComputerUsePermissions.canControlComputer
    }

    private func requestScreenRecording() {
        _ = ComputerUsePermissions.requestScreenRecording()
        refreshPermissions()
    }

    private func requestAccessibility() {
        _ = ComputerUsePermissions.requestAccessibility()
        refreshPermissions()
    }
}

private struct DraggableApplicationPermissionView: View {
    private let appName =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        ?? "Chatmice"

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.055))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        .foregroundStyle(Color.secondary.opacity(0.45))
                }

            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(appName)
                        .font(.callout.weight(.semibold))
                    Text("Drag into the Accessibility applications list")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)

            ApplicationBundleDragSource()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 62)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Drag \(appName) into the Accessibility applications list")
        .help("Drag this item into System Settings > Privacy & Security > Accessibility")
    }
}

private struct ApplicationBundleDragSource: NSViewRepresentable {
    func makeNSView(context: Context) -> ApplicationBundleDragSourceView {
        ApplicationBundleDragSourceView()
    }

    func updateNSView(_ nsView: ApplicationBundleDragSourceView, context: Context) {}
}

private final class ApplicationBundleDragSourceView: NSView, NSDraggingSource {
    private var initialMouseEvent: NSEvent?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        initialMouseEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let initialMouseEvent else { return }
        self.initialMouseEvent = nil

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(Bundle.main.bundleURL.absoluteString, forType: .fileURL)
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        let location = convert(initialMouseEvent.locationInWindow, from: nil)
        draggingItem.setDraggingFrame(
            NSRect(x: location.x - 24, y: location.y - 24, width: 48, height: 48),
            contents: icon
        )
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        initialMouseEvent = nil
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        true
    }
}

struct TabSkillsView: View {
    @AppStorage("chatmiceSkillsEnabled") private var skillsEnabled = true
    @State private var installedSkills: [SkillInfo] = []
    @State private var busySkillIDs: Set<String> = []
    @State private var errorMessage: String?
    @State private var storeItems = GitHubSkillCatalogItem.curated
    @State private var storeSearchText = ""
    @State private var storeFilter = SkillStoreFilter.all
    @AppStorage("selectedSkillsStore") private var selectedStoreID = SkillStoreSource.anthropic.id
    @State private var isLoadingStore = false
    private let installer = SkillMarketplaceInstaller()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Skill Runtime") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Toggle("Enable Agent Skills", isOn: $skillsEnabled)
                            .toggleStyle(.switch)
                        Spacer()
                        Button("Open Skills Folder") { openSkillsFolder() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    Text(
                        "Skills are SKILL.md instruction bundles loaded on demand by the agent. Disable individual skills without deleting their files."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(8)
            }

            GroupBox("Installed Skills (\(installedSkills.count))") {
                VStack(alignment: .leading, spacing: 0) {
                    if installedSkills.isEmpty {
                        ContentUnavailableView(
                            "No Skills Installed",
                            systemImage: "puzzlepiece.extension",
                            description: Text(
                                "Install a skill from the Store below or place a SKILL.md folder in the Chatmice skills directory."
                            )
                        )
                        .frame(maxWidth: .infinity, minHeight: 110)
                    }
                    else {
                        ForEach(installedSkills) { skill in
                            installedSkillRow(skill)
                            if skill.id != installedSkills.last?.id { Divider() }
                        }
                    }
                }
                .padding(8)
            }

            GroupBox("Skills Store") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Official Agent Skills")
                                .font(.subheadline.weight(.semibold))
                            Text("Choose a store, then search and install its complete skill bundles.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if isLoadingStore { ProgressView().controlSize(.small) }
                        Picker("Store", selection: $selectedStoreID) {
                            ForEach(SkillStoreSource.all) { source in
                                Text(source.name).tag(source.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(minWidth: 150)
                        Link("Browse Source", destination: selectedStore.sourceURL)
                            .font(.caption)
                    }

                    HStack(spacing: 10) {
                        HStack(spacing: 7) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                            TextField("Search skills by name or description", text: $storeSearchText)
                                .textFieldStyle(.plain)
                            if !storeSearchText.isEmpty {
                                Button {
                                    storeSearchText = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))

                        Picker("Filter", selection: $storeFilter) {
                            ForEach(SkillStoreFilter.allCases) { filter in
                                Text(filter.title).tag(filter)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 250)
                    }

                    if filteredStoreItems.isEmpty {
                        ContentUnavailableView.search(text: storeSearchText)
                            .frame(maxWidth: .infinity, minHeight: 120)
                    }
                    else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 10)], spacing: 10) {
                            ForEach(filteredStoreItems) { item in
                                storeCard(item)
                            }
                        }
                    }
                }
                .padding(8)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .task {
            await refreshSkills()
            await refreshStore()
        }
        .onChange(of: selectedStoreID) { _ in
            storeSearchText = ""
            storeItems = []
            Task { await refreshStore() }
        }
    }

    private var selectedStore: SkillStoreSource {
        SkillStoreSource.all.first { $0.id == selectedStoreID } ?? .anthropic
    }

    private var filteredStoreItems: [GitHubSkillCatalogItem] {
        let query = storeSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return storeItems.filter { item in
            let installed = installedSkills.contains { $0.directory.lastPathComponent == item.installationIdentifier }
            let matchesFilter: Bool
            switch storeFilter {
            case .all: matchesFilter = true
            case .installed: matchesFilter = installed
            case .available: matchesFilter = !installed
            }
            let matchesQuery =
                query.isEmpty || item.name.lowercased().contains(query)
                || item.description.lowercased().contains(query)
                || item.id.lowercased().contains(query)
            return matchesFilter && matchesQuery
        }
    }

    private func installedSkillRow(_ skill: SkillInfo) -> some View {
        let identifier = skill.directory.lastPathComponent
        let enabled = SkillEnablementStore.isEnabled(identifier)
        return HStack(spacing: 10) {
            Image(systemName: "puzzlepiece.extension.fill")
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(skill.name).font(.body.weight(.medium))
                Text(skill.description.isEmpty ? identifier : skill.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Toggle(
                "",
                isOn: Binding(
                    get: { enabled },
                    set: {
                        SkillEnablementStore.setEnabled($0, identifier: identifier)
                        Task { await refreshSkills() }
                    }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            Button(role: .destructive) {
                removeSkill(identifier)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(busySkillIDs.contains(identifier) || !isManaged(skill))
            .help(isManaged(skill) ? "Uninstall Skill" : "Legacy skills can be managed in Finder")
        }
        .padding(.vertical, 7)
    }

    private func storeCard(_ item: GitHubSkillCatalogItem) -> some View {
        let installed = installedSkills.contains { $0.directory.lastPathComponent == item.installationIdentifier }
        let busy = busySkillIDs.contains(item.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: item.symbol)
                    .foregroundStyle(Color.accentColor)
                Text(item.name)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(item.publisher)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(item.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Text(installed ? "Installed" : item.publisher)
                    .font(.caption2)
                    .foregroundStyle(installed ? Color.green : Color.secondary)
                Spacer()
                Button(installed ? "Update" : "Install") { installSkill(item) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(busy)
            }
        }
        .padding(11)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        }
    }

    private func installSkill(_ item: GitHubSkillCatalogItem) {
        busySkillIDs.insert(item.id)
        errorMessage = nil
        Task {
            do {
                try await installer.install(item)
                await refreshSkills()
            }
            catch {
                errorMessage = error.localizedDescription
            }
            busySkillIDs.remove(item.id)
        }
    }

    private func removeSkill(_ identifier: String) {
        busySkillIDs.insert(identifier)
        errorMessage = nil
        Task {
            do {
                try await installer.uninstall(identifier: identifier)
                SkillEnablementStore.setEnabled(true, identifier: identifier)
                await refreshSkills()
            }
            catch {
                errorMessage = error.localizedDescription
            }
            busySkillIDs.remove(identifier)
        }
    }

    @MainActor
    private func refreshSkills() async {
        installedSkills = await SkillStore().allSkills()
    }

    @MainActor
    private func refreshStore() async {
        isLoadingStore = true
        defer { isLoadingStore = false }
        do {
            storeItems = try await installer.catalog(source: selectedStore)
        }
        catch {
            if storeItems.isEmpty { errorMessage = error.localizedDescription }
        }
    }

    private func openSkillsFolder() {
        let directory = SkillMarketplaceInstaller.skillsDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directory.path)
    }

    private func isManaged(_ skill: SkillInfo) -> Bool {
        skill.directory.deletingLastPathComponent().standardizedFileURL
            == SkillMarketplaceInstaller.skillsDirectory.standardizedFileURL
    }
}

private enum SkillStoreFilter: String, CaseIterable, Identifiable {
    case all
    case installed
    case available

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

private struct SkillStoreSource: Identifiable, Sendable {
    let id: String
    let name: String
    let repository: String
    let branch: String
    let rootPath: String

    var sourceURL: URL { URL(string: "https://github.com/\(repository)")! }

    static let anthropic = Self(
        id: "anthropic",
        name: "Anthropic",
        repository: "anthropics/skills",
        branch: "main",
        rootPath: "skills"
    )
    static let all: [Self] = [
        anthropic,
        .init(
            id: "huggingface",
            name: "Hugging Face",
            repository: "huggingface/skills",
            branch: "main",
            rootPath: "skills"
        ),
        .init(id: "vercel", name: "Vercel", repository: "vercel-labs/agent-skills", branch: "main", rootPath: "skills"),
        .init(
            id: "superpowers",
            name: "Superpowers",
            repository: "obra/superpowers",
            branch: "main",
            rootPath: "skills"
        ),
    ]
}

private struct GitHubSkillCatalogItem: Identifiable, Sendable {
    let id: String
    let name: String
    let description: String
    let symbol: String
    let sourceID: String
    let publisher: String
    let repository: String
    let branch: String
    let path: String

    var installationIdentifier: String {
        sourceID == SkillStoreSource.anthropic.id ? id : "\(sourceID)--\(id)"
    }

    static let curated: [Self] = [
        .init(
            id: "academy-guide",
            name: "Academy Guide",
            description: "Build structured learning guides and educational material.",
            symbol: "graduationcap",
            sourceID: "anthropic",
            publisher: "Anthropic",
            repository: "anthropics/skills",
            branch: "main",
            path: "skills/academy-guide"
        ),
        .init(
            id: "algorithmic-art",
            name: "Algorithmic Art",
            description: "Create generative artwork with deterministic, reusable workflows.",
            symbol: "paintbrush.pointed",
            sourceID: "anthropic",
            publisher: "Anthropic",
            repository: "anthropics/skills",
            branch: "main",
            path: "skills/algorithmic-art"
        ),
        .init(
            id: "brand-guidelines",
            name: "Brand Guidelines",
            description: "Apply consistent brand colors, typography, and visual language.",
            symbol: "swatchpalette",
            sourceID: "anthropic",
            publisher: "Anthropic",
            repository: "anthropics/skills",
            branch: "main",
            path: "skills/brand-guidelines"
        ),
        .init(
            id: "canvas-design",
            name: "Canvas Design",
            description: "Create polished visual designs with bundled templates and fonts.",
            symbol: "rectangle.on.rectangle.angled",
            sourceID: "anthropic",
            publisher: "Anthropic",
            repository: "anthropics/skills",
            branch: "main",
            path: "skills/canvas-design"
        ),
    ]
}
private actor SkillMarketplaceInstaller {
    static var skillsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Chatmice/skills", isDirectory: true)
    }

    private struct GitHubEntry: Decodable, Sendable {
        let name: String
        let type: String
        let url: URL
        let downloadURL: URL?

        enum CodingKeys: String, CodingKey {
            case name, type, url
            case downloadURL = "download_url"
        }
    }

    enum InstallError: LocalizedError {
        case invalidResponse
        case invalidEntry(String)
        case missingManifest

        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "The Skills Store returned an invalid response."
            case .invalidEntry(let name): return "The skill bundle contains an invalid path: \(name)"
            case .missingManifest: return "The downloaded bundle does not contain SKILL.md."
            }
        }
    }

    func catalog(source: SkillStoreSource) async throws -> [GitHubSkillCatalogItem] {
        var components = URLComponents(
            string: "https://api.github.com/repos/\(source.repository)/contents/\(source.rootPath)"
        )!
        components.queryItems = [URLQueryItem(name: "ref", value: source.branch)]
        let entries = try await fetchEntries(from: components.url!)
        let directories = entries.filter { $0.type == "dir" }

        return await withTaskGroup(of: GitHubSkillCatalogItem?.self) { group in
            for entry in directories {
                group.addTask {
                    let manifestURL = URL(
                        string:
                            "https://raw.githubusercontent.com/\(source.repository)/\(source.branch)/\(source.rootPath)/\(entry.name)/SKILL.md"
                    )!
                    guard let (data, response) = try? await URLSession.shared.data(from: manifestURL),
                        let http = response as? HTTPURLResponse,
                        (200...299).contains(http.statusCode),
                        let raw = String(data: data, encoding: .utf8)
                    else { return nil }
                    let metadata = SkillStore.parseFrontmatter(raw).meta
                    let displayName =
                        metadata["name"]?.replacingOccurrences(of: "-", with: " ").capitalized
                        ?? entry.name.replacingOccurrences(of: "-", with: " ").capitalized
                    return GitHubSkillCatalogItem(
                        id: entry.name,
                        name: displayName,
                        description: metadata["description"] ?? "Agent Skill from the \(source.name) repository.",
                        symbol: "puzzlepiece.extension",
                        sourceID: source.id,
                        publisher: source.name,
                        repository: source.repository,
                        branch: source.branch,
                        path: "\(source.rootPath)/\(entry.name)"
                    )
                }
            }
            var items: [GitHubSkillCatalogItem] = []
            for await item in group {
                if let item { items.append(item) }
            }
            if items.isEmpty, source.id == SkillStoreSource.anthropic.id {
                return GitHubSkillCatalogItem.curated
            }
            return items.sorted { $0.name < $1.name }
        }
    }
    private func fetchEntries(from url: URL) async throws -> [GitHubEntry] {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Chatmice", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw InstallError.invalidResponse
        }
        return try JSONDecoder().decode([GitHubEntry].self, from: data)
    }

    func install(_ item: GitHubSkillCatalogItem) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Self.skillsDirectory, withIntermediateDirectories: true)
        let staging = Self.skillsDirectory.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        let destination = Self.skillsDirectory.appendingPathComponent(item.installationIdentifier, isDirectory: true)
        let backup = Self.skillsDirectory.appendingPathComponent(".backup-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        do {
            var components = URLComponents(
                string: "https://api.github.com/repos/\(item.repository)/contents/\(item.path)"
            )!
            components.queryItems = [URLQueryItem(name: "ref", value: item.branch)]
            try await downloadDirectory(apiURL: components.url!, destination: staging)
            guard fm.fileExists(atPath: staging.appendingPathComponent("SKILL.md").path) else {
                throw InstallError.missingManifest
            }
            if fm.fileExists(atPath: destination.path) {
                try fm.moveItem(at: destination, to: backup)
            }
            do {
                try fm.moveItem(at: staging, to: destination)
                try? fm.removeItem(at: backup)
            }
            catch {
                if fm.fileExists(atPath: backup.path) {
                    try? fm.moveItem(at: backup, to: destination)
                }
                throw error
            }
        }
        catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    func uninstall(identifier: String) throws {
        guard !identifier.isEmpty, !identifier.contains("/"), identifier != ".", identifier != ".." else {
            throw InstallError.invalidEntry(identifier)
        }
        let destination = Self.skillsDirectory.appendingPathComponent(identifier, isDirectory: true)
        guard destination.standardizedFileURL.deletingLastPathComponent() == Self.skillsDirectory.standardizedFileURL
        else {
            throw InstallError.invalidEntry(identifier)
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
    }

    private func downloadDirectory(apiURL: URL, destination: URL) async throws {
        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Chatmice", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw InstallError.invalidResponse
        }
        let entries = try JSONDecoder().decode([GitHubEntry].self, from: data)
        for entry in entries {
            guard !entry.name.isEmpty, !entry.name.contains("/"), entry.name != ".", entry.name != ".." else {
                throw InstallError.invalidEntry(entry.name)
            }
            let target = destination.appendingPathComponent(entry.name, isDirectory: entry.type == "dir")
            if entry.type == "dir" {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                try await downloadDirectory(apiURL: entry.url, destination: target)
            }
            else if entry.type == "file", let downloadURL = entry.downloadURL {
                let (fileData, fileResponse) = try await URLSession.shared.data(from: downloadURL)
                guard let http = fileResponse as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw InstallError.invalidResponse
                }
                try fileData.write(to: target, options: .atomic)
            }
        }
    }
}

private struct DefaultToolListSettingsView: View {
    let fileToolsEnabled: Bool
    let bashEnabled: Bool
    let skillsEnabled: Bool
    let computerEnabled: Bool

    @AppStorage("mcpServersJSON") private var mcpServersJSON = "[]"
    @State private var sources: [ToolSourceDescriptor] = []
    @State private var revision = 0

    var body: some View {
        GroupBox("Default Tool List") {
            VStack(alignment: .leading, spacing: 10) {
                Text("New chats inherit this list. Individual chats can override it from the input toolbar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                if sources.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: 56)
                }
                else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(sources) { source in
                                Toggle(isOn: sourceBinding(source)) {
                                    HStack(spacing: 8) {
                                        Image(systemName: source.kind.systemImage)
                                            .frame(width: 16)
                                            .foregroundStyle(source.isAvailable ? Color.accentColor : .secondary)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(source.name)
                                                .font(.system(size: 12, weight: .medium))
                                            Text(source.detail)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                    }
                                }
                                .toggleStyle(.checkbox)
                                .controlSize(.small)
                                .disabled(!source.isAvailable)
                                .padding(.vertical, 3)
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await loadSources() }
        .onChange(of: mcpServersJSON) { _, _ in reloadSources() }
        .onChange(of: fileToolsEnabled) { _, _ in reloadSources() }
        .onChange(of: bashEnabled) { _, _ in reloadSources() }
        .onChange(of: skillsEnabled) { _, _ in reloadSources() }
        .onChange(of: computerEnabled) { _, _ in reloadSources() }
    }

    private func sourceBinding(_ source: ToolSourceDescriptor) -> Binding<Bool> {
        Binding(
            get: {
                _ = revision
                return source.isAvailable
                    && !ToolSelectionStore.disabledSourceIDs(for: nil).contains(source.id)
            },
            set: { enabled in
                ToolSelectionStore.setSourceEnabled(enabled, sourceID: source.id, for: nil)
                revision += 1
            }
        )
    }

    private func reloadSources() {
        Task { await loadSources() }
    }

    @MainActor
    private func loadSources() async {
        sources = await ToolSourceCatalog.load(
            fileToolsEnabled: fileToolsEnabled,
            bashEnabled: bashEnabled,
            skillsEnabled: skillsEnabled,
            computerEnabled: computerEnabled
        )
    }
}
