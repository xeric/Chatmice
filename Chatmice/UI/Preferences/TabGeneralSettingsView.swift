//
//  TabGeneralSettingsView.swift
//  Chatmice
//
//  Created by Renat on 31.01.2025.
//

import AppKit
import ServiceManagement
import SwiftUI

struct TabGeneralSettingsView: View {
    @AppStorage(PersistenceController.iCloudSyncEnabledKey) private var iCloudSyncEnabled: Bool = false
    @AppStorage(SettingsIndicatorKeys.generalSeen) private var generalSettingsSeen: Bool = false
    @ObservedObject private var presentationController = AppPresentationController.shared
    @StateObject private var cloudSyncManager = CloudSyncManager.shared
    @State private var showRestartAlert: Bool = false
    @State private var pendingSyncState: Bool = false
    @State private var showSyncDebugLog: Bool = false
    @State private var isPurgingCloudData: Bool = false
    @State private var purgeError: String?
    @State private var launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?

    private var selectedPresentationMode: AppPresentationMode {
        presentationController.mode
    }

    private var presentationModeRaw: Binding<String> {
        Binding(
            get: { presentationController.mode.rawValue },
            set: { rawValue in
                guard let mode = AppPresentationMode(rawValue: rawValue) else { return }
                presentationController.selectMode(mode)
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox {
                HStack(alignment: .center, spacing: 16) {
                    Image(systemName: "power")
                        .foregroundStyle(Color.accentColor)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Launch at Login")
                            .fontWeight(.medium)
                        Text("Open Chatmice automatically when you sign in to this Mac.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 20)

                    Toggle("Launch at Login", isOn: Binding(
                        get: { launchAtLoginEnabled },
                        set: setLaunchAtLogin
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                .padding(8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Use a plain VStack instead of Form so sections stretch to the full
            // available width (macOS Form tends to hug intrinsic content).
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "menubar.rectangle")
                            .foregroundStyle(Color.accentColor)
                        Text("App Visibility")
                            .fontWeight(.medium)
                        Spacer()
                    }

                    Picker("Show Chatmice in", selection: presentationModeRaw) {
                        ForEach(AppPresentationMode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.menu)

                    Text(selectedPresentationMode.description)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

                // Offer sync only when this build is signed for the configured CloudKit container.
                #if !DISABLE_ICLOUD
                    if AppConstants.isCloudKitAvailable {
                        GroupBox {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(alignment: .center, spacing: 8) {
                                    Text("iCloud Sync")
                                        .fontWeight(.medium)

                                    Image(systemName: "info.circle")
                                        .foregroundColor(.secondary)
                                        .font(.callout)
                                        .help(
                                            """
                                            - Your data is transmitted securely to iCloud and stored by Apple; it is not accessible to the Chatmice developer.
                                            - You can enable Advanced Data Protection in iCloud settings to encrypt your data so even Apple can't read your chats and messages.
                                            - Apple collects telemetry data, but it is anonymized.
                                            """
                                        )

                                    SettingsIndicatorBadge(text: "Beta", color: .gray)

                                    Spacer()

                                    // Status indicator with label
                                    HStack(spacing: 6) {
                                        Circle()
                                            .fill(syncStatusColor)
                                            .frame(width: 8, height: 8)
                                        Text(syncStatusText)
                                            .foregroundColor(.secondary)
                                            .font(.callout)
                                    }

                                    Button(action: {
                                        pendingSyncState = !iCloudSyncEnabled
                                        showRestartAlert = true
                                    }) {
                                        Text(iCloudSyncEnabled ? "Turn Off" : "Turn On")
                                            .frame(width: 60)
                                    }
                                    .disabled(isPurgingCloudData)
                                }

                                Text(
                                    "Syncs chats, messages, AI Assistants, and API Services across your devices. API keys are synced securely via iCloud Keychain."
                                )
                                .foregroundColor(.secondary)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)

                                if iCloudSyncEnabled {
                                    HStack {
                                        Spacer()
                                        Button("Show Log") {
                                            showSyncDebugLog = true
                                        }
                                        .buttonStyle(.link)
                                        .font(.callout)
                                    }
                                }
                            }
                            .padding(8)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(maxWidth: .infinity)
                    }
                #else
                    // Show info when iCloud is disabled via build flag
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Image(systemName: "icloud.slash")
                                    .foregroundColor(.secondary)
                                    .font(.title2)

                                Text("iCloud Sync Disabled")
                                    .fontWeight(.medium)

                                Spacer()
                            }

                            Text("iCloud Sync is disabled in this build via the DISABLE_ICLOUD compiler flag.")
                                .foregroundColor(.secondary)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)

                            Text(
                                "To enable iCloud Sync, remove DISABLE_ICLOUD from Build Settings → Swift Compiler → Active Compilation Conditions."
                            )
                            .foregroundColor(.secondary)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(8)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                #endif


        }
        .padding()
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                generalSettingsSeen = true
            }
        }
        .alert("Launch at Login", isPresented: Binding(
            get: { launchAtLoginError != nil },
            set: { if !$0 { launchAtLoginError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(launchAtLoginError ?? "Unable to update the login item.")
        }
        .alert("Restart Required", isPresented: $showRestartAlert) {
            Button("Cancel", role: .cancel) {}
            if pendingSyncState {
                Button("Enable & Restart") {
                    // Cache tokens first, then restore to cloud after enabling sync
                    let cachedTokens = TokenManager.cacheAllTokens()
                    iCloudSyncEnabled = pendingSyncState
                    TokenManager.restoreTokensToCloudKeychain(cachedTokens)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        restartApp()
                    }
                }
            }
            else {
                Button("Disable & Keep in iCloud") {
                    // Cache tokens in memory first, then restore to local keychain
                    let cachedTokens = TokenManager.cacheAllTokens()
                    iCloudSyncEnabled = pendingSyncState
                    TokenManager.restoreTokensToLocalKeychain(cachedTokens)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        restartApp()
                    }
                }
                Button("Disable & Delete from iCloud", role: .destructive) {
                    guard !isPurgingCloudData else { return }
                    isPurgingCloudData = true
                    // Cache all tokens in memory BEFORE any keychain operations
                    let cachedTokens = TokenManager.cacheAllTokens()
                    cloudSyncManager.purgeCloudData { result in
                        DispatchQueue.main.async {
                            isPurgingCloudData = false
                            switch result {
                            case .success:
                                purgeError = nil
                                TokenManager.clearCloudTokens()
                                // Restore cached tokens to local keychain AFTER clearing cloud
                                TokenManager.restoreTokensToLocalKeychain(cachedTokens)
                                iCloudSyncEnabled = pendingSyncState
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                    restartApp()
                                }
                            case .failure(let error):
                                purgeError = error.localizedDescription
                            }
                        }
                    }
                }
            }
        } message: {
            Text(
                pendingSyncState
                    ? "Enabling iCloud sync requires restarting the app. Your existing data will be uploaded to iCloud."
                    : "Disabling iCloud sync requires restarting the app. Choose to keep or delete your iCloud copy; local data stays on this Mac and will stop syncing."
            )
        }
        .sheet(isPresented: $showSyncDebugLog) {
            SyncDebugLogView(cloudSyncManager: cloudSyncManager)
        }
        .alert(
            "Couldn't remove iCloud data",
            isPresented: Binding<Bool>(
                get: { purgeError != nil },
                set: { newValue in if !newValue { purgeError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(purgeError ?? "Unknown error")
        }
    }

    private var syncStatusColor: Color {
        if !iCloudSyncEnabled {
            return .gray
        }
        switch cloudSyncManager.syncStatus {
        case .inactive:
            return .gray
        case .syncing:
            return .yellow
        case .synced:
            return .green
        case .error:
            return .red
        }
    }

    private var syncStatusText: String {
        if !iCloudSyncEnabled {
            return "Off"
        }
        switch cloudSyncManager.syncStatus {
        case .inactive:
            return "Off"
        case .syncing:
            return "Syncing..."
        case .synced:
            return "Up to date"
        case .error(let message):
            return "Error: \(message)"
        }
    }

    private func restartApp() {
        let appPath = Bundle.main.bundlePath

        // Spawn a detached shell process that waits for the app to quit, then relaunches it
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; open \"\(appPath)\""]

        do {
            try task.run()
        }
        catch {
            print("Failed to schedule relaunch: \(error.localizedDescription)")
        }

        // Terminate the current instance
        NSApplication.shared.terminate(nil)
    }
    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        } catch {
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
            launchAtLoginError = error.localizedDescription
        }
    }

}

// MARK: - Sync Debug Log View

struct SyncDebugLogView: View {
    @ObservedObject var cloudSyncManager: CloudSyncManager
    @Environment(\.dismiss) private var dismiss
    @State private var autoScroll = true
    @State private var showErrorsOnly = false

