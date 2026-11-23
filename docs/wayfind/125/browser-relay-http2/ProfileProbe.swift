import Foundation
import Network
import WebKit

@MainActor
enum ProfileProbe {
    static func run(url: URL, relayHost: String, primary: UInt16, secondary: UInt16) async throws -> [String: Any] {
        let secondaryID = UUID()
        var snapshot = try await inspect(url: url, relayHost: relayHost, primary: primary, secondary: secondary,
                                         secondaryID: secondaryID)
        #if os(iOS)
        snapshot["secondaryStoreID"] = secondaryID.uuidString
        #endif
        return snapshot
    }

    static func reopen(url: URL, relayHost: String, port: UInt16, identifier: UUID) async throws -> [String: String] {
        let profile = try store(relayHost: relayHost, port: port, identifier: identifier)
        return try await snapshot(open(url, store: profile))
    }

    private static func inspect(url: URL, relayHost: String, primary: UInt16, secondary: UInt16,
                                secondaryID: UUID) async throws -> [String: Any] {
        let firstStore = try store(relayHost: relayHost, port: primary)
        let secondStore = try store(relayHost: relayHost, port: secondary, identifier: secondaryID)
        let first = try await open(url, store: firstStore)
        _ = try await first.evaluateJavaScript("""
            document.cookie = 'myterm_profile=A; Max-Age=300; SameSite=Lax';
            localStorage.setItem('myterm_profile', 'A');
            sessionStorage.setItem('myterm_profile', 'A');
            'done';
            """)

        let second = try await open(url, store: secondStore)
        let secondBeforeWrite = try await snapshot(second)
        _ = try await second.evaluateJavaScript("""
            document.cookie = 'myterm_profile=B; Max-Age=300; SameSite=Lax';
            localStorage.setItem('myterm_profile', 'B');
            'done';
            """)
        let firstAfterSecondWrite = try await snapshot(first)
        let secondAfterWrite = try await snapshot(second)

        let firstReopened = try await open(url, store: firstStore)
        let firstAfterReopen = try await snapshot(firstReopened)
        _ = try await firstReopened.evaluateJavaScript("""
            document.cookie = 'myterm_profile=; Max-Age=0; SameSite=Lax';
            localStorage.removeItem('myterm_profile');
            'done';
            """)
        let firstAfterDeletion = try await snapshot(firstReopened)
        let secondAfterFirstDeletion = try await snapshot(second)
        guard let host = url.host,
              let nativeCookie = HTTPCookie(properties: [
                .name: "myterm_native_profile",
                .value: "B",
                .domain: host,
                .path: "/",
                .expires: Date().addingTimeInterval(300)
              ]) else {
            throw NSError(domain: "Native profile cookie fixture", code: 4)
        }
        await secondStore.httpCookieStore.setCookie(nativeCookie)
        let preRestartCookies = await secondStore.httpCookieStore.allCookies().map {
            ["name": $0.name, "value": $0.value, "sessionOnly": String($0.isSessionOnly)]
        }

        return ["url": url.absoluteString,
                "preRestartCookies": preRestartCookies,
                "secondBeforeWrite": secondBeforeWrite,
                "firstAfterSecondWrite": firstAfterSecondWrite,
                "secondAfterWrite": secondAfterWrite,
                "firstAfterReopen": firstAfterReopen,
                "firstAfterDeletion": firstAfterDeletion,
                "secondAfterFirstDeletion": secondAfterFirstDeletion]
    }

    private static func store(relayHost: String, port: UInt16, identifier: UUID = UUID()) throws -> WKWebsiteDataStore {
        guard let endpoint = URL(string: "https://\(relayHost):\(port)") else {
            throw NSError(domain: "Profile relay endpoint", code: 1)
        }
        var proxy = ProxyConfiguration(relayHops: [.init(http2RelayEndpoint: .url(endpoint))])
        proxy.allowFailover = false
        #if os(iOS)
        let store = WKWebsiteDataStore(forIdentifier: identifier)
        #else
        let store = WKWebsiteDataStore.nonPersistent()
        #endif
        store.proxyConfigurations = [proxy]
        return store
    }

    private static func open(_ url: URL, store: WKWebsiteDataStore) async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        let browser = WKWebView(frame: .zero, configuration: configuration)
        let navigation = Navigation(expectedCertificate: Data())
        browser.navigationDelegate = navigation
        browser.load(URLRequest(url: url, timeoutInterval: 8))
        let deadline = ContinuousClock.now + .seconds(10)
        while !navigation.finished && navigation.error == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        browser.navigationDelegate = nil
        if let error = navigation.error { throw error }
        guard navigation.finished else { throw NSError(domain: "Profile navigation timed out", code: 2) }
        return browser
    }

    private static func snapshot(_ browser: WKWebView) async throws -> [String: String] {
        let script = """
            ({
              title: document.title,
              origin: location.origin,
              cookie: document.cookie,
              local: localStorage.getItem('myterm_profile') || '',
              session: sessionStorage.getItem('myterm_profile') || ''
            })
            """
        guard let state = try await browser.evaluateJavaScript(script) as? [String: String] else {
            throw NSError(domain: "Profile snapshot result", code: 3)
        }
        return state
    }
}
