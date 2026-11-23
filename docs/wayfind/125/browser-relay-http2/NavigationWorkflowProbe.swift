import Foundation
import Network
import WebKit

private enum NavigationWorkflowError: Error {
    case invalidURL, missingPopup, invalidScriptResult, timeout(String)
}

@MainActor private final class PopupInspector: Inspector, WKUIDelegate {
    var popup: WKWebView?
    var popupInspector: Inspector?
    var sharesWebsiteDataStore = false
    var didClosePopup = false

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        sharesWebsiteDataStore = configuration.websiteDataStore === webView.configuration.websiteDataStore
        let child = WKWebView(frame: .zero, configuration: configuration)
        let inspector = Inspector(server: server, exceptions: exceptions)
        child.navigationDelegate = inspector
        child.uiDelegate = self
        popupInspector = inspector
        popup = child
        return child
    }

    func webViewDidClose(_ webView: WKWebView) {
        if webView === popup { didClosePopup = true }
    }
}

@MainActor enum NavigationWorkflowProbe {
    static func run(relayHost: String, relayPort: UInt16, port: UInt16,
                    exception: ApprovedOrigin) async throws -> [String: Any] {
        guard let endpoint = URL(string: "https://\(relayHost):\(relayPort)"),
              let primary = URL(string: "https://myterm-route-probe.invalid:\(port)"),
              let secondary = URL(string: "https://other-route-probe.invalid:\(port)"),
              let otherHost = secondary.host else { throw NavigationWorkflowError.invalidURL }
        let otherException = ApprovedOrigin(server: exception.server, host: otherHost, port: Int(port),
                                            certificate: exception.certificate)
        let exceptions = [exception, otherException]
        let openerInspector = PopupInspector(server: exception.server, exceptions: exceptions)
        let secondClient = Inspector(server: exception.server, exceptions: exceptions)
        let opener = makeBrowser(endpoint: endpoint, inspector: openerInspector)
        let independentView = makeBrowser(endpoint: endpoint, inspector: secondClient)
        opener.uiDelegate = openerInspector
        let initialURL = primary.appendingPathComponent("navigation")
        opener.load(URLRequest(url: initialURL))
        independentView.load(URLRequest(url: initialURL))
        try await arrive(opener, inspector: openerInspector, title: "NAVIGATION_HOME")
        try await arrive(independentView, inspector: secondClient, title: "NAVIGATION_HOME")

        openerInspector.finished = false
        opener.load(URLRequest(url: primary.appendingPathComponent("login-start")))
        try await arrive(opener, inspector: openerInspector, title: "NAVIGATION_SIGNED_IN")
        let finalLoginURL = opener.url?.absoluteString ?? ""
        let cookieProof = try await loginProof(opener)
        let independentCookieProof = try await loginProof(independentView)
        let independentTitle = independentView.title ?? ""
        let independentCanGoBack = independentView.canGoBack

        let cors = try await opener.callAsyncJavaScript("""
            const allowed = await fetch(other + '/cors-ok').then(response => response.text());
            const denied = await fetch(other + '/cors-denied').then(() => false, () => true);
            return {allowed, denied};
            """, arguments: ["other": secondary.absoluteString], in: nil, contentWorld: .page)
        guard let corsResult = cors as? [String: Any] else { throw NavigationWorkflowError.invalidScriptResult }

        let webSockets = try await exerciseWebSockets(opener, destination: secondary)
        let webFeatures = try await exerciseWebFeatures(opener)

        _ = try await opener.evaluateJavaScript("document.getElementById('popup').click(); 'clicked';")
        try await waitFor("popup creation") { openerInspector.popup != nil }
        guard let popup = openerInspector.popup, let popupInspector = openerInspector.popupInspector else {
            throw NavigationWorkflowError.missingPopup
        }
        try await arrive(popup, inspector: popupInspector, title: "NAVIGATION_POPUP")
        try await waitFor("popup response") {
            try await opener.evaluateJavaScript("typeof window.fixturePopup !== 'undefined'") as? Bool == true
        }
        let postedFrom = try await opener.evaluateJavaScript("window.fixturePopup") as? String ?? ""
        let popupURL = popup.url?.absoluteString ?? ""
        _ = try await popup.evaluateJavaScript("window.close(); 'closed';")
        try await waitFor("popup close callback") { openerInspector.didClosePopup }
        let returnedToOpener = opener.url?.absoluteString == finalLoginURL && opener.title == "NAVIGATION_SIGNED_IN"

        openerInspector.finished = false
        opener.goBack()
        try await arrive(opener, inspector: openerInspector, title: "NAVIGATION_HOME")
        let historyBackURL = opener.url?.absoluteString ?? ""
        openerInspector.finished = false
        opener.goForward()
        try await arrive(opener, inspector: openerInspector, title: "NAVIGATION_SIGNED_IN")
        let historyForwardURL = opener.url?.absoluteString ?? ""

        return [
            "initialURL": initialURL.absoluteString,
            "finalLoginURL": finalLoginURL,
            "loginProof": cookieProof,
            "independentView": ["title": independentTitle, "canGoBack": independentCanGoBack, "loginProof": independentCookieProof],
            "cors": corsResult,
            "webSockets": webSockets,
            "webFeatures": webFeatures,
            "popup": ["url": popupURL, "sharedWebsiteDataStore": openerInspector.sharesWebsiteDataStore,
                      "messageOrigin": postedFrom, "returnedToOpener": returnedToOpener],
            "history": ["back": historyBackURL, "forward": historyForwardURL],
            "approvedCertificateHosts": Array(Set((openerInspector.challenges + popupInspector.challenges).compactMap {
                ($0["usedException"] as? Bool) == true ? $0["host"] as? String : nil
            })).sorted()
        ]
    }

