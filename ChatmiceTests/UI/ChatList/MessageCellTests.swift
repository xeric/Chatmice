import CoreData
import XCTest
@testable import Chatmice

final class MessageCellTests: XCTestCase {

    @MainActor
    func testSelectingPersonaUpdatesChatPromptAndKeepsIconComposition() throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext

        let chat = ChatEntity(context: context)
        chat.id = UUID()
        chat.name = "Persona test"
        chat.systemMessage = "Old prompt"
        chat.gptModel = "test"
        chat.requestMessages = []

        let persona = PersonaEntity(context: context)
        persona.id = UUID()
        persona.name = "Engineer"
        persona.systemMessage = "New prompt"
        persona.symbolName = "laptopcomputer"
        persona.symbolOverlayName = "checkmark"

        PersonaSelection.apply(persona, to: chat)

        XCTAssertEqual(chat.persona, persona)
        XCTAssertEqual(chat.systemMessage, "New prompt")
        XCTAssertEqual(chat.persona?.symbolName, "laptopcomputer")
        XCTAssertEqual(chat.persona?.symbolOverlayName, "checkmark")
        XCTAssertFalse(chat.hasChanges)
    }

    @MainActor
    func testPersonaSymbolPatchMapsPresetsAndFallsBackForCustomAssistants() throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext

        let preset = PersonaEntity(context: context)
        preset.id = UUID()
        preset.name = "Software Engineer"

        let custom = PersonaEntity(context: context)
        custom.id = UUID()
        custom.name = "Custom Assistant"
        try context.save()

        DatabasePatcher.patchPersonaSymbols(context: context)

        XCTAssertEqual(preset.symbolName, "laptopcomputer")
        XCTAssertEqual(custom.symbolName, PersonaAppearance.defaultSymbol)
        XCTAssertFalse(context.hasChanges)
    }

    func testBuiltInPersonaSymbolsMatchRequestedDefaults() {
        let expectedSymbols = [
            "Default Assistant": "person.fill",
            "Software Engineer": "laptopcomputer",
            "AI Expert": "sparkles",
            "Natural Sciences Expert": "globe.americas.fill",
            "History Buff": "books.vertical.fill",
            "Fitness Trainer": "dumbbell.fill",
            "Dietologist": "leaf.fill",
            "DBT Psychologist": "brain.head.profile",
        ]

        for (name, symbol) in expectedSymbols {
            XCTAssertEqual(PersonaAppearance.defaultSymbol(for: name), symbol)
            XCTAssertEqual(
                AppConstants.PersonaPresets.allPersonas.first(where: { $0.name == name })?.symbolName,
                symbol
            )
        }
    }

    func testSymbolCatalogSupportsBroadKeywordSearchForBaseAndBadgeSymbols() {
        XCTAssertGreaterThan(PersonaSymbolCatalog.baseOptions.count, 80)
        XCTAssertGreaterThan(PersonaSymbolCatalog.overlayOptions.count, 30)
        XCTAssertTrue(PersonaSymbolCatalog.baseOptions.contains { $0.matches("psychology") })
        XCTAssertTrue(PersonaSymbolCatalog.baseOptions.contains { $0.matches("database") })
        XCTAssertTrue(PersonaSymbolCatalog.overlayOptions.contains { $0.matches("notification") })
        XCTAssertTrue(PersonaSymbolCatalog.overlayOptions.contains { $0.matches("安全") })
    }

    @MainActor
    func testRevisedPresetPatchUpdatesGeneratedIconsAndPreservesCustomChoices() throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext

        let aiExpert = PersonaEntity(context: context)
        aiExpert.id = UUID()
        aiExpert.name = "AI Expert"
        aiExpert.symbolName = "brain.head.profile"

        let customizedDefault = PersonaEntity(context: context)
        customizedDefault.id = UUID()
        customizedDefault.name = "Default Assistant"
        customizedDefault.symbolName = "camera.fill"
        try context.save()

        persistence.setMetadata(
            value: false,
            forKey: AppConstants.personaDefaultSymbolsV2PatchCompletedKey
        )
        DatabasePatcher.patchPersonaDefaultSymbolsV2(context: context, persistence: persistence)

        XCTAssertEqual(aiExpert.symbolName, "sparkles")
        XCTAssertEqual(customizedDefault.symbolName, "camera.fill")
        XCTAssertEqual(
            persistence.getMetadata(forKey: AppConstants.personaDefaultSymbolsV2PatchCompletedKey) as? Bool,
            true
        )
    }

    func testUntitledConversationUsesVisibleFallbackTitleAndMessageIcon() {
        let presentation = SidebarConversationPresentation(
            chatName: "  \n",
            personaColor: "#FF4444",
            personaSymbolName: "person.fill",
            personaOverlaySymbolName: "star.fill"
        )

        XCTAssertEqual(presentation.title, "Untitled")
        XCTAssertEqual(presentation.color, "#007AFF")
        XCTAssertEqual(presentation.symbolName, "bubble.left.fill")
        XCTAssertNil(presentation.overlaySymbolName)
    }

}
