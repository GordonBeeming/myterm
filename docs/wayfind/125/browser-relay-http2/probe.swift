// Throwaway native WebKit routing test. No windows, persistent data or user network settings.
import AppKit
import Foundation
import Network
import Security
import WebKit

final class Fixture: @unchecked Sendable {
    let listener: NWListener
    private let lock = NSLock()
    private var seen: [String] = []
    private var connections: [NWConnection] = []
    init() throws {
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.lock.lock(); self.connections.append(connection); self.lock.unlock()
            connection.start(queue: .global())
            self.receive(connection, data: Data())
        }
    }
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.listener.stateUpdateHandler = nil
                    if let port = self.listener.port { continuation.resume(returning: port.rawValue) }
                    else { continuation.resume(throwing: NSError(domain: "Fixture", code: 1)) }
                case .failed(let error):
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .global())
        }
    }
    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] bytes, _, complete, error in
            guard let self else { return }
            var all = data; if let bytes { all.append(bytes) }
            guard all.count <= 65536, error == nil else { connection.cancel(); return }
            guard let boundary = all.range(of: Data("\r\n\r\n".utf8)) else {
                if complete { connection.cancel() }
                else { self.receive(connection, data: all) }
                return
            }
            let request = String(decoding: all[..<boundary.upperBound], as: UTF8.self)
            let first = request.components(separatedBy: "\r\n")[0]
            self.lock.lock(); self.seen.append(first); self.lock.unlock()
            let body = "<!doctype html><title>CLIENT_LOCAL_FIXTURE</title>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return seen }
    func stop() {
        listener.cancel()
        lock.lock(); let active = connections; connections.removeAll(); lock.unlock()
        active.forEach { $0.cancel() }
    }
}

@MainActor final class Navigation: NSObject, WKNavigationDelegate {
    var finished = false
    let expectedCertificate: Data
    var error: NSError?
    init(expectedCertificate: Data) { self.expectedCertificate = expectedCertificate }
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        fputs("WebKit authentication challenge: \(space.authenticationMethod) \(space.host)\n", stderr)
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = space.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        _ = SecTrustEvaluateWithError(trust, nil)
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first, (SecCertificateCopyData(leaf) as Data) == expectedCertificate else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.error = error as NSError
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.error = error as NSError
    }
}

@main struct Probe {
    @MainActor static func main() async {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        do {
            let origin = try Fixture()
            let originPort = try await origin.start()
            defer { origin.stop() }
            var results: [[String: Any]] = []
            guard CommandLine.arguments.count == 3, let relayPort = UInt16(CommandLine.arguments[1]),
                  ["running", "stopped"].contains(CommandLine.arguments[2]) else {
                fputs("usage: probe RELAY_PORT running|stopped\n", stderr)
                exit(2)
            }
            let status = CommandLine.arguments[2]
            let expectedCertificate = try Data(contentsOf: URL(fileURLWithPath: "relay.der"))
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
                fputs("Relay verify callback\n", stderr)
                let trust = sec_trust_copy_ref(trust).takeRetainedValue()
                _ = SecTrustEvaluateWithError(trust, nil)
                guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
                    complete(false)
                    return
                }
                complete((SecCertificateCopyData(leaf) as Data) == expectedCertificate)
            }, .global())
            guard let relayURL = URL(string: "https://127.0.0.1:\(relayPort)") else {
                throw NSError(domain: "Probe", code: 3)
            }
            let kind = "relayHTTP2"
            for host in ["myterm-route-probe.invalid", "localhost", "127.0.0.1", "[::1]"] {
                let beforeOrigin = origin.snapshot().count
                let store = WKWebsiteDataStore.nonPersistent()
                guard let url = URL(string: "http://\(host):\(originPort)/routing-probe") else {
                    throw NSError(domain: "Probe", code: 2)
                }
                let hop = ProxyConfiguration.RelayHop(http2RelayEndpoint: .url(relayURL), tlsOptions: tls)
                var config = ProxyConfiguration(relayHops: [hop])
                config.allowFailover = false
                config.matchDomains = ["localhost", "127.0.0.1", "::1", ""]
                config.excludedDomains = []
                store.proxyConfigurations = [config]
                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = store
                let browser = WKWebView(frame: .zero, configuration: configuration)
                let navigation = Navigation(expectedCertificate: expectedCertificate)
                browser.navigationDelegate = navigation
                browser.load(URLRequest(url: url, timeoutInterval: 5))
                let deadline = Date().addingTimeInterval(8)
                while !navigation.finished && navigation.error == nil && Date() < deadline {
                    try await Task.sleep(for: .milliseconds(50))
                }
                results.append([
                    "url": url.absoluteString, "proxy": kind,
                    "title": browser.title ?? "", "finished": navigation.finished,
                    "errorDomain": navigation.error?.domain ?? "",
                    "errorCode": navigation.error?.code ?? 0,
                    "underlyingErrorCode": (navigation.error?.userInfo[NSUnderlyingErrorKey] as? NSError)?.code ?? 0,
                    "clientOriginRequests": Array(origin.snapshot().dropFirst(beforeOrigin))
                ])
                browser.stopLoading()
                browser.navigationDelegate = nil
            }
            let output: [String: Any] = ["scope": "offscreen macOS WKWebView HTTP/2 relay routing fixture; no Rust server or E2EE", "os": ProcessInfo.processInfo.operatingSystemVersionString, "relayState": status, "results": results]
            let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            exit(0)
        } catch { fputs("Probe failed: \(error)\n", stderr); exit(1) }
    }
}
