//
//  PDFHandlingTests.swift
//  ChatmiceTests
//
//  Created by Renat Notfullin on 10.01.2026
//

import XCTest
import Combine
@testable import Chatmice

final class PDFHandlingTests: XCTestCase {
    private func fileURL(named name: String) -> URL {
        let baseURL = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return baseURL
            .appendingPathComponent("Files")
            .appendingPathComponent(name)
    }

    @MainActor
    private func waitForAttachment(_ attachment: DocumentAttachment, timeout: TimeInterval = 5.0) async {
        let loaded = expectation(description: "Wait for attachment load")
        // Yield the main actor while the loader publishes completion on the main queue.
        // A timeout must fail the expectation, never masquerade as completed loading.
        let observation = attachment.$isLoading
            .first(where: { !$0 })
            .sink { _ in loaded.fulfill() }
        defer { observation.cancel() }
        await fulfillment(of: [loaded], timeout: timeout)
    }

    @MainActor
    func testNormalPDFLoadsAndGeneratesPreview() async {
        let url = fileURL(named: "lorem-ipsum.pdf")
        let attachment = DocumentAttachment(url: url)

        await waitForAttachment(attachment)

        XCTAssertNil(attachment.error)
        XCTAssertTrue(attachment.isReadyForUpload)
        XCTAssertFalse(attachment.previewUnavailable)
        XCTAssertNotNil(attachment.thumbnail)
    }

    @MainActor
    func testCorruptedPDFDoesNotCrashAndRemainsSendable() async {
        let url = fileURL(named: "lorem-ipsum-corrupted.pdf")
        let attachment = DocumentAttachment(url: url)

        await waitForAttachment(attachment)

        XCTAssertNil(attachment.error)
        XCTAssertTrue(attachment.isReadyForUpload)
    }

    @MainActor
    func testEncryptedPDFDoesNotCrashAndRemainsSendable() async {
        let url = fileURL(named: "lorem-ipsum-password.pdf")
        let attachment = DocumentAttachment(url: url)

        await waitForAttachment(attachment)

        XCTAssertNil(attachment.error)
        XCTAssertTrue(attachment.isReadyForUpload)
    }
}
