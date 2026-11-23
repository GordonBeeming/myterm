import AppKit
import Foundation
import Network
import WebKit

private enum ArtifactProbeError: Error {
    case missingConfiguration, relayStartup, invalidPage
}

private struct ArtifactRelay {
    let process: Process
    let port: UInt16

    init(originPort: UInt16, originHost: String, certificate: String, key: String) throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("relay")
        process.arguments = ["--cert", certificate, "--key", key, "--origin-fixture-port", String(originPort),
                             "--artifact-fixture-host", originHost]
        process.standardOutput = output
        try process.run()
        let bytes = output.fileHandleForReading.availableData
        guard let port = UInt16(String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else {
            if process.isRunning { process.terminate() }
            throw ArtifactProbeError.relayStartup
        }
        self.process = process
        self.port = port
    }

    func stop() {
        if process.isRunning { process.terminate() }
    }
}

@MainActor private final class ArtifactNavigation: NSObject, WKNavigationDelegate {
    var finished = false
    var error: NSError?
    var status = 0

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        status = (navigationResponse.response as? HTTPURLResponse)?.statusCode ?? 0
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.error = error as NSError
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.error = error as NSError
    }
}

@main struct ArtifactProbe {
    @MainActor static func main() async {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        do {
            let result = try await run()
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } catch {
            fputs("Artifact fixture failed: \(error)\n", stderr)
            exit(1)
        }
    }

    @MainActor private static func run() async throws -> [String: Any] {
        let environment = ProcessInfo.processInfo.environment
        guard let relayHost = environment["MYTERM_RELAY_HOST"], let certificate = environment["MYTERM_RELAY_CERT"],
              let key = environment["MYTERM_RELAY_KEY"] else { throw ArtifactProbeError.missingConfiguration }
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let host = UUID().uuidString.lowercased() + "." + CompanionBrowserArtifact.hostname
        let unregisteredHost = UUID().uuidString.lowercased() + "." + CompanionBrowserArtifact.hostname
        let first = try createServer(directory: directory.appendingPathComponent("granted-a"), title: "ARTIFACT_A", scripts: false)
        let second = try createServer(directory: directory.appendingPathComponent("granted-b"), title: "ARTIFACT_B", scripts: true)
        try await first.registerVirtualOrigin(host)
        try await second.registerVirtualOrigin(host)
        let (_, firstPort) = try await first.endpoint()
        let (_, secondPort) = try await second.endpoint()
        let firstRelay = try ArtifactRelay(originPort: firstPort, originHost: host, certificate: certificate, key: key)
        defer { firstRelay.stop() }
        let secondRelay = try ArtifactRelay(originPort: secondPort, originHost: host, certificate: certificate, key: key)
        defer { secondRelay.stop() }
        let rejectedRelay = try ArtifactRelay(originPort: firstPort, originHost: unregisteredHost, certificate: certificate, key: key)
        defer { rejectedRelay.stop() }

        let firstBrowser = try browser(relayHost: relayHost, port: firstRelay.port)
        let secondBrowser = try browser(relayHost: relayHost, port: secondRelay.port)
        let unregisteredBrowser = try browser(relayHost: relayHost, port: rejectedRelay.port)
        let firstLoad = try await load(firstBrowser, host: host)
        let secondLoad = try await load(secondBrowser, host: host)
        let firstPage = try await readPage(firstBrowser)
        let secondPage = try await readPage(secondBrowser)
        let mutation = try await secondBrowser.callAsyncJavaScript("""
            const paths = ['/outside.txt', '/linked.txt'];
            const denied = {};
            for (const path of paths) denied[path] = (await fetch(path)).status;
            const write = await fetch('/index.html', {method: 'POST', body: 'new bytes'});
            return {denied, write: write.status};
            """, arguments: [:], in: nil, contentWorld: .page)
        let unregistered = try await load(unregisteredBrowser, host: unregisteredHost)
        await first.close()
        let revoked = try await load(firstBrowser, host: host, nonce: "revoked")
        let otherStillGranted = try await load(secondBrowser, host: host, nonce: "other")
        await second.close()
        return [
            "firstLoad": firstLoad, "secondLoad": secondLoad,
            "firstPage": firstPage, "secondPage": secondPage,
            "fileBoundaries": mutation as? [String: Any] ?? [:],
            "unregistered": unregistered, "revoked": revoked, "otherStillGranted": otherStillGranted
        ]
    }

    private static func createServer(directory: URL, title: String, scripts: Bool) throws -> CompanionBrowserArtifactServer {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("assets"), withIntermediateDirectories: true)
        let outside = directory.deletingLastPathComponent().appendingPathComponent("outside.txt")
        try Data("OUTSIDE_THE_GRANT".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("linked.txt"), withDestinationURL: outside)
        let html = directory.appendingPathComponent("index.html")
        let markup = """
            <!doctype html><title>\(title)</title>
            <link rel="stylesheet" href="assets/style.css">
            <p id="marker">Relative resource fixture</p>
            <script>document.documentElement.dataset.scriptRan = 'yes';</script>
            """
        try Data(markup.utf8).write(to: html)
        try Data("#marker {color: rgb(26, 97, 162)}".utf8).write(to: directory.appendingPathComponent("assets/style.css"))
        return CompanionBrowserArtifactServer(artifact: try CompanionBrowserArtifact(selectedFile: html, allowsJavaScript: scripts))
    }

    @MainActor private static func browser(relayHost: String, port: UInt16) throws -> WKWebView {
        guard let endpoint = URL(string: "https://\(relayHost):\(port)") else { throw ArtifactProbeError.missingConfiguration }
        var proxy = ProxyConfiguration(relayHops: [.init(http2RelayEndpoint: .url(endpoint))])
        proxy.allowFailover = false
        let store = WKWebsiteDataStore.nonPersistent()
        store.proxyConfigurations = [proxy]
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        return WKWebView(frame: .zero, configuration: configuration)
    }

    @MainActor private static func load(_ browser: WKWebView, host: String, nonce: String = "initial") async throws -> [String: Any] {
        guard let url = URL(string: "http://\(host)/index.html?phase=\(nonce)") else { throw ArtifactProbeError.missingConfiguration }
        let inspector = ArtifactNavigation()
        browser.navigationDelegate = inspector
        defer { browser.navigationDelegate = nil }
        browser.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6))
        let deadline = ContinuousClock.now + .seconds(7)
        while !inspector.finished && inspector.error == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        return ["status": inspector.status, "finished": inspector.finished, "error": inspector.error?.code ?? 0,
                "title": browser.title ?? ""]
    }

    @MainActor private static func readPage(_ browser: WKWebView) async throws -> [String: String] {
        let state = try await browser.evaluateJavaScript("""
            ({
              color: getComputedStyle(document.getElementById('marker')).color,
              scriptRan: document.documentElement.dataset.scriptRan || '',
              origin: location.origin
            })
            """)
        guard let facts = state as? [String: String] else { throw ArtifactProbeError.invalidPage }
        return facts
    }
}
