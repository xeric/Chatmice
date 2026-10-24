//
//  TabAIAgentsView.swift
//  Chatmice
//
//  Created by Renat Notfullin on 07.09.2024.
//

import CoreData
import SwiftUI
import UniformTypeIdentifiers

struct TabAIPersonasView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \PersonaEntity.order, ascending: true)],
        animation: .default
    )
    private var personas: FetchedResults<PersonaEntity>

    @State private var isShowingAddOrEditPersona = false
    @State private var selectedPersona: PersonaEntity?
    @State private var selectedPersonaID: NSManagedObjectID?
    @State private var refreshID = UUID()
    @State private var showingDeleteConfirmation = false
    @State private var personaToDelete: PersonaEntity?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                if personas.isEmpty {
                    addPresetsButton
                }
                Spacer()
                Button(action: onAdd) {
                    Label("Add New", systemImage: "plus")
                }
            }

            entityListView
                .id(refreshID)
        }
        .frame(minHeight: 300)
        .onChange(of: selectedPersonaID) { _, id in
            selectedPersona = personas.first(where: { $0.objectID == id })
            print("Selected Assistant ID: \(String(describing: id))")
            print("Selected Assistant: \(selectedPersona?.name ?? "nil")")
        }
        .sheet(isPresented: $isShowingAddOrEditPersona) {
            PersonaDetailView(
                persona: $selectedPersona,
                onSave: {
                    refreshList()
                },
                onDelete: {
                    selectedPersona = nil
                }
            )
        }
        .alert(isPresented: $showingDeleteConfirmation) {
            Alert(
                title: Text("Delete Assistant \(personaToDelete?.name ?? "Unknown")"),
                message: Text("Are you sure you want to delete this assistant? This action cannot be undone."),
                primaryButton: .destructive(Text("Delete")) {
                    if let persona = personaToDelete {
                        viewContext.delete(persona)
                        try? viewContext.save()
                        selectedPersonaID = nil
                    }
                },
                secondaryButton: .cancel()
            )
        }
    }

    private var entityListView: some View {
        EntityListView(
            selectedEntityID: $selectedPersonaID,
            entities: personas,
            detailContent: detailContent,
            getEntityColor: getPersonaColor,
            getEntityName: getPersonaName,
            getEntityIcon: getPersonaIcon,
            getEntityOverlayIcon: getPersonaOverlayIcon,
            onEdit: {
                if let persona = personas.first(where: { $0.objectID == selectedPersonaID }) {
                    selectedPersona = persona
                    isShowingAddOrEditPersona = true
                }
            },
            onMove: { fromOffsets, toOffset in
                var updatedItems = Array(personas)
                updatedItems.move(fromOffsets: fromOffsets, toOffset: toOffset)

                for (index, item) in updatedItems.enumerated() {
                    item.order = Int16(index)
                }

                do {
                    try viewContext.save()
                }
                catch {
                    print("Failed to save reordering: \(error)")
                }
            }
        )
    }

    private var addPresetsButton: some View {
        Button(action: {
            DatabasePatcher.addDefaultPersonasIfNeeded(context: viewContext, force: true)
        }) {
            Label("Add AI Assistants from Presets", systemImage: "plus.circle")
        }
    }

    private func detailContent(persona: PersonaEntity?) -> some View {
        Group {
            if let persona {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        PersonaIconView(persona: persona, size: 36)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(persona.name ?? "Unnamed Assistant")
                                .font(.headline)
                            Text(persona.systemMessage ?? "")
                                .foregroundStyle(.secondary)
                                .lineLimit(4)
                        }
                    }

                    HStack(spacing: 16) {
                        Button(action: onEdit) {
                            Label("Edit", systemImage: "pencil")
                        }
                        .buttonStyle(.borderless)
                        .keyboardShortcut(.defaultAction)

                        Button {
                            requestDelete(persona)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            else {
                Text("There are no assistants yet. Add one or restore the built-in presets above.")
            }
        }
    }

    private func requestDelete(_ persona: PersonaEntity) {
        personaToDelete = persona
        showingDeleteConfirmation = true
    }

    private func onAdd() {
        selectedPersona = nil
        isShowingAddOrEditPersona = true
    }

    private func onEdit() {
        selectedPersona = personas.first(where: { $0.objectID == selectedPersonaID })
        isShowingAddOrEditPersona = true
        print("Opening Assistant Detail View: \(selectedPersona?.name ?? "nil")")
    }

    private func getPersonaColor(persona: PersonaEntity) -> Color? {
        Color(hex: persona.color ?? "#FFFFFF") ?? .white
    }

    private func getPersonaName(persona: PersonaEntity) -> String {
        persona.name ?? "Unnamed Assistant"
    }

    private func getPersonaIcon(persona: PersonaEntity) -> String? {
        PersonaAppearance.symbolName(for: persona)
    }

    private func getPersonaOverlayIcon(persona: PersonaEntity) -> String? {
        PersonaAppearance.overlaySymbolName(for: persona)
    }

    private func refreshList() {
        refreshID = UUID()
    }
}

