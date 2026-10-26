import Foundation
import XCTest
import UIKit
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
    func testNavigatedArtifactFileBecomesCapturedContextSourceRatherThanOriginalFile() throws {
        let original = URL(fileURLWithPath: "/private/tmp/browser-project/index.html")
        let artifactHost = "capture-test.myterm-artifact.invalid"
        let navigated = try XCTUnwrap(URL(string: "http://\(artifactHost)/docs/settings.html?tab=layout#spacing"))
        let source = try XCTUnwrap(RemoteBrowserView.captureSourceURL(navigated, source: original,
                                                                 artifactHost: artifactHost))
        let context = CompanionBrowserCapture(url: source.absoluteString, title: "Settings",
            selectedText: "Spacing", screenshot: nil, notes: []).context(instructions: "Fix this")
        XCTAssertEqual(source.path, "/private/tmp/browser-project/docs/settings.html")
        XCTAssertEqual(source.query, "tab=layout")
        XCTAssertEqual(source.fragment, "spacing")
        XCTAssertTrue(context.contains("URL: \(source.absoluteString)"))
        XCTAssertFalse(context.contains(original.absoluteString))
        let external = try XCTUnwrap(URL(string: "https://example.com/other"))
        XCTAssertEqual(RemoteBrowserView.captureSourceURL(external, source: original, artifactHost: artifactHost), external)
    }

    func testReplacementCaptureGetsItsOwnPreviewAndPreservesOriginalScreenshotBytes() throws {
        func png(_ color: UIColor) -> Data {
            UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { renderer in
                color.setFill()
                renderer.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
            }
        }
        let firstBytes = png(.red)
        let first = CompanionBrowserCapture(url: "https://example.com/first", title: "First",
            selectedText: "", screenshot: firstBytes, notes: [])
        let preview = try XCTUnwrap(first.previewImage)
        XCTAssertEqual(first.screenshot, firstBytes)
        let replacementBytes = png(.blue)
        let replacement = CompanionBrowserCapture(url: "https://example.com/second", title: "Second",
            selectedText: "", screenshot: replacementBytes, notes: [])
        XCTAssertNotEqual(first.id, replacement.id)
        XCTAssertFalse(replacement.previewImage === preview)
        XCTAssertEqual(replacement.screenshot, replacementBytes)
        XCTAssertNotEqual(replacementBytes, firstBytes)
        XCTAssertNotNil(replacement.previewImage)
    }

    func testMissingOrInvalidScreenshotHasNoPreviewAndKeepsItsOriginalData() {
        let invalid = Data("not an image".utf8)
        let capture = CompanionBrowserCapture(url: "https://example.com", title: "Invalid",
            selectedText: "", screenshot: invalid, notes: [])
        XCTAssertNil(capture.previewImage)
        XCTAssertEqual(capture.screenshot, invalid)
        XCTAssertNil(CompanionBrowserCapture(url: "https://example.com", title: "Missing",
            selectedText: "", screenshot: nil, notes: []).previewImage)
    }

    func testCaptureRejectsMissingUnsafeOrUnmappableArtifactSourceInsteadOfExposingTransportAddress() throws {
        let host = "capture-test.myterm-artifact.invalid"
        let artifact = try XCTUnwrap(URL(string: "http://\(host)/other.html"))
        let original = URL(fileURLWithPath: "/private/tmp/browser-project/index.html")
        XCTAssertNil(RemoteBrowserView.captureSourceURL(artifact, source: nil, artifactHost: host))
        XCTAssertNil(RemoteBrowserView.captureSourceURL(artifact, source: URL(string: "https://example.com"), artifactHost: host))
        XCTAssertNil(RemoteBrowserView.captureSourceURL(nil, source: original, artifactHost: host))
        let traversal = try XCTUnwrap(URL(string: "http://\(host)/../outside.html"))
        XCTAssertNil(RemoteBrowserView.captureSourceURL(traversal, source: original, artifactHost: host))
        let otherInternal = try XCTUnwrap(URL(string: "http://another.myterm-artifact.invalid/other.html"))
        XCTAssertNil(RemoteBrowserView.captureSourceURL(otherInternal, source: original, artifactHost: host))
    }

}
