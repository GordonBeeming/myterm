// Throwaway native WebKit routing test. No windows, persistent data or user network settings.
#if os(iOS)
import UIKit
#else
import AppKit
#endif
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

private final class STUNObserver: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var datagrams = 0

    init() throws {
        let parameters = NWParameters.udp
        parameters.acceptLocalOnly = true
        listener = try NWListener(using: parameters, on: .any)
    }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global())
            connection.receiveMessage { [weak self] data, _, _, _ in
                if let self, let data, data.count >= 20,
                   data.dropFirst(4).prefix(4).elementsEqual([0x21, 0x12, 0xa4, 0x42]) {
                    self.lock.withLock { self.datagrams += 1 }
                }
                connection.cancel()
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    if let port = listener.port { continuation.resume(returning: port.rawValue) }
                    else { continuation.resume(throwing: NSError(domain: "STUN observer", code: 1)) }
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .global())
        }
    }

    func snapshot() -> Int { lock.withLock { datagrams } }
    func stop() { listener.cancel() }
}

@MainActor private func observeWebRTC(in browser: WKWebView) async throws -> [String: Any] {
    let observer = try STUNObserver()
    let port = try await observer.start()
    defer { observer.stop() }
    let script = """
        (() => {
          if (typeof RTCPeerConnection === 'undefined') return "API unavailable";
          let connection = new RTCPeerConnection({
            iceServers: [{urls: "stun:127.0.0.1:\(port)"}]
          });
          window.fixturePeerConnection = connection;
          connection.createDataChannel("fixture");
          connection.createOffer().then(offer => connection.setLocalDescription(offer))
            .catch(error => { window.fixtureRTCError = String(error); });
          return "ICE gathering requested";
        })();
        """
    let activation = try await browser.evaluateJavaScript(script) as? String ?? ""
    try await Task.sleep(for: .seconds(4))
    let error = try await browser.evaluateJavaScript("window.fixtureRTCError || ''") as? String ?? ""
    _ = try await browser.evaluateJavaScript("window.fixturePeerConnection?.close()")
    return ["start": activation, "setupError": error, "clientSTUNDatagrams": observer.snapshot()]
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

@MainActor struct Probe {
    static func run(relayPort: UInt16, status: String, expectedCertificate: Data?,
                    domainMatching: String = "explicit", transport: String = "http2",
                    relayHost: String = "127.0.0.1", probeWebRTC: Bool = false) async throws -> Data {
        let origin = try Fixture()
        let originPort = try await origin.start()
        defer { origin.stop() }
        var results: [[String: Any]] = []
        var rtc: [String: Any] = [:]
        var directRTC: [String: Any] = [:]
        let tls = NWProtocolTLS.Options()
        if let expectedCertificate {
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
        }
        guard let relayURL = URL(string: "https://\(relayHost):\(relayPort)") else {
            throw NSError(domain: "Probe", code: 3)
        }
        let kind = transport == "http3" ? "relayHTTP3" : "relayHTTP2"
        for host in ["myterm-route-probe.invalid", "localhost", "127.0.0.1", "[::1]"] {
            let beforeOrigin = origin.snapshot().count
            let store = WKWebsiteDataStore.nonPersistent()
            guard let url = URL(string: "http://\(host):\(originPort)/routing-probe") else {
                throw NSError(domain: "Probe", code: 2)
            }
            let hop = transport == "http3"
                ? ProxyConfiguration.RelayHop(http3RelayEndpoint: .url(relayURL), tlsOptions: tls)
                : ProxyConfiguration.RelayHop(http2RelayEndpoint: .url(relayURL), tlsOptions: tls)
            var config = ProxyConfiguration(relayHops: [hop])
            config.allowFailover = false
            if domainMatching == "explicit" {
                config.matchDomains = ["localhost", "127.0.0.1", "::1", ""]
                config.excludedDomains = []
            }
            store.proxyConfigurations = [config]
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = store
            let browser = WKWebView(frame: .zero, configuration: configuration)
            let navigation = Navigation(expectedCertificate: expectedCertificate ?? Data())
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
                "underlyingErrorDomain": (navigation.error?.userInfo[NSUnderlyingErrorKey] as? NSError)?.domain ?? "",
                "underlyingErrorCode": (navigation.error?.userInfo[NSUnderlyingErrorKey] as? NSError)?.code ?? 0,
                "clientOriginRequests": Array(origin.snapshot().dropFirst(beforeOrigin))
            ])
            if probeWebRTC, host == "myterm-route-probe.invalid", navigation.finished {
                rtc = try await observeWebRTC(in: browser)
            }
            browser.stopLoading()
            browser.navigationDelegate = nil
        }
        if probeWebRTC, status == "running",
           let url = URL(string: "http://localhost:\(originPort)/webrtc-control") {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let browser = WKWebView(frame: .zero, configuration: configuration)
            let navigation = Navigation(expectedCertificate: Data())
            browser.navigationDelegate = navigation
            browser.loadHTMLString("<!doctype html><title>DIRECT_RTC_CONTROL</title>", baseURL: url)
            let deadline = Date().addingTimeInterval(8)
            while !navigation.finished && navigation.error == nil && Date() < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            if navigation.finished {
                directRTC = try await observeWebRTC(in: browser)
            } else {
                directRTC = ["navigationError": navigation.error?.code ?? 0]
            }
        }
        let output: [String: Any] = ["scope": "offscreen WKWebView secure relay routing fixture; no Rust server or E2EE", "os": ProcessInfo.processInfo.operatingSystemVersionString, "relayState": status, "domainMatching": domainMatching, "relayHost": relayHost, "webRTC": rtc, "webRTCDirectControl": directRTC, "results": results]
        return try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
    }
}