struct PersonaDetailView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.presentationMode) var presentationMode

    @Binding var persona: PersonaEntity?
    let onSave: () -> Void
    let onDelete: () -> Void

    @State private var name: String = ""
    @State private var color: Color = Color(hex: PersonaAppearance.defaultColor) ?? .red
    @State private var systemMessage: String = ""
    @State private var showingDeleteConfirmation = false
    @State private var temperature: Float = AppConstants.defaultPersonaTemperature
    @State private var symbolName = PersonaAppearance.defaultSymbol
    @State private var symbolOverlayName = ""
    @State private var isSymbolOptionsExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading) {

            HStack(alignment: .center, spacing: 16) {
                PersonaIconView(
                    color: color,
                    symbolName: symbolName,
                    overlaySymbolName: symbolOverlayName.isEmpty ? nil : symbolOverlayName,
                    size: 48
                )

                VStack(alignment: .leading) {
                    Text("Name:")
                    TextField("Enter AI Assistant name here", text: $name)
                }

                VStack(alignment: .leading) {
                    Text("Color:")
                    ColorPicker("Assistant color", selection: $color)
                        .labelsHidden()
                }
            }
            .padding(.top, 8)

            DisclosureGroup(isExpanded: $isSymbolOptionsExpanded) {
                PersonaSymbolPicker(
                    symbolName: $symbolName,
                    overlaySymbolName: $symbolOverlayName
                )
                .padding(.top, 10)
            } label: {
                HStack(spacing: 8) {
                    Text("Icon & Badge")
                    Spacer()
                    Image(systemName: symbolName)
                        .foregroundStyle(.secondary)
                    if !symbolOverlayName.isEmpty {
                        Image(systemName: symbolOverlayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 8)

            VStack(alignment: .leading) {
                Text("System message:")
                TextEditor(text: $systemMessage)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.primary)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 160, maxHeight: 160)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                            )
                    )
            }
            .padding(.top, 8)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Slider(
                        value: $temperature,
                        in: 0...1,
                        step: 0.1
                    ) {
                        Text("Temperature")
                    } minimumValueLabel: {
                        Text("0.0")
                    } maximumValueLabel: {
                        Text("1.0")
                    }

                    Text(getTemperatureLabel())
                        .frame(width: 90)
                }

                Text("1.0 is recommended when using reasoning models.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)


        }
        .padding()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Divider()
            personaEditorFooter
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 480, idealWidth: 520)
        .frame(height: 500)
        .onAppear {
            print(">> Assistant: \(persona?.name ?? "")")
            if let persona = persona {
                name = persona.name ?? ""
                color = Color(hex: persona.color ?? "#FFFFFF") ?? .white
                systemMessage = persona.systemMessage ?? ""
                temperature = persona.temperature
                symbolName = PersonaAppearance.symbolName(for: persona)
                symbolOverlayName = PersonaAppearance.overlaySymbolName(for: persona) ?? ""
            }
        }
        .alert(isPresented: $showingDeleteConfirmation) {
            Alert(
                title: Text("Delete Assistant"),
                message: Text("Are you sure you want to delete this assistant? This action cannot be undone."),
                primaryButton: .destructive(Text("Delete")) {
                    deletePersona()
                    onDelete()
                },
                secondaryButton: .cancel()
            )
        }
    }

    private var personaEditorFooter: some View {
        HStack {
            if persona != nil {
                Button(action: {
                    showingDeleteConfirmation = true
                }) {
                    Label("Delete", systemImage: "trash")
                        .foregroundColor(.red)
                }
            }

            Spacer()

            Button("Cancel") {
                presentationMode.wrappedValue.dismiss()
            }

            Button(persona == nil ? "Create Assistant" : "Update Assistant") {
                savePersona()
                onSave()
            }
            .disabled(name.isEmpty || systemMessage.isEmpty)
            .keyboardShortcut(.defaultAction)
        }
    }

    private func getTemperatureLabel() -> String {
        if temperature > 0.8 {
            return "Creative"
        }

        if temperature > 0.6 {
            return "Explorative"
        }

        if temperature > 0.4 {
            return "Balanced"
        }

        if temperature > 0.2 {
            return "Focused"
        }

        return "Deterministic"
    }

    private func savePersona() {
        let personaToSave = persona ?? PersonaEntity(context: viewContext)
        personaToSave.name = name
        personaToSave.color = color.toHex()
        personaToSave.temperature = round(temperature * 10) / 10
        personaToSave.systemMessage = systemMessage
        personaToSave.symbolName = PersonaAppearance.validatedSymbol(
            symbolName,
            fallback: PersonaAppearance.defaultSymbol
        )
        let trimmedOverlay = symbolOverlayName.trimmingCharacters(in: .whitespacesAndNewlines)
        personaToSave.symbolOverlayName = PersonaAppearance.isValidSymbol(trimmedOverlay)
            ? trimmedOverlay
            : nil
        if persona == nil {
            personaToSave.addedDate = Date()
            personaToSave.id = UUID()

            let fetchRequest: NSFetchRequest<PersonaEntity> = PersonaEntity.fetchRequest()
            do {
                let existingPersonas = try viewContext.fetch(fetchRequest)
                for existingPersona in existingPersonas {
                    existingPersona.order += 1
                }
                personaToSave.order = 0
            }
            catch {
                personaToSave.order = 0
                print("Error fetching personas for order: \(error)")
            }
        }
        else {
            personaToSave.editedDate = Date()
        }

        if personaToSave.objectID.isTemporaryID {
            do {
                try viewContext.obtainPermanentIDs(for: [personaToSave])
            }
            catch {
                print("Failed to obtain permanent ID for persona: \(error)")
            }
        }

        let linkedChatsRequest = NSFetchRequest<ChatEntity>(entityName: "ChatEntity")
        linkedChatsRequest.predicate = NSPredicate(format: "persona == %@", personaToSave)
        if let linkedChats = try? viewContext.fetch(linkedChatsRequest) {
            for chat in linkedChats {
                chat.systemMessage = systemMessage
            }
        }

        do {
            personaToSave.objectWillChange.send()
            try viewContext.save()
            presentationMode.wrappedValue.dismiss()
        }
        catch {
            let nsError = error as NSError
            fatalError("Unresolved error \(nsError), \(nsError.userInfo)")
        }
    }

    private func deletePersona() {
        if let personaToDelete = persona {
            viewContext.delete(personaToDelete)
            do {
                try viewContext.save()
                presentationMode.wrappedValue.dismiss()
            }
            catch {
                let nsError = error as NSError
                fatalError("Unresolved error \(nsError), \(nsError.userInfo)")
            }
        }
    }
}

#Preview {
    TabAIPersonasView()
}
