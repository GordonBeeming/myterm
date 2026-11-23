import CryptoKit
import Foundation
import Network
import WebKit

private enum TransferFixtureError: Error {
    case invalidURL, navigation, timeout(String)
}

@MainActor private final class TransferInspector: Inspector, WKUIDelegate, WKDownloadDelegate {
    let fileToUpload: URL?
    let downloadPath: URL
    var openPanelRequests = 0
    var suggestedFilename = ""
    var download: WKDownload?
    var downloadPolicyResponses = 0
    var downloadAuthChallenges = 0
    var downloadFinished = false
    var downloadError: NSError?

    init(exception: ApprovedOrigin, fileToUpload: URL?, downloadPath: URL) {
        self.fileToUpload = fileToUpload
        self.downloadPath = downloadPath
        super.init(server: exception.server, exceptions: [exception])
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        openPanelRequests += 1
        completionHandler(fileToUpload.map { [$0] })
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.response.mimeType == "application/octet-stream" {
            downloadPolicyResponses += 1
            decisionHandler(.download)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        trackDownload(download)
    }

    func trackDownload(_ download: WKDownload) {
        self.download = download
        download.delegate = self
    }

    func download(_ download: WKDownload, didReceive challenge: URLAuthenticationChallenge,
                  completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        downloadAuthChallenges += 1
        respondToChallenge(challenge, completionHandler: completionHandler)
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        self.suggestedFilename = suggestedFilename
        completionHandler(downloadPath)
    }

    func downloadDidFinish(_ download: WKDownload) { downloadFinished = true }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloadError = error as NSError
    }
}

@MainActor enum TransferProbe {
    private static let fixtureSize = 8 * 1024 * 1024

