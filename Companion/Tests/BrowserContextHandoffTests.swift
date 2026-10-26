import Foundation
import XCTest
@testable import MyTermCompanion

@MainActor
final class BrowserContextHandoffTests: XCTestCase {
    private let connection = SavedConnectionID(relayOrigin: "https://relay.example", accountID: UUID(), hostID: UUID())
    private var capture: CompanionBrowserCapture {
        CompanionBrowserCapture(url: "https://example.com/settings", title: "Settings",
            selectedText: "Save changes", screenshot: nil, notes: [])
    }

    func testContextAppendsWithoutReplacingAnExistingDraftOrClaimingScreenshotDelivery() throws {
        let result = try capture.appending(instructions: "  Fix button spacing  ", to: "Existing instruction",
            capturedConnection: connection, currentConnection: connection)
        XCTAssertTrue(result.hasPrefix("Existing instruction\n\nFix button spacing"))
        XCTAssertTrue(result.contains("URL: https://example.com/settings"))
        XCTAssertTrue(result.contains("Selected page text (context):\nSave changes"))
        XCTAssertFalse(result.localizedCaseInsensitiveContains("screenshot"))
    }

    func testOversizeAppendFailsBeforeTheExistingDraftCanBeReplaced() {
        let original = String(repeating: "a", count: TerminalComposerDraft.maximumUTF8Bytes)
        XCTAssertThrowsError(try capture.appending(instructions: "", to: original,
            capturedConnection: connection, currentConnection: connection)) { error in
                XCTAssertTrue(error is BrowserContextHandoffError)
        }
        XCTAssertEqual(original.utf8.count, TerminalComposerDraft.maximumUTF8Bytes)
    }

    func testSwitchingHostOrDisconnectingCannotAppendToTheNewMacDraft() {
        let other = SavedConnectionID(relayOrigin: connection.relayOrigin,
                                     accountID: connection.accountID, hostID: UUID())
        for current in [Optional(other), nil] {
            XCTAssertThrowsError(try capture.appending(instructions: "", to: "",
                capturedConnection: connection, currentConnection: current))
        }
    }
}