    private static func exerciseWebFeatures(_ browser: WKWebView) async throws -> [String: Any] {
        let result = try await browser.callAsyncJavaScript("""
            const features = { file: typeof File, fileReader: typeof FileReader,
                indexedDB: typeof indexedDB, serviceWorker: typeof navigator.serviceWorker };
            if (typeof indexedDB === 'undefined') {
                features.indexedDBRoundTrip = false;
                return features;
            }
            features.indexedDBRoundTrip = await Promise.race([
                new Promise(resolve => {
                    const opened = indexedDB.open('myterm-fixture', 1);
                    opened.onupgradeneeded = () => opened.result.createObjectStore('session');
                    opened.onerror = () => resolve(false);
                    opened.onsuccess = () => {
                        const db = opened.result;
                        const update = db.transaction('session', 'readwrite');
                        update.objectStore('session').put('fixture-session', 'token');
                        update.onerror = () => { db.close(); resolve(false); };
                        update.oncomplete = () => {
                            const read = db.transaction('session', 'readonly').objectStore('session').get('token');
                            read.onsuccess = () => { db.close(); resolve(read.result === 'fixture-session'); };
                            read.onerror = () => { db.close(); resolve(false); };
                        };
                    };
                }),
                new Promise(resolve => setTimeout(() => resolve(false), 2000))
            ]);
            return features;
            """, arguments: [:], in: nil, contentWorld: .page)
        guard let features = result as? [String: Any] else { throw NavigationWorkflowError.invalidScriptResult }
        return features
    }

    private static func exerciseWebSockets(_ browser: WKWebView, destination: URL) async throws -> [String: Any] {
        guard var components = URLComponents(url: destination, resolvingAgainstBaseURL: false) else {
            throw NavigationWorkflowError.invalidURL
        }
        components.scheme = "wss"
        components.path = "/hot-reload"
        guard let url = components.url else { throw NavigationWorkflowError.invalidURL }
        let result = try await browser.callAsyncJavaScript("""
            const messages = [];
            try {
              for (const generation of [1, 2]) {
                await new Promise((resolve, reject) => {
                  const socket = new WebSocket(target + '?generation=' + generation);
                  const timeout = setTimeout(() => {
                    socket.close();
                    reject(new Error('timed out during generation ' + generation));
                  }, 2500);
                  socket.onmessage = event => {
                    messages.push(event.data);
                    socket.send('received-' + generation);
                  };
                  socket.onerror = () => {
                    if (messages.length !== generation) {
                      clearTimeout(timeout);
                      reject(new Error('socket error during generation ' + generation));
                    }
                  };
                  socket.onclose = () => {
                    clearTimeout(timeout);
                    if (messages.length === generation) resolve();
                    else reject(new Error('socket closed without a message'));
                  };
                });
              }
              return {messages, error: ''};
            } catch (error) { return {messages, error: String(error)}; }
            """, arguments: ["target": url.absoluteString], in: nil, contentWorld: .page)
        guard let decoded = result as? [String: Any] else { throw NavigationWorkflowError.invalidScriptResult }
        return decoded
    }

    private static func loginProof(_ browser: WKWebView) async throws -> [String: Any] {
        let result = try await browser.callAsyncJavaScript("""
            const response = await fetch('/login-proof');
            return {status: response.status, body: await response.text()};
            """, arguments: [:], in: nil, contentWorld: .page)
        guard let proof = result as? [String: Any] else { throw NavigationWorkflowError.invalidScriptResult }
        return proof
    }

    private static func makeBrowser(endpoint: URL, inspector: Inspector) -> WKWebView {
        var proxy = ProxyConfiguration(relayHops: [.init(http2RelayEndpoint: .url(endpoint))])
        proxy.allowFailover = false
        let store = WKWebsiteDataStore.nonPersistent()
        store.proxyConfigurations = [proxy]
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        if ProcessInfo.processInfo.environment["MYTERM_PROBE_LOCKDOWN"] == "1" {
            configuration.defaultWebpagePreferences.isLockdownModeEnabled = true
        }
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let browser = WKWebView(frame: .zero, configuration: configuration)
        browser.navigationDelegate = inspector
        return browser
    }

    private static func arrive(_ browser: WKWebView, inspector: Inspector, title: String) async throws {
        try await waitFor(title) {
            if let error = inspector.failure { throw error }
            return inspector.finished && browser.title == title
        }
    }

    private static func waitFor(_ description: String, condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(9)
        while ContinuousClock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw NavigationWorkflowError.timeout(description)
    }
}
