import AppKit
import Foundation
import Network
import Security
import WebKit

private enum OriginFixtureError: Error { case invalidArguments }

struct ApprovedOrigin {
    let server: String
    let host: String
    let port: Int
    let certificate: SecCertificate
}

@MainActor class Inspector: NSObject, WKNavigationDelegate {
    let server: String
    let exception: ApprovedOrigin?
    var finished = false
    var failure: NSError?
    var challenges: [[String: Any]] = []

    init(server: String, exception: ApprovedOrigin?) {
        self.server = server
        self.exception = exception
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = space.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let exceptionTrust = approvedTrust(for: space, actualTrust: trust)
        challenges.append(["host": space.host, "port": space.port, "usedException": exceptionTrust != nil])
        if let exceptionTrust {
            completionHandler(.useCredential, URLCredential(trust: exceptionTrust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    private func approvedTrust(for space: URLProtectionSpace, actualTrust: SecTrust) -> SecTrust? {
        guard let exception, server == exception.server, space.host == exception.host,
              space.port == exception.port else { return nil }
        _ = SecTrustEvaluateWithError(actualTrust, nil)
        guard let chain = SecTrustCopyCertificateChain(actualTrust) as? [SecCertificate], let leaf = chain.first,
              SecCertificateCopyData(leaf) as Data == SecCertificateCopyData(exception.certificate) as Data else {
            return nil
        }
        var candidate: SecTrust?
        let policy = SecPolicyCreateSSL(true, space.host as CFString)
        guard SecTrustCreateWithCertificates(leaf, policy, &candidate) == errSecSuccess, let candidate,
              SecTrustSetAnchorCertificates(candidate, [exception.certificate] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(candidate, true) == errSecSuccess,
              SecTrustEvaluateWithError(candidate, nil) else { return nil }
        return candidate
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failure = error as NSError
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failure = error as NSError
    }
}

@main struct OriginTrustProbe {
    @MainActor static func main() async {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        do {
            let arguments = CommandLine.arguments
            guard arguments.count == 5,
                  let primary = UInt16(arguments[2]), let secondary = UInt16(arguments[3]),
                  let port = UInt16(arguments[4]) else {
                throw OriginFixtureError.invalidArguments
            }
            let relayHost = arguments[1]
            let certificate = try Data(contentsOf: URL(fileURLWithPath: "origin.der"))
            let unrelatedCertificate = try Data(contentsOf: URL(fileURLWithPath: "unrelated/origin.der"))
            guard let pin = SecCertificateCreateWithData(nil, certificate as CFData),
                  let otherPin = SecCertificateCreateWithData(nil, unrelatedCertificate as CFData) else {
                throw OriginFixtureError.invalidArguments
            }
            let host = "myterm-route-probe.invalid"
            let exception = ApprovedOrigin(server: "A", host: host, port: Int(port), certificate: pin)
            if ProcessInfo.processInfo.environment["MYTERM_PROBE_TRANSFERS"] == "1" {
                let results = try await TransferProbe.run(relayHost: relayHost, relayPort: primary,
                                                          port: port, exception: exception)
                let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
                print(String(decoding: data, as: UTF8.self))
                return
            }
            let wrongLeaf = ApprovedOrigin(server: "A", host: host, port: Int(port), certificate: otherPin)
            let scenarios: [(String, String, UInt16, String, UInt16, ApprovedOrigin?)] = [
                ("default", "A", primary, host, port, nil),
                ("approved", "A", primary, host, port, exception),
                ("different-server", "B", secondary, host, port, exception),
                ("different-host", "A", primary, "other-route-probe.invalid", port, exception),
                ("different-port", "A", primary, host, port == UInt16.max ? port - 1 : port + 1, exception),
                ("different-leaf", "A", primary, host, port, wrongLeaf)
            ]
            var results: [[String: Any]] = []
            for (name, server, relayPort, destinationHost, destinationPort, exception) in scenarios {
                let result = try await load(relayHost: relayHost, relayPort: relayPort,
                                            destinationHost: destinationHost, destinationPort: destinationPort,
                                            server: server, exception: exception)
                results.append(result.merging(["scenario": name]) { original, _ in original })
            }
            let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } catch {
            fputs("Origin trust fixture failed: \(error)\n", stderr)
            exit(1)
        }
    }

    @MainActor private static func load(relayHost: String, relayPort: UInt16, destinationHost: String,
                                       destinationPort: UInt16, server: String,
                                       exception: ApprovedOrigin?) async throws -> [String: Any] {
        guard let endpoint = URL(string: "https://\(relayHost):\(relayPort)"),
              let destination = URL(string: "https://\(destinationHost):\(destinationPort)/origin-trust") else {
            throw OriginFixtureError.invalidArguments
        }
        var proxy = ProxyConfiguration(relayHops: [.init(http2RelayEndpoint: .url(endpoint))])
        proxy.allowFailover = false
        let store = WKWebsiteDataStore.nonPersistent()
        store.proxyConfigurations = [proxy]
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        let browser = WKWebView(frame: .zero, configuration: configuration)
        let inspector = Inspector(server: server, exception: exception)
        browser.navigationDelegate = inspector
        browser.load(URLRequest(url: destination, timeoutInterval: 8))
        let deadline = ContinuousClock.now + .seconds(10)
        while !inspector.finished && inspector.failure == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let result: [String: Any] = [
            "url": destination.absoluteString, "title": browser.title ?? "",
            "finished": inspector.finished, "errorCode": inspector.failure?.code ?? 0,
            "challenges": inspector.challenges
        ]
        browser.stopLoading()
        browser.navigationDelegate = nil
        return result
    }
}
