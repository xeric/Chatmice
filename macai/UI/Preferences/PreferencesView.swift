//
//  PreferencesView.swift
//  Chatmice / macai
//
//  Native macOS Preferences Window implementing standard Apple HIG.
//

import AppKit
import Foundation
import SwiftUI

struct PreferencesView: View {
    @StateObject private var store = ChatStore(persistenceController: PersistenceController.shared)

    var body: some View {
        TabView {
            TabGeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            TabAPIServicesView()
                .tabItem {
                    Label("API Services", systemImage: "network")
                }

            TabAIPersonasView()
                .tabItem {
                    Label("AI Assistants", systemImage: "person.2")
                }

            TabMCPServersView()
                .tabItem {
                    Label("MCP", systemImage: "hammer")
                }

            TabSkillsView()
                .tabItem {
                    Label("Skills", systemImage: "puzzlepiece.extension")
                }

            BackupRestoreView(store: store)
                .tabItem {
                    Label("Backup", systemImage: "externaldrive")
                }

            DangerZoneView(store: store)
                .tabItem {
                    Label("Danger Zone", systemImage: "flame.fill")
                }
        }
        .frame(width: 520)
        .padding()
        .onAppear {
            store.saveInCoreData()
            if let window = NSApp.mainWindow {
                window.title = "Settings"
                window.standardWindowButton(.zoomButton)?.isEnabled = false
            }
        }
    }
}
