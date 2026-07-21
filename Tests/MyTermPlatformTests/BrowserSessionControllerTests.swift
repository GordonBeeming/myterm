@preconcurrency import WebKit
import MyTermCore
@testable import MyTermPlatform
import XCTest

@MainActor
final class BrowserSessionControllerTests: XCTestCase {
    func testProfileIdentifierIsInstalledOnWebViewConfiguration() {
        let identifier = UUID()
        let controller = BrowserSessionController(
            profile: BrowserDataProfile(scope: .workspace, persistentStoreID: identifier)
        )

        XCTAssertEqual(controller.webView.configuration.websiteDataStore.identifier, identifier)
    }

    func testNamedStoresShareCookiesOnlyWithTheSameIdentifier() async throws {
        let sharedIdentifier = UUID()
        let isolatedIdentifier = UUID()
        await removeStore(sharedIdentifier)
        await removeStore(isolatedIdentifier)
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

        WKWebsiteDataStore.remove(forIdentifier: sharedIdentifier) { _ in }
        WKWebsiteDataStore.remove(forIdentifier: isolatedIdentifier) { _ in }

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
