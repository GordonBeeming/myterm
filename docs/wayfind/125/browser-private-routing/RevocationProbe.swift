import Foundation
import Network
import WebKit

private enum FixtureFailure: Error { case configuration, timeout(String), invalidObservation }

@MainActor private final class FixtureNavigation: NSObject, WKNavigationDelegate {
    var loaded = false
    var failure: NSError?
    var status: Int?

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        status = (response.response as? HTTPURLResponse)?.statusCode
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failure = error as NSError
    }
}

private struct StreamObservation: Codable {
    let bytes: Int
    let outcome: String
}

@MainActor enum RevocationProbe {
    static func run(signalDirectory: URL = URL(fileURLWithPath: ".")) async throws -> Data {
        let env = ProcessInfo.processInfo.environment
        let form = env["MYTERM_PRIVATE_REVOCATION_TARGET"] ?? "private-ip"
        let endpointKey: String
        switch form {
        case "private-ip": endpointKey = "MYTERM_PRIVATE_IP"
        case "private-name": endpointKey = "MYTERM_PRIVATE_NAME"
        default: throw FixtureFailure.configuration
        }
        guard let relay = env["MYTERM_PRIVATE_PROXY"].flatMap(URL.init(string:)),
              let address = env[endpointKey], let port = env["MYTERM_PRIVATE_ORIGIN_PORT"],
              let origin = URL(string: "http://\(address):\(port)/private-route"),
              let mainToken = env["MYTERM_FIXTURE_ADMISSION"],
              let controlToken = env["MYTERM_FIXTURE_CONTROL_ADMISSION"] else { throw FixtureFailure.configuration }

        let revoked = try await open(relay: relay, token: mainToken, origin: origin, role: "revocation subject")
        let control = try await open(relay: relay, token: controlToken, origin: origin, role: "control")
        try await startStream(revoked)
        try await startStream(control)
        try await until("both streams delivered content") {
            let first = try await observation(revoked)
            let second = try await observation(control)
            return first.bytes >= 10 && second.bytes >= 10
        }
        let firstBefore = try await observation(revoked)
        let controlBefore = try await observation(control)
        try Data("ready\n".utf8).write(to: signalDirectory.appendingPathComponent("revocation-ready"), options: .atomic)
        try await until("Rust committed revocation") { FileManager.default.fileExists(atPath: signalDirectory.appendingPathComponent("revocation-committed").path) }
        try await until("revoked stream terminated") { try await observation(revoked).outcome != "running" }
        let firstAfter = try await observation(revoked)
        let controlAtRevocation = try await observation(control)
        try await until("unrevoked peer received further bytes") {
            try await observation(control).bytes > controlAtRevocation.bytes + 10
        }
        let controlAfter = try await observation(control)
        let refusedFresh = try await freshRequest(revoked)
        let acceptedFresh = try await freshRequest(control)
        let result: [String: Any] = [
            "targetForm": form,
            "revokedBefore": ["bytes": firstBefore.bytes, "outcome": firstBefore.outcome],
            "revokedAfter": ["bytes": firstAfter.bytes, "outcome": firstAfter.outcome],
            "controlBefore": ["bytes": controlBefore.bytes, "outcome": controlBefore.outcome],
            "controlAtRevocation": ["bytes": controlAtRevocation.bytes, "outcome": controlAtRevocation.outcome],
            "controlAfter": ["bytes": controlAfter.bytes, "outcome": controlAfter.outcome],
            "newRequestRevoked": refusedFresh, "newRequestControl": acceptedFresh
        ]
        return try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
    }

    private static func open(relay: URL, token: String, origin: URL, role: String) async throws -> WKWebView {
        let hop = ProxyConfiguration.RelayHop(http2RelayEndpoint: .url(relay),
                                               additionalHTTPHeaderFields: ["X-MyTerm-Fixture-Admission": token])
        var proxy = ProxyConfiguration(relayHops: [hop])
        proxy.allowFailover = false
        let dataStore = WKWebsiteDataStore.nonPersistent()
        dataStore.proxyConfigurations = [proxy]
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        let view = WKWebView(frame: .zero, configuration: configuration)
        let navigation = FixtureNavigation()
        view.navigationDelegate = navigation
        view.load(URLRequest(url: origin, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10))
        try await until("private origin loaded", duration: .seconds(10)) { navigation.loaded || navigation.failure != nil }
        if let failure = navigation.failure {
            fputs("Initial load for \(role) returned HTTP \(navigation.status ?? 0), navigation error \(failure.code)\n", stderr)
            throw failure
        }
        guard view.title == "RUST_PRIVATE_ORIGIN" else { throw FixtureFailure.invalidObservation }
        return view
    }

    private static func startStream(_ view: WKWebView) async throws {
        _ = try await view.evaluateJavaScript("""
            window.streamObservation = { bytes: 0, outcome: 'running' };
            (async () => {
                try {
                    const response = await fetch('/revocation-stream', {cache: 'no-store'});
                    if (!response.ok || !response.body) throw Error('stream response unavailable');
                    const reader = response.body.getReader();
                    while (true) {
                        const entry = await reader.read();
                        if (entry.done) break;
                        window.streamObservation.bytes += entry.value.byteLength;
                    }
                    window.streamObservation.outcome = 'completed';
                } catch {
                    window.streamObservation.outcome = 'interrupted';
                }
            })();
            'started';
            """)
    }

    private static func observation(_ view: WKWebView) async throws -> StreamObservation {
        guard let facts = try await view.evaluateJavaScript("JSON.stringify(window.streamObservation)") as? String else {
            throw FixtureFailure.invalidObservation
        }
        return try JSONDecoder().decode(StreamObservation.self, from: Data(facts.utf8))
    }

    private static func freshRequest(_ view: WKWebView) async throws -> String {
        let outcome = try await view.callAsyncJavaScript("""
            try {
                const result = await fetch('/private-route?after=revocation', {
                    cache:'no-store', signal:AbortSignal.timeout(2500)
                });
                return result.ok ? 'loaded' : 'denied';
            } catch (error) {
                return error.name === 'TimeoutError' ? 'timed-out' : 'interrupted';
            }
            """, arguments: [:], in: nil, contentWorld: .page)
        guard let value = outcome as? String else { throw FixtureFailure.invalidObservation }
        return value
    }

    private static func until(_ name: String, duration: Duration = .seconds(5),
                              condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + duration
        while ContinuousClock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(35))
        }
        throw FixtureFailure.timeout(name)
    }
}
