import AppKit
import Foundation
import MyTermPlatform
import XCTest

final class BrowserContextCaptureTests: XCTestCase {
    func testDraftIncludesOnlyExplicitContextAndOptionalLocalScreenshotPath() throws {
        let url = try XCTUnwrap(URL(string: "https://example.test/page"))
        let capture = BrowserContextCapture(url: url, title: "Page title", selectedText: "Selected words", screenshotPNG: Data([1]))
        XCTAssertEqual(capture.draft(), "Page: https://example.test/page\n\nTitle: Page title\n\nSelected page text:\nSelected words")
        XCTAssertTrue(capture.draft(screenshotPath: "/tmp/context.png").contains("Screenshot file on this Mac (read this image): /tmp/context.png"))
    }

    func testEmptySelectionDoesNotClaimWholePageText() throws {
        let capture = BrowserContextCapture(url: try XCTUnwrap(URL(string: "https://example.test")),
            title: "Page", selectedText: "", screenshotPNG: Data())
        XCTAssertFalse(capture.draft().contains("Selected page text"))
        XCTAssertFalse(capture.draft().contains("Screenshot"))
    }
    @MainActor
    func testCaptureReadsSelectedTextAndProducesRealPNGWithoutPresentingWindow() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "browser-capture-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = directory.appending(path: "fixture.html")
        try "<html><head><title>Capture fixture</title></head><body><p id='context'>Selected context</p></body></html>"
            .write(to: page, atomically: true, encoding: .utf8)
        let controller = BrowserSessionController(allowsLocalFileJavaScript: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.webView
        try controller.load(url: page)
        let deadline = Date().addingTimeInterval(10)
        while controller.webView.isLoading || controller.webView.title != "Capture fixture" {
            guard Date() < deadline else { return XCTFail("Fixture did not load") }
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try await controller.webView.evaluateJavaScript("const range = document.createRange(); range.selectNodeContents(document.getElementById('context')); window.getSelection().removeAllRanges(); window.getSelection().addRange(range);")
        let capture = try await controller.captureContext()
        XCTAssertEqual(capture.url, page)
        XCTAssertEqual(capture.title, "Capture fixture")
        XCTAssertEqual(capture.selectedText, "Selected context")
        XCTAssertTrue(capture.screenshotPNG.starts(with: [0x89, 0x50, 0x4e, 0x47]))
        XCTAssertFalse(window.isVisible)
        controller.webView.stopLoading()
        window.contentView = nil
    }

}
