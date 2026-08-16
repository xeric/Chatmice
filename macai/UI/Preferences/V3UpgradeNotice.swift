//
//  V3UpgradeNotice.swift
//  macai
//

import AppKit
@preconcurrency import Sparkle
import SwiftUI

/// Owns the Sparkle updater and enforces one rule: an update to macai 3 (or any
/// later major version) is never downloaded or installed until the user has
/// explicitly confirmed it in the upgrade notice, regardless of Sparkle's
/// automatic-update settings.
@MainActor
final class V3UpdateCoordinator: NSObject, ObservableObject {
    static let shared = V3UpdateCoordinator()

    private static let noticePresentedVersionKey = "v3UpgradeNoticePresentedVersion"

    @Published private(set) var availableV3Version: String?

    let noticeState = V3UpgradeNoticeState()

    private var upgradeWindowController: NSWindowController?
    private var userRequestedCheck = false

    /// Set only when the user chooses to continue from the upgrade notice.
    /// Deliberately in-memory: if the update doesn't complete this session,
    /// the confirmation must be given again.
    private var userConfirmedMajorUpgrade = false

    private(set) lazy var updaterController: SPUStandardUpdaterController = {
        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        // Defense in depth: the primary gate is updater(_:shouldProceedWithUpdate:updateCheck:),
        // which every Sparkle driver consults before downloading. Disabling silent
        // downloads as well means even a regression in that gate cannot lead to an
        // unattended install.
        controller.updater.automaticallyDownloadsUpdates = false
        controller.startUpdater()
        return controller
    }()

    var updater: SPUUpdater {
        updaterController.updater
    }

    override private init() {
        super.init()
        _ = updaterController
    }

    func checkForUpdates() {
        guard updater.canCheckForUpdates else { return }
        userRequestedCheck = true
        updater.checkForUpdatesInBackground()
    }

    func checkForUpdatesInBackground() {
        guard updater.canCheckForUpdates else { return }
        updater.checkForUpdatesInBackground()
    }

    func showAvailableV3Upgrade() {
        guard let version = availableV3Version else { return }
        showUpgradeNotice(version: version, recordsPresentation: false)
    }

    #if DEBUG
    func previewV3UpgradeNotice() {
        showUpgradeNotice(version: "3.0", recordsPresentation: false)
    }
    #endif

    /// Backs up the database, then lets the confirmed update proceed. The
    /// backup uses the same mechanism as manual backups in Settings → Backup
    /// & Restore, so it appears in that list and can be restored from there.
    func continueWithV3Update() {
        guard !noticeState.isBackingUp else { return }
        noticeState.isBackingUp = true

        let backupName = Self.preUpdateBackupName()
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try DatabaseBackupManager.createBackup(named: backupName) }
            }.value

            guard let self else { return }
            self.noticeState.isBackingUp = false

            switch result {
            case .success:
                self.proceedWithConfirmedUpdate()
            case .failure(let error):
                self.presentBackupFailure(error)
            }
        }
    }

    private func proceedWithConfirmedUpdate() {
        userConfirmedMajorUpgrade = true
        closeUpgradeNotice()
        updaterController.checkForUpdates(nil)
    }

    private static func preUpdateBackupName() -> String {
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return "Before-macai-3-\(timestamp)"
    }

    private func presentBackupFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Backup Failed"
        alert.informativeText =
            "macai couldn't back up your database before updating.\n\n\(error.localizedDescription)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Update Anyway")

        if alert.runModal() == .alertSecondButtonReturn {
            proceedWithConfirmedUpdate()
        }
    }

    func closeUpgradeNotice() {
        upgradeWindowController?.close()
        upgradeWindowController = nil
    }

    /// Called from the update gate when a major upgrade was found and blocked.
    /// Publishes the version (for the Settings banner) and shows the notice —
    /// automatically only once per version, but always for a user-initiated check.
    private func registerBlockedUpgrade(_ item: SUAppcastItem) {
        let version = item.displayVersionString
        availableV3Version = version

        let userAskedForThisCheck = userRequestedCheck
        userRequestedCheck = false

        let alreadyPresented = UserDefaults.standard.string(forKey: Self.noticePresentedVersionKey) == version
        guard userAskedForThisCheck || !alreadyPresented else { return }

        // Let Sparkle finish aborting its update driver before presenting UI.
        DispatchQueue.main.async { [weak self] in
            self?.showUpgradeNotice(version: version, recordsPresentation: true)
        }
    }

    private func showUpgradeNotice(version: String, recordsPresentation: Bool) {
        if let window = upgradeWindowController?.window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        if recordsPresentation {
            UserDefaults.standard.set(version, forKey: Self.noticePresentedVersionKey)
        }

        let rootView = V3UpgradeNoticeView(
            version: version,
            state: noticeState,
            onDismiss: { [weak self] in self?.closeUpgradeNotice() },
            onUpdate: { [weak self] in self?.continueWithV3Update() }
        )
        let window = NSWindow(contentViewController: NSHostingController(rootView: rootView))
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.title = "Update to macai 3"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        let controller = NSWindowController(window: window)
        upgradeWindowController = controller
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
    }

    private static func isMajorUpgrade(_ version: String) -> Bool {
        let firstNumber = version.firstIndex(where: \Character.isNumber)
        guard let firstNumber else { return false }
        let majorDigits = version[firstNumber...].prefix(while: \Character.isNumber)
        guard let major = Int(majorDigits) else { return false }
        return major >= 3
    }
}

