import AppKit
@preconcurrency import WebKit
import MyTermCore
@testable import MyTermPlatform
import XCTest

@MainActor
final class BrowserSessionControllerTests: XCTestCase {
    @MainActor
    func testActiveBrowserHostFocusesOnAttachmentWithoutStealingToolbarFocus() {
        let browserView = FocusableBrowserTestView()
        let host = BrowserSessionHostView(contentView: browserView, isActive: true)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host

        XCTAssertTrue(window.firstResponder === browserView)

        let otherView = FocusableBrowserTestView()
        host.addSubview(otherView)
        host.setPaneActive(false)
        window.makeFirstResponder(otherView)
        host.setPaneActive(true)

        XCTAssertTrue(window.firstResponder === otherView)
    }

    func testWritingToolsOverlayIsDisabled() {
        let controller = BrowserSessionController()

        if #available(macOS 15.0, *) {
            XCTAssertEqual(
                controller.webView.configuration.value(forKey: "writingToolsBehavior") as? Int,
                NSWritingToolsBehavior.none.rawValue
            )
        }
    }

    func testProfileIdentifierIsInstalledOnWebViewConfiguration() {
        let identifier = UUID()
        let controller = BrowserSessionController(
            profile: BrowserDataProfile(scope: .workspace, persistentStoreID: identifier)
        )

        XCTAssertEqual(controller.webView.configuration.websiteDataStore.identifier, identifier)
    }

    func testFileLoadsUseTheContainingDirectoryAsTheReadBoundary() throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "myterm-browser-test-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "index.html", directoryHint: .notDirectory)
        try Data("<html><body>MyTerm</body></html>".utf8).write(to: fileURL)
        let controller = BrowserSessionController()

        XCTAssertEqual(
            BrowserSessionController.fileReadAccessBoundary(for: fileURL),
            directory
        )
        XCTAssertNoThrow(try controller.load(url: fileURL))
    }

    func testUIDelegateCloseRequestsUseTheNarrowCallback() {
        let controller = BrowserSessionController()
        var callbackCount = 0
        controller.onCloseRequest = { callbackCount += 1 }

        controller.webViewDidClose(controller.webView)

        XCTAssertEqual(callbackCount, 1)
    }

    func testTargetBlankNavigationLoadsInTheExistingWebView() async {
        let controller = BrowserSessionController()
        let initialWaiter = NavigationWaiter()
        controller.webView.navigationDelegate = initialWaiter
        await withCheckedContinuation { continuation in
            initialWaiter.continuation = continuation
            controller.webView.loadHTMLString(
                "<a id='next' target='_blank' href='data:text/html,%3Ctitle%3ENext%20Page%3C%2Ftitle%3E'>Next</a>",
                baseURL: URL(string: "https://myterm.test")
            )
        }

        let nextWaiter = NavigationWaiter()
        controller.webView.navigationDelegate = nextWaiter
        await withCheckedContinuation { continuation in
            nextWaiter.continuation = continuation
            controller.webView.evaluateJavaScript("document.getElementById('next').click()")
        }

        XCTAssertEqual(controller.webView.url?.scheme, "data")
    }

    func testLocalFileNavigationsDisableJavaScriptWhileWebNavigationsKeepItEnabled() throws {
        let controller = BrowserSessionController()
        let localPreferences = WKWebpagePreferences()
        var localDecision: WKNavigationActionPolicy?
        controller.decideNavigationPolicy(
            for: URL(fileURLWithPath: "/tmp/local.html"),
            preferences: localPreferences
        ) { policy, preferences in
            localDecision = policy
            XCTAssertFalse(preferences.allowsContentJavaScript)
        }
        XCTAssertEqual(localDecision, .allow)

        let webPreferences = WKWebpagePreferences()
        webPreferences.allowsContentJavaScript = false
        var webDecision: WKNavigationActionPolicy?
        controller.decideNavigationPolicy(
            for: try XCTUnwrap(URL(string: "https://example.com")),
            preferences: webPreferences
        ) { policy, preferences in
            webDecision = policy
            XCTAssertTrue(preferences.allowsContentJavaScript)
        }
        XCTAssertEqual(webDecision, .allow)
    }

    func testNamedStoresShareCookiesOnlyWithTheSameIdentifier() async throws {
        let sharedIdentifier = UUID()
        let isolatedIdentifier = UUID()
        let cookieName = "myterm-profile-test"
        let cookieValue = UUID().uuidString

        let results: (matching: String, isolated: String) = await {
            let sharedProfile = BrowserDataProfile(scope: .workspace, persistentStoreID: sharedIdentifier)
            let firstController = BrowserSessionController(profile: sharedProfile)
            await loadHTML(
                "<script>document.cookie = '\(cookieName)=\(cookieValue); path=/; Secure';</script>",
                in: firstController.webView
            )
            let secondController = BrowserSessionController(profile: sharedProfile)
            let isolatedController = BrowserSessionController(
                profile: BrowserDataProfile(scope: .workspace, persistentStoreID: isolatedIdentifier)
            )
            await loadHTML("", in: secondController.webView)
            await loadHTML("", in: isolatedController.webView)
            return (
                await documentCookie(in: secondController.webView),
                await documentCookie(in: isolatedController.webView)
            )
        }()

        await removeStore(sharedIdentifier)
        await removeStore(isolatedIdentifier)

        XCTAssertTrue(results.matching.contains("\(cookieName)=\(cookieValue)"))
        XCTAssertFalse(results.isolated.contains("\(cookieName)=\(cookieValue)"))
    }

    private func loadHTML(_ html: String, in webView: WKWebView) async {
        let waiter = NavigationWaiter()
        webView.navigationDelegate = waiter
        await withCheckedContinuation { continuation in
            waiter.continuation = continuation
            webView.loadHTMLString(html, baseURL: URL(string: "https://myterm.test"))
        }
    }

    private func documentCookie(in webView: WKWebView) async -> String {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript("document.cookie") { value, _ in
                continuation.resume(returning: value as? String ?? "")
            }
        }
    }

    private func removeStore(_ identifier: UUID) async {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.remove(forIdentifier: identifier) { _ in
                continuation.resume()
            }
        }
    }
}

private final class FocusableBrowserTestView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

@MainActor
private final class NavigationWaiter: NSObject, WKNavigationDelegate {
    var continuation: CheckedContinuation<Void, Never>?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume()
        continuation = nil
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        continuation?.resume()
        continuation = nil
    }
}
