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

    func testBrowserContentAcceptsTheClickThatActivatesTheApp() {
        let controller = BrowserSessionController()

        XCTAssertTrue(controller.webView.acceptsFirstMouse(for: nil))
        XCTAssertTrue(BrowserSessionHostView(contentView: controller.webView, isActive: false).acceptsFirstMouse(for: nil))
    }

    func testPluginHandledLoadsAreNotPresentedAsNavigationErrors() {
        let controller = BrowserSessionController()
        let handledLoad = NSError(
            domain: "WebKitErrorDomain",
            code: 204,
            userInfo: [NSLocalizedDescriptionKey: "Plug-in handled load"]
        )
        let realFailure = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotOpenFile)

        XCTAssertTrue(BrowserSessionController.isHandledContentNavigation(handledLoad))
        XCTAssertFalse(BrowserSessionController.isHandledContentNavigation(realFailure))

        controller.webView(controller.webView, didFail: nil, withError: handledLoad)
        XCTAssertNil(controller.state.errorDescription)

        controller.webView(controller.webView, didFail: nil, withError: realFailure)
        XCTAssertEqual(controller.state.errorDescription, realFailure.localizedDescription)
    }

    @MainActor
    func testBrowserHostReplacesDisplayedSessionAndTransfersFocus() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let originalBrowser = FocusableBrowserTestView()
        let replacementBrowser = FocusableBrowserTestView()
        let host = BrowserSessionHostView(contentView: originalBrowser, isActive: false)
        window.contentView = host

        XCTAssertTrue(window.makeFirstResponder(originalBrowser))

        host.update(contentView: replacementBrowser, isActive: true)

        XCTAssertNil(originalBrowser.superview)
        XCTAssertTrue(host.owns(replacementBrowser))
        XCTAssertTrue(window.firstResponder === replacementBrowser)
    }

    @MainActor
    func testBrowserHostTransfersFocusHeldByAWebViewDescendant() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let originalBrowser = FocusableBrowserTestView()
        let focusedWebContent = FocusableBrowserTestView()
        originalBrowser.addSubview(focusedWebContent)
        let replacementBrowser = FocusableBrowserTestView()
        let host = BrowserSessionHostView(contentView: originalBrowser, isActive: false)
        window.contentView = host

        XCTAssertTrue(window.makeFirstResponder(focusedWebContent))

        host.update(contentView: replacementBrowser, isActive: true)

        XCTAssertNil(originalBrowser.superview)
        XCTAssertTrue(host.owns(replacementBrowser))
        XCTAssertTrue(window.firstResponder === replacementBrowser)
    }

    @MainActor
    func testBrowserHostReportsWebViewDescendantFocusOncePerTransition() {
        let browserView = FocusableBrowserTestView()
        let focusedWebContent = FocusableBrowserTestView()
        browserView.addSubview(focusedWebContent)
        let otherView = FocusableBrowserTestView()
        var focusCount = 0
        let host = BrowserSessionHostView(
            contentView: browserView,
            isActive: false,
            onFocused: { focusCount += 1 }
        )
        let container = NSView(frame: .zero)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        container.addSubview(host)
        container.addSubview(otherView)

        XCTAssertTrue(window.makeFirstResponder(focusedWebContent))
        XCTAssertEqual(focusCount, 1)

        XCTAssertTrue(window.makeFirstResponder(focusedWebContent))
        XCTAssertEqual(focusCount, 1)

        XCTAssertTrue(window.makeFirstResponder(otherView))
        XCTAssertTrue(window.makeFirstResponder(focusedWebContent))
        XCTAssertEqual(focusCount, 2)
    }

    @MainActor
    func testBrowserHostDoesNotRemoveContentReparentedByAnotherHost() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let movedBrowser = FocusableBrowserTestView()
        let sourceReplacement = FocusableBrowserTestView()
        let destinationBrowser = FocusableBrowserTestView()
        let sourceHost = BrowserSessionHostView(contentView: movedBrowser, isActive: false)
        let destinationHost = BrowserSessionHostView(contentView: destinationBrowser, isActive: false)
        let container = NSView(frame: .zero)
        window.contentView = container
        container.addSubview(sourceHost)
        container.addSubview(destinationHost)

        destinationHost.update(contentView: movedBrowser, isActive: true)
        XCTAssertTrue(window.makeFirstResponder(movedBrowser))

        XCTAssertFalse(sourceHost.owns(movedBrowser))
        XCTAssertFalse(sourceHost.subviews.contains { $0 === movedBrowser })
        XCTAssertFalse(sourceHost.constraints.contains { constraint in
            constraint.isActive && (
                (constraint.firstItem as AnyObject?) === movedBrowser
                    || (constraint.secondItem as AnyObject?) === movedBrowser
            )
        })

        sourceHost.update(contentView: sourceReplacement, isActive: false)

        XCTAssertTrue(destinationHost.owns(movedBrowser))
        XCTAssertTrue(sourceHost.owns(sourceReplacement))
        XCTAssertTrue(window.firstResponder === movedBrowser)
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

    func testMiddleClickNewWindowRequestUsesNewTabCallback() throws {
        let controller = BrowserSessionController()
        let expectedURL = try XCTUnwrap(URL(string: "https://example.com/middle-click"))
        var requestedURL: URL?
        controller.onNewTabRequest = { requestedURL = $0 }

        controller.handleNewWindowRequest(
            URLRequest(url: expectedURL),
            buttonNumber: 2
        )

        XCTAssertEqual(requestedURL, expectedURL)
        XCTAssertNil(controller.webView.url)
    }

    func testMiddleClickHitTestsAnOrdinarySameFrameLink() async throws {
        let controller = BrowserSessionController()
        let webView = try XCTUnwrap(controller.webView as? MyTermWebView)
        webView.frame = NSRect(x: 0, y: 0, width: 320, height: 200)
        await loadHTML(
            "<a href='https://example.com/middle-click' style='position:fixed;inset:0'>Open</a>",
            in: webView
        )
        let expectedURL = try XCTUnwrap(URL(string: "https://example.com/middle-click"))
        var requestedURL: URL?
        controller.onNewTabRequest = { requestedURL = $0 }

        let handled = await withCheckedContinuation { continuation in
            webView.openLinkUnderMiddleClick(at: CGPoint(x: 20, y: 180)) {
                continuation.resume(returning: $0)
            }
        }

        XCTAssertTrue(handled)
        XCTAssertEqual(requestedURL, expectedURL)
        XCTAssertEqual(webView.url?.host, "myterm.test")
    }

    func testMiddleClickWithoutALinkAlwaysCallsCompletion() async throws {
        let controller = BrowserSessionController()
        let webView = try XCTUnwrap(controller.webView as? MyTermWebView)
        webView.frame = NSRect(x: 0, y: 0, width: 320, height: 200)
        await loadHTML("<p>No link here</p>", in: webView)

        let handled = await withCheckedContinuation { continuation in
            webView.openLinkUnderMiddleClick(at: CGPoint(x: 20, y: 180)) {
                continuation.resume(returning: $0)
            }
        }

        XCTAssertFalse(handled)
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

    func testLocalFileJavaScriptCanBeEnabledExplicitly() {
        let controller = BrowserSessionController(allowsLocalFileJavaScript: true)
        let localPreferences = WKWebpagePreferences()
        var localDecision: WKNavigationActionPolicy?

        controller.decideNavigationPolicy(
            for: URL(fileURLWithPath: "/tmp/local.html"),
            preferences: localPreferences
        ) { policy, preferences in
            localDecision = policy
            XCTAssertTrue(preferences.allowsContentJavaScript)
        }

        XCTAssertEqual(localDecision, .allow)
    }

    func testEnabledLocalFileJavaScriptRunsPageAuthoredScript() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "myterm-local-page-script-test-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "index.html", directoryHint: .notDirectory)
        try Data(
            "<html><head><title>Before script</title><script>document.title = 'Script ran'</script></head></html>".utf8
        ).write(to: fileURL)
        let controller = BrowserSessionController(allowsLocalFileJavaScript: true)

        try controller.load(url: fileURL)

        let didLoad = try await waitUntilLoaded(fileURL, in: controller.webView)
        XCTAssertTrue(didLoad)
        let didRunScript = try await waitUntil(
            "the local page's authored script to update the title"
        ) {
            controller.webView.title == "Script ran"
        }
        XCTAssertTrue(didRunScript)
    }

    func testChangingLocalFileJavaScriptDoesNotReloadANonFilePage() {
        let controller = BrowserSessionController()

        controller.allowsLocalFileJavaScript = true

        XCTAssertNil(controller.lastAction)
    }

    func testChangingLocalFileJavaScriptReloadsAnOpenFilePage() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "myterm-local-js-test-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "index.html", directoryHint: .notDirectory)
        try Data("<html><body>Local file</body></html>".utf8).write(to: fileURL)
        let controller = BrowserSessionController()

        try controller.load(url: fileURL)
        let didLoad = try await waitUntilLoaded(fileURL, in: controller.webView)
        XCTAssertTrue(didLoad, "Timed out waiting for local WebKit navigation")
        guard didLoad else { return }
        controller.allowsLocalFileJavaScript = true

        XCTAssertEqual(controller.lastAction, .reload)
    }

    func testBrowserActionsAreObservableAndZoomIsBounded() {
        let controller = BrowserSessionController()

        XCTAssertGreaterThanOrEqual(controller.state.estimatedProgress, 0)
        XCTAssertLessThanOrEqual(controller.state.estimatedProgress, 1)

        controller.reload()
        XCTAssertEqual(controller.lastAction, .reload)
        controller.reloadFromOrigin()
        XCTAssertEqual(controller.lastAction, .reloadFromOrigin)
        controller.stopLoading()
        XCTAssertEqual(controller.lastAction, .stop)
        controller.find("MyTerm")
        XCTAssertEqual(controller.lastAction, .find(query: "MyTerm", backwards: false))

        controller.webView.pageZoom = 1
        controller.zoomIn()
        XCTAssertEqual(controller.lastAction, .zoomIn)
        XCTAssertEqual(controller.webView.pageZoom, 1.1, accuracy: 0.0001)
        controller.zoomOut()
        XCTAssertEqual(controller.lastAction, .zoomOut)
        XCTAssertEqual(controller.webView.pageZoom, 1, accuracy: 0.0001)
        controller.webView.pageZoom = 2
        controller.resetZoom()
        XCTAssertEqual(controller.lastAction, .resetZoom)
        XCTAssertEqual(controller.webView.pageZoom, 1, accuracy: 0.0001)
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

    private func waitUntilLoaded(_ url: URL, in webView: WKWebView) async throws -> Bool {
        try await waitUntil("the WebKit navigation to finish") {
            webView.url == url && !webView.isLoading
        }
    }

    private func waitUntil(
        _ description: String,
        condition: @escaping @MainActor () -> Bool
    ) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !condition() {
            guard clock.now < deadline else { return false }
            try await Task.sleep(for: .milliseconds(10))
        }
        return true
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
