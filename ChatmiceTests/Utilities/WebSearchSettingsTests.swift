//
//  WebSearchSettingsTests.swift
//  ChatmiceTests
//

import XCTest

@testable import Chatmice

final class WebSearchSettingsTests: XCTestCase {
    func testNewChatSearchDefaultPrefersEnabledWebProvider() throws {
        var settings = WebSearchSettings(enabled: true, searchEnabledByDefault: true)
        XCTAssertEqual(settings.defaultSearchModeForNewChat, .web)

        let providerIndex = try XCTUnwrap(settings.providers.firstIndex { $0.id == .tavily })
        settings.providers[providerIndex].enabled = false
        XCTAssertEqual(settings.defaultSearchModeForNewChat, .native)

        settings.searchEnabledByDefault = false
        XCTAssertEqual(settings.defaultSearchModeForNewChat, .off)
    }

    func testDecodePreservesExistingSettingsWithoutNewChatDefault() throws {
        let original = WebSearchSettings(
            enabled: true,
            defaultSearchProvider: .searxng,
            defaultFetchProvider: .jina,
            maxResults: 17
        )
        let encoded = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "searchEnabledByDefault")

        let migrated = try JSONDecoder().decode(
            WebSearchSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertTrue(migrated.enabled)
        XCTAssertFalse(migrated.searchEnabledByDefault)
        XCTAssertEqual(migrated.defaultSearchProvider, .searxng)
        XCTAssertEqual(migrated.defaultFetchProvider, .jina)
        XCTAssertEqual(migrated.maxResults, 17)
    }
}