    static func run(relayHost: String, relayPort: UInt16, port: UInt16,
                    exception: ApprovedOrigin, directDownload: Bool = false) async throws -> [String: Any] {
        guard let endpoint = URL(string: "https://\(relayHost):\(relayPort)"),
              let origin = URL(string: "https://myterm-route-probe.invalid:\(port)") else {
            throw TransferFixtureError.invalidURL
        }
        #if os(iOS)
        let directory = URL.documentsDirectory
        #else
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        #endif
        let file = directory.appendingPathComponent("upload-fixture.bin")
        let payload = Data(repeating: 0x5a, count: fixtureSize)
        try payload.write(to: file)
        let expectedDigest = digest(payload)
        var result: [String: Any] = [
            "fixtureBytes": fixtureSize, "fixtureSHA256": expectedDigest,
            "downloadInitiation": directDownload ? "startDownload" : "navigationResponse"
        ]
        for mode in ["accept", "cancel", "reject"] {
            do {
                let inspector = TransferInspector(exception: exception, fileToUpload: mode == "cancel" ? nil : file,
                                                  downloadPath: directory.appendingPathComponent("unused.bin"))
                let browser = makeBrowser(endpoint: endpoint, inspector: inspector)
                let url = try target(origin, path: "transfer", mode: mode)
                browser.load(URLRequest(url: url))
                try await waitFor("upload page \(mode)") { inspector.finished || inspector.failure != nil }
                guard inspector.finished else { throw inspector.failure ?? TransferFixtureError.navigation }
                _ = try await browser.evaluateJavaScript("document.getElementById('file').click(); 'requested';")
                try await waitFor("open-panel delegate \(mode)") { inspector.openPanelRequests == 1 }
                if mode == "cancel" {
                    try await Task.sleep(for: .milliseconds(350))
                } else {
                    try await waitFor("upload reply \(mode)") {
                        try await browser.evaluateJavaScript("typeof window.fixtureTransfer !== 'undefined'") as? Bool == true
                    }
                }
                let reply = try await browser.evaluateJavaScript("JSON.stringify(window.fixtureTransfer || {})") as? String
                let decoded = try JSONSerialization.jsonObject(with: Data((reply ?? "{}").utf8))
                result["upload-\(mode)"] = ["pickerCallbacks": inspector.openPanelRequests, "reply": decoded]
                browser.stopLoading()
            } catch {
                result["upload-\(mode)"] = ["probeError": String(describing: error)]
            }
        }

        for mode in ["success", "cancel", "broken"] {
            let path = directory.appendingPathComponent("download-\(mode).bin")
            let partialPath = path.appendingPathExtension("partial")
            let inspector = TransferInspector(exception: exception, fileToUpload: nil, downloadPath: partialPath)
            let browser = makeBrowser(endpoint: endpoint, inspector: inspector)
            do {
                let request = URLRequest(url: try target(origin, path: "download", mode: mode))
                if directDownload {
                    browser.startDownload(using: request) { inspector.trackDownload($0) }
                } else {
                    browser.load(request)
                }
                try await waitFor("download delegate \(mode)") {
                    inspector.download != nil || (inspector.failure.map { $0.code != 102 } ?? false)
                }
                var facts: [String: Any] = [:]
                if mode == "cancel", let download = inspector.download {
                    try await waitFor("partial download before cancelling") {
                        download.progress.completedUnitCount > 0 || inspector.downloadFinished || inspector.downloadError != nil
                    }
                    facts["bytesBeforeCancel"] = download.progress.completedUnitCount
                    facts["finishedBeforeCancel"] = inspector.downloadFinished
                    await withCheckedContinuation { continuation in
                        download.cancel { _ in continuation.resume() }
                    }
                    facts["cancelCallback"] = true
                } else if inspector.download != nil {
                    try await waitFor("download completion \(mode)") {
                        inspector.downloadFinished || inspector.downloadError != nil
                    }
                }
                let files = FileManager.default
                let content = files.fileExists(atPath: partialPath.path) ? try Data(contentsOf: partialPath) : nil
                facts["receivedBytes"] = content?.count ?? 0
                facts["sha256"] = content.map(digest) ?? ""
                if inspector.downloadFinished {
                    try files.moveItem(at: partialPath, to: path)
                } else if content != nil {
                    try files.removeItem(at: partialPath)
                }
                facts["published"] = files.fileExists(atPath: path.path)
                facts["partialFileCleaned"] = !files.fileExists(atPath: partialPath.path)
                facts["suggestedFilename"] = inspector.suggestedFilename
                facts["finished"] = inspector.downloadFinished
                facts["downloadAuthChallenges"] = inspector.downloadAuthChallenges
                facts["downloadErrorCode"] = inspector.downloadError?.code ?? 0
                facts["navigationErrorCode"] = inspector.failure?.code ?? 0
                result["download-\(mode)"] = facts
            } catch {
                result["download-\(mode)"] = [
                    "probeError": String(describing: error),
                    "downloadPolicyResponses": inspector.downloadPolicyResponses,
                    "downloadDelegateCalled": inspector.download != nil,
                    "downloadAuthChallenges": inspector.downloadAuthChallenges,
                    "navigationErrorCode": inspector.failure?.code ?? 0
                ]
            }
            browser.stopLoading()
        }
        return result
    }

    private static func makeBrowser(endpoint: URL, inspector: TransferInspector) -> WKWebView {
        var proxy = ProxyConfiguration(relayHops: [.init(http2RelayEndpoint: .url(endpoint))])
        proxy.allowFailover = false
        let store = WKWebsiteDataStore.nonPersistent()
        store.proxyConfigurations = [proxy]
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        if ProcessInfo.processInfo.environment["MYTERM_PROBE_LOCKDOWN"] == "1" {
            configuration.defaultWebpagePreferences.isLockdownModeEnabled = true
        }
        let browser = WKWebView(frame: .zero, configuration: configuration)
        browser.navigationDelegate = inspector
        browser.uiDelegate = inspector
        return browser
    }

    private static func target(_ origin: URL, path: String, mode: String) throws -> URL {
        guard var components = URLComponents(url: origin.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw TransferFixtureError.invalidURL
        }
        components.queryItems = [URLQueryItem(name: "mode", value: mode)]
        guard let url = components.url else { throw TransferFixtureError.invalidURL }
        return url
    }

    private static func digest(_ content: Data) -> String {
        SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
    }

    private static func waitFor(_ description: String, condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(18)
        while ContinuousClock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw TransferFixtureError.timeout(description)
    }
}
