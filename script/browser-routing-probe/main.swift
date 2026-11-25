// Throwaway native WebKit routing test. No windows, persistent data or user network settings.
import AppKit
import Foundation
import Network
import WebKit

final class Fixture: @unchecked Sendable {
    let listener: NWListener
    let isProxy: Bool
    private let lock = NSLock()
    private var seen: [String] = []
    private var connections: [NWConnection] = []
    init(proxy: Bool) throws {
        isProxy = proxy
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.lock.lock(); self.connections.append(connection); self.lock.unlock()
            connection.start(queue: .global())
            self.receive(connection, data: Data(), tunneled: false)
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
    private func receive(_ connection: NWConnection, data: Data, tunneled: Bool) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] bytes, _, complete, error in
            guard let self else { return }
            var all = data; if let bytes { all.append(bytes) }
            guard all.count <= 65536, error == nil else { connection.cancel(); return }
            guard let boundary = all.range(of: Data("\r\n\r\n".utf8)) else {
                if complete { connection.cancel() }
                else { self.receive(connection, data: all, tunneled: tunneled) }
                return
            }
            let request = String(decoding: all[..<boundary.upperBound], as: UTF8.self)
            let first = request.components(separatedBy: "\r\n")[0]
            self.lock.lock(); self.seen.append(first); self.lock.unlock()
            if self.isProxy && !tunneled && first.hasPrefix("CONNECT ") {
                connection.send(content: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8), completion: .contentProcessed { error in
                    if error == nil { self.receive(connection, data: Data(all[boundary.upperBound...]), tunneled: true) }
                    else { connection.cancel() }
                })
            } else {
                let title = self.isProxy ? "PROXY_FIXTURE" : "CLIENT_LOCAL_FIXTURE"
                let body = "<!doctype html><title>\(title)</title><p>\(title)</p>"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
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
    var error: String?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.error = String(describing: error)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.error = String(describing: error)
    }
}

@main struct Probe {
    @MainActor static func main() async {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        do {
            let origin = try Fixture(proxy: false), proxy = try Fixture(proxy: true)
            let originPort = try await origin.start(), proxyPort = try await proxy.start()
            defer { origin.stop(); proxy.stop() }
            var results: [[String: Any]] = []
            let kind = "httpCONNECT"
            for host in ["myterm-route-probe.invalid", "localhost", "127.0.0.1", "[::1]"] {
                let beforeOrigin = origin.snapshot().count, beforeProxy = proxy.snapshot().count
                let store = WKWebsiteDataStore.nonPersistent()
                guard let port = NWEndpoint.Port(rawValue: proxyPort), let url = URL(string: "http://\(host):\(originPort)/routing-probe") else {
                    throw NSError(domain: "Probe", code: 2)
                }
                var config = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: port))
                config.allowFailover = false
                config.matchDomains = ["localhost", "127.0.0.1", "::1", ""]
                config.excludedDomains = []
                store.proxyConfigurations = [config]
                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = store
                let browser = WKWebView(frame: .zero, configuration: configuration)
                let navigation = Navigation()
                browser.navigationDelegate = navigation
                browser.load(URLRequest(url: url, timeoutInterval: 5))
                let deadline = Date().addingTimeInterval(8)
                while !navigation.finished && navigation.error == nil && Date() < deadline {
                    try await Task.sleep(for: .milliseconds(50))
                }
                results.append([
                    "url": url.absoluteString, "proxy": kind,
                    "title": browser.title ?? "", "finished": navigation.finished,
                    "error": navigation.error ?? "",
                    "clientOriginRequests": Array(origin.snapshot().dropFirst(beforeOrigin)),
                    "proxyRequests": Array(proxy.snapshot().dropFirst(beforeProxy))
                ])
                browser.stopLoading()
                browser.navigationDelegate = nil
            }
            let output: [String: Any] = ["scope": "offscreen macOS WKWebView HTTP CONNECT routing fixture; no Rust server or E2EE", "os": ProcessInfo.processInfo.operatingSystemVersionString, "results": results]
            let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            exit(0)
        } catch { fputs("Probe failed: \(error)\n", stderr); exit(1) }
    }
}