@MainActor private func arguments() throws -> (UInt16, String) {
    guard CommandLine.arguments.count == 3,
          let port = UInt16(CommandLine.arguments[1]),
          ["running", "stopped"].contains(CommandLine.arguments[2]) else {
        throw NSError(domain: "usage: probe RELAY_PORT running|stopped", code: 2)
    }
    return (port, CommandLine.arguments[2])
}

#if os(iOS)
@main final class ProbeApplication: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = ProbeScene.self
        return configuration
    }
}

final class ProbeScene: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        self.window = window
        window.makeKeyAndVisible()
        Task {
            let path = URL.documentsDirectory.appendingPathComponent("routing-result.json")
            do {
                let environment = ProcessInfo.processInfo.environment
                guard let rawPort = environment["MYTERM_PROBE_PORT"], let port = UInt16(rawPort),
                      let status = environment["MYTERM_PROBE_STATE"],
                      ["running", "stopped"].contains(status) else {
                    throw NSError(domain: "Missing simulator fixture configuration", code: 2)
                }
                let domainMatching = environment["MYTERM_PROBE_DOMAINS"] ?? "explicit"
                let data = try await Probe.run(relayPort: port, status: status, expectedCertificate: nil,
                                               domainMatching: domainMatching,
                                               transport: environment["MYTERM_PROBE_TRANSPORT"] ?? "http2",
                                               probeWebRTC: environment["MYTERM_PROBE_WEBRTC"] == "1")
                try data.write(to: path, options: .atomic)
            } catch {
                let errorData = try? JSONSerialization.data(withJSONObject: ["probeError": String(describing: error)])
                try? errorData?.write(to: path, options: .atomic)
            }
        }
    }
}
#else
@main struct DesktopProbe {
    @MainActor static func main() async {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        do {
            let (port, status) = try arguments()
            let environment = ProcessInfo.processInfo.environment
            let relayHost = environment["MYTERM_RELAY_HOST"] ?? "127.0.0.1"
            let certificate = relayHost == "127.0.0.1" ? try Data(contentsOf: URL(fileURLWithPath: "relay.der")) : nil
            let data = try await Probe.run(relayPort: port, status: status, expectedCertificate: certificate,
                                           domainMatching: environment["MYTERM_PROBE_DOMAINS"] ?? "explicit",
                                           transport: environment["MYTERM_PROBE_TRANSPORT"] ?? "http2",
                                           relayHost: relayHost, probeWebRTC: environment["MYTERM_PROBE_WEBRTC"] == "1")
            print(String(decoding: data, as: UTF8.self))
        } catch {
            fputs("Probe failed: \(error)\n", stderr)
            exit(1)
        }
    }
}
#endif