    private var filteredLogs: [CloudSyncManager.SyncLogEntry] {
        if showErrorsOnly {
            return cloudSyncManager.syncLogs.filter { $0.isError }
        }
        return cloudSyncManager.syncLogs
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("iCloud Sync Debug Log")
                    .font(.headline)

                Spacer()

                // Status
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(cloudSyncManager.syncStatus.displayText)
                        .foregroundColor(.secondary)
                        .font(.callout)
                }

                Spacer()

                Toggle("Auto-scroll", isOn: $autoScroll)
                    .toggleStyle(.checkbox)

                Toggle("Errors only", isOn: $showErrorsOnly)
                    .toggleStyle(.checkbox)

                Button("Copy Log") {
                    let logText = cloudSyncManager.exportLogsAsText()
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(logText, forType: .string)
                }

                Button("Clear") {
                    cloudSyncManager.clearLogs()
                }

                Button("Close") {
                    dismiss()
                }
            }
            .padding()

            Divider()

            // Log entries
            if filteredLogs.isEmpty {
                VStack {
                    Spacer()
                    Text("No log entries yet")
                        .foregroundColor(.secondary)
                    Text("Sync events will appear here")
                        .foregroundColor(.secondary)
                        .font(.callout)
                    Spacer()
                }
            }
            else {
                ScrollViewReader { proxy in
                    List(filteredLogs) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Text(entry.formattedTimestamp)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(width: 90, alignment: .leading)

                            Text(entry.type)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(typeColor(entry.type))
                                .frame(width: 80, alignment: .leading)

                            Text(entry.message)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(entry.isError ? .red : .primary)
                                .textSelection(.enabled)
                        }
                        .id(entry.id)
                    }
                    .onChange(of: filteredLogs.count) {
                        if autoScroll, let lastEntry = filteredLogs.last {
                            withAnimation {
                                proxy.scrollTo(lastEntry.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }

            Divider()

            // Footer with stats
            HStack {
                if showErrorsOnly {
                    Text("\(filteredLogs.count) errors of \(cloudSyncManager.syncLogs.count) entries")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                else {
                    Text("\(cloudSyncManager.syncLogs.count) entries")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if let lastSync = cloudSyncManager.lastSyncDate {
                    Text("Last sync: \(lastSync.formatted(date: .abbreviated, time: .standard))")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
        }
        .frame(minWidth: 700, minHeight: 400)
    }

    private var statusColor: Color {
        switch cloudSyncManager.syncStatus {
        case .inactive:
            return .gray
        case .syncing:
            return .yellow
        case .synced:
            return .green
        case .error:
            return .red
        }
    }

    private func typeColor(_ type: String) -> Color {
        switch type {
        case "Error", "CloudKit":
            return .red
        case "Setup":
            return .blue
        case "Event":
            return .green
        case "RemoteChange":
            return .orange
        default:
            return .secondary
        }
    }
}
