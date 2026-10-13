import AppKit
import CoreData
import SwiftUI

struct WorkspaceCreationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext

    let workspace: WorkspaceEntity?
    let onSave: (WorkspaceEntity) -> Void

    @State private var name = ""
    @State private var directory: URL?
    @State private var errorMessage: String?

    init(workspace: WorkspaceEntity? = nil, onSave: @escaping (WorkspaceEntity) -> Void) {
        self.workspace = workspace
        self.onSave = onSave
        _name = State(initialValue: workspace?.name ?? "")
        _directory = State(initialValue: workspace?.rootURL)
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && directory != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: workspace == nil ? "folder.badge.plus" : "folder")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 48, height: 48)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 5) {
                    Text(workspace == nil ? "Create a Workspace" : "Edit Workspace")
                        .font(.title2.weight(.semibold))
                    Text("Chats use this folder for local tools. Changing the folder affects future requests in all of this workspace's chats; existing files are not moved.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Form {
                LabeledContent("Name") {
                    TextField("Workspace name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(width: 260)
                        .accessibilityIdentifier("workspace.name")
                }

                LabeledContent("Folder") {
                    HStack(spacing: 8) {
                        Text(directory?.path(percentEncoded: false) ?? "No folder selected")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(directory == nil ? .secondary : .primary)
                            .frame(width: 190, alignment: .leading)

                        Button("Choose…", action: chooseDirectory)
                            .accessibilityIdentifier("workspace.chooseFolder")
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(workspace == nil ? "Create Workspace" : "Save Changes", action: createWorkspace)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
        }
        .padding(24)
        .frame(width: 520, height: 340)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose Workspace Folder"
        panel.message = "Chatmice will keep this workspace's file access inside the selected folder."
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
        directory = selectedURL.standardizedFileURL.resolvingSymlinksInPath()
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            name = selectedURL.lastPathComponent
        }
        errorMessage = nil
    }

    private func createWorkspace() {
        guard let directory else { return }
        do {
            let savedWorkspace: WorkspaceEntity
            if let workspace {
                try WorkspaceManager.update(workspace, name: name, directory: directory, in: viewContext)
                savedWorkspace = workspace
            } else {
                savedWorkspace = try WorkspaceManager.create(name: name, directory: directory, in: viewContext)
            }
            onSave(savedWorkspace)
            dismiss()
        }
        catch {
            errorMessage = error.localizedDescription
        }
    }
}