extension V3UpdateCoordinator: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === upgradeWindowController?.window else { return }
        upgradeWindowController = nil
    }
}

extension V3UpdateCoordinator: @preconcurrency SPUUpdaterDelegate {
    /// The hard gate. Sparkle consults this in every update driver — including
    /// the silent automatic-install driver — before an update is downloaded.
    /// Throwing here means the update is neither shown by Sparkle nor
    /// downloaded, so a major upgrade cannot proceed without the explicit
    /// confirmation given in the upgrade notice.
    func updater(
        _ updater: SPUUpdater,
        shouldProceedWithUpdate updateItem: SUAppcastItem,
        updateCheck: SPUUpdateCheck
    ) throws {
        guard Self.isMajorUpgrade(updateItem.displayVersionString), !userConfirmedMajorUpgrade else { return }

        registerBlockedUpgrade(updateItem)
        throw NSError(
            domain: Bundle.main.bundleIdentifier ?? "macai",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "macai \(updateItem.displayVersionString) is a major upgrade and requires explicit confirmation."
            ]
        )
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        userRequestedCheck = false
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        guard userRequestedCheck else { return }
        userRequestedCheck = false

        let alert = NSAlert()
        alert.messageText = "You're up to date"
        alert.informativeText = "This Mac is running the newest available version of macai."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - Upgrade notice view

/// UI state the update coordinator drives while the notice is on screen.
/// Kept free of Sparkle dependencies so the view can be previewed standalone.
@MainActor
final class V3UpgradeNoticeState: ObservableObject {
    @Published var isBackingUp = false
}

struct V3UpgradeNoticeView: View {
    let version: String
    @ObservedObject var state: V3UpgradeNoticeState
    let onDismiss: () -> Void
    let onUpdate: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                V3AppIconBadge()

                Text("Before You Update to macai 3")
                    .font(.system(size: 26, weight: .bold))
                    .multilineTextAlignment(.center)

                Text(
                    "Version \(version) changes how AI Assistants and API Services work together. Here’s what to expect."
                )
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 400)
            }
            .padding(.top, 46)
            .padding(.horizontal, 40)

            VStack(alignment: .leading, spacing: 24) {
                V3ChangeRow(
                    icon: "person.crop.circle.badge.checkmark",
                    title: "Assistants take the lead",
                    detail:
                        "Each AI Assistant now owns its model, temperature, and context settings, and connects to one API service."
                )
                V3ChangeRow(
                    icon: "rectangle.2.swap",
                    title: "Switch without reconfiguring",
                    detail:
                        "Choosing an assistant brings its service, model, and settings along — no more editing a shared setup to change models."
                )
                V3ChangeRow(
                    icon: "checklist",
                    title: "Review after updating",
                    detail:
                        "Your settings are migrated automatically. Once the update finishes, confirm each assistant’s API service and model in Settings → AI Assistants."
                )
            }
            .padding(.vertical, 36)
            .padding(.horizontal, 62)

            VStack(spacing: 18) {
                Text(
                    "macai backs up your database before updating and never installs this update on its own. You can update any time from Settings."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 340)

                VStack(spacing: 12) {
                    Button(action: onUpdate) {
                        HStack(spacing: 8) {
                            if state.isBackingUp {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(state.isBackingUp ? "Backing Up…" : "Continue to Update…")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.isBackingUp)

                    Button("Not Now", action: onDismiss)
                        .buttonStyle(.link)
                        .keyboardShortcut(.cancelAction)
                        .disabled(state.isBackingUp)
                }
                .frame(width: 240)
            }
            .padding(.top, 2)
            .padding(.bottom, 34)
            .padding(.horizontal, 40)
        }
        .frame(width: 520)
    }
}

private struct V3AppIconBadge: View {
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage ?? NSImage(named: NSImage.applicationIconName) ?? NSImage())
            .resizable()
            .frame(width: 88, height: 88)
            .overlay(alignment: .bottomTrailing) {
                Text("3")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 27, height: 27)
                    .background(Color.accentColor, in: .circle)
                    .overlay {
                        Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 2)
                    }
                    .offset(x: 1, y: -3)
            }
            .accessibilityHidden(true)
    }
}

private struct V3ChangeRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 36)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("macai 3 upgrade notice") {
    V3UpgradeNoticeView(version: "3.0", state: V3UpgradeNoticeState(), onDismiss: {}, onUpdate: {})
}
