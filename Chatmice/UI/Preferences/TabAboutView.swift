//
//  TabAboutView.swift
//  Chatmice
//
//  Project information and update preferences.
//

import AppKit
import SwiftUI

struct TabAboutView: View {
    @AppStorage("autoCheckForUpdates") private var automaticUpdates = true
    @ObservedObject private var updateCoordinator = V3UpdateCoordinator.shared
    @StateObject private var updateAvailability: CheckForUpdatesViewModel

    init() {
        _updateAvailability = StateObject(
            wrappedValue: CheckForUpdatesViewModel(updater: V3UpdateCoordinator.shared.updater)
        )
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    settingsHeader("Updates", symbol: "arrow.triangle.2.circlepath")

                    HStack(alignment: .center, spacing: 16) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Automatic Updates")
                                .fontWeight(.medium)
                            Text("Periodically check for new versions and notify you when an update is available.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 20)

                        Toggle("Automatic Updates", isOn: $automaticUpdates)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .onChange(of: automaticUpdates) { _, enabled in
                                updateCoordinator.updater.automaticallyChecksForUpdates = enabled
                            }
                    }

                    Divider()

                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Current Version")
                                .fontWeight(.medium)
                            Text("Version \(version) (Build \(build))")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button("Check for Updates") {
                            updateCoordinator.checkForUpdates()
                        }
                        .disabled(!updateAvailability.canCheckForUpdates)
                    }

                    if let availableVersion = updateCoordinator.availableV3Version {
                        Divider()
                        HStack(spacing: 12) {
                            Image(systemName: "sparkles")
                                .font(.title2)
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Chatmice \(availableVersion) is available")
                                    .font(.headline)
                                Text("Review the changes before installing this major update.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Review Update") {
                                updateCoordinator.showAvailableV3Upgrade()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
                .padding(8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    settingsHeader("About Chatmice", symbol: "info.circle")

                    Text("A native macOS AI workspace for conversations, tools, local automation, and multiple model providers.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider()

                    infoRow("Source Code", value: "github.com/xeric/Chatmice") {
                        open(URL(string: "https://github.com/xeric/Chatmice")!)
                    }
                    infoRow("License", value: "Apache License 2.0") {
                        open(URL(string: "https://github.com/xeric/Chatmice/blob/main/LICENSE.md")!)
                    }
                }
                .padding(8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .onAppear {
            updateCoordinator.updater.automaticallyChecksForUpdates = automaticUpdates
        }
    }

    private func settingsHeader(_ title: String, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(Color.accentColor)
            Text(title)
                .fontWeight(.medium)
            Spacer()
        }
    }

    private func infoRow(
        _ title: String,
        value: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 16) {
            Text(title)
                .fontWeight(.medium)
            Spacer()
            Button(value, action: action)
                .buttonStyle(.link)
        }
    }

    private func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
