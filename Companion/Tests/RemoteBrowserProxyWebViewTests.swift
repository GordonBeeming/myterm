import CryptoKit
import MyTermRemote
import Network
import WebKit
import XCTest
@testable import MyTermCompanion

private actor EncryptedBrowserBridge {
    var proxy: RemoteBrowserProxy?
    var host: RemoteBrowserHostTunnel?
    let client = P256.KeyAgreement.PrivateKey()
    let server = P256.KeyAgreement.PrivateKey()
    private var observedHosts: [String] = []

    func configure(destinationPort: UInt16? = nil) {
        proxy = RemoteBrowserProxy { [weak self] frame in try await self?.toHost(frame) }
        host = RemoteBrowserHostTunnel(send: { [weak self] frame in try await self?.toClient(frame) },
            resolve: { host, port in
                if let destinationPort { return ("127.0.0.1", destinationPort) }
                return (host, port)
            })
    }
    func endpoint() async throws -> RemoteBrowserProxyEndpoint {
        guard let proxy else { throw RemoteError.invalidMessage }
        return try await proxy.start(protocolKind: .socks5)
    }
    private func protectedFrame(_ frame: BrowserTunnelParameters) throws -> BrowserTunnelParameters {
        let key = try client.sharedSecretFromKeyAgreement(with: server.publicKey)
            .hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("browser-test".utf8),
                sharedInfo: Data(), outputByteCount: 32)
        let sealed = try AES.GCM.seal(JSONEncoder().encode(frame), using: key)
        guard let combined = sealed.combined else { throw RemoteError.invalidMessage }
        let opened = try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: key)
        return try JSONDecoder().decode(BrowserTunnelParameters.self, from: opened)
    }
    func toHost(_ frame: BrowserTunnelParameters) async throws {
        if let destination = frame.host { observedHosts.append(destination) }
        try await host?.receive(protectedFrame(frame))
    }
    func toClient(_ frame: BrowserTunnelParameters) async throws { try await proxy?.receive(protectedFrame(frame)) }
    func destinations() -> [String] { observedHosts }
    func stop() async { await proxy?.stop(); await host?.closeAll() }
}

private final class BrowserHTTPFixture: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "browser-fixture")
    private let body: String
    private let lock = NSLock()
    private var requestCount = 0
    private var failsRequests = false
    func setRequestFailure(_ enabled: Bool) { lock.withLock { failsRequests = enabled } }
    var requests: Int { lock.withLock { requestCount } }
    init(body: String = "<html><title>Remote fixture</title><a href='/next'>Next</a><p>Host page</p></html>") throws {
        self.body = body
        listener = try NWListener(using: .tcp, on: .any)
    }
    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [self, queue] connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, error in
                guard error == nil else { connection.cancel(); return }
                let shouldFail = self.lock.withLock {
                    self.requestCount += 1
                    return self.failsRequests
                }
                if shouldFail { connection.cancel(); return }
                if let data, let request = String(data: data, encoding: .utf8),
                   request.lowercased().contains("upgrade: websocket"),
                   let keyLine = request.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("sec-websocket-key:") }),
                   let key = keyLine.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) {
                    let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
                    var response = Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n".utf8)
                    let payload = Data("Remote websocket".utf8)
                    response.append(contentsOf: [0x81, UInt8(payload.count)])
                    response.append(payload)
                    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
                let body = self.body
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nCache-Control: no-store\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    if let port = listener.port { continuation.resume(returning: port.rawValue) }
                    else { continuation.resume(throwing: RemoteError.invalidMessage) }
                case .failed(let error): listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }
    func stop() { listener.cancel() }
}

private final class BrowserUDPProbe: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var datagrams = 0
    var count: Int { lock.withLock { datagrams } }
    init() throws { listener = try NWListener(using: .udp, on: .any) }
    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [self] connection in
            connection.start(queue: .global())
            connection.receiveMessage { [self] data, _, _, _ in
                if let data, !data.isEmpty { lock.withLock { datagrams += 1 } }
                connection.cancel()
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    if let port = listener.port { continuation.resume(returning: port.rawValue) }
                    else { continuation.resume(throwing: RemoteError.invalidMessage) }
                case .failed(let error): listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .global())
        }
    }
    func stop() { listener.cancel() }
}

@MainActor
final class RemoteBrowserProxyWebViewTests: XCTestCase {
    func testNativeNavigationClearsFailedReloadWhenGoingBackAndReloading() async throws {
        let fixture = try BrowserHTTPFixture()
        let port = try await fixture.start()
        defer { fixture.stop() }
        let bridge = EncryptedBrowserBridge()
        await bridge.configure(destinationPort: port)
        let browser = NativeRemoteBrowser()
        let endpoint = try await bridge.endpoint()
        try await browser.start(endpoint, url: try XCTUnwrap(URL(string: "http://myterm-test.invalid/first")))
        let view = try XCTUnwrap(browser.webView)
        try await waitForBrowser { view.title == "Remote fixture" && !view.isLoading }
        view.load(URLRequest(url: try XCTUnwrap(URL(string: "http://myterm-test.invalid/second"))))
        try await waitForBrowser { view.url?.path == "/second" && !view.isLoading && view.canGoBack }
        fixture.setRequestFailure(true)
        view.reload()
        try await waitForBrowser { browser.error != nil }
        fixture.setRequestFailure(false)
        view.goBack()
        try await waitForBrowser { view.url?.path == "/first" && !view.isLoading }
        XCTAssertNil(browser.error, "Back navigation must clear the failed reload error")
        view.goForward()
        try await waitForBrowser { view.url?.path == "/second" && !view.isLoading }
        fixture.setRequestFailure(true)
        view.reload()
        try await waitForBrowser { browser.error != nil }
        fixture.setRequestFailure(false)
        view.reload()
        try await waitForBrowser { browser.error == nil && !view.isLoading }
        XCTAssertNil(browser.error, "A successful retry must clear the old error")
        browser.stop()
        await bridge.stop()
    }

    private func waitForBrowser(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(condition(), "Browser navigation did not reach its expected state")
    }

    func testNativeWebSocketFlowsThroughEncryptedRemoteProxy() async throws {
        let fixture = try BrowserHTTPFixture(body: "<html><title>Remote fixture</title><script>let s=new WebSocket('ws://myterm-test.invalid/socket');s.onmessage=e=>document.title=e.data;</script></html>")
        let port = try await fixture.start()
        defer { fixture.stop() }
        let bridge = EncryptedBrowserBridge()
        await bridge.configure(destinationPort: port)
        let browser = NativeRemoteBrowser()
        let endpoint = try await bridge.endpoint()
        try await browser.start(endpoint, url: try XCTUnwrap(URL(string: "http://myterm-test.invalid/page")))
        let deadline = Date().addingTimeInterval(15)
        while browser.webView?.title != "Remote websocket", browser.error == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(browser.webView?.title, "Remote websocket", browser.error ?? "WebSocket did not deliver its text frame")
        let destinations = await bridge.destinations()
        XCTAssertGreaterThanOrEqual(destinations.filter { $0 == "myterm-test.invalid" }.count, 2)
        browser.stop()
        await bridge.stop()
    }

    func testWebRTCProxyBoundaryDiagnosticWithoutMediaPermissions() async throws {
        let fixture = try BrowserHTTPFixture()
        let port = try await fixture.start()
        defer { fixture.stop() }
        let udp = try BrowserUDPProbe()
        let udpPort = try await udp.start()
        defer { udp.stop() }
        let bridge = EncryptedBrowserBridge()
        await bridge.configure(destinationPort: port)
        let browser = NativeRemoteBrowser()
        let endpoint = try await bridge.endpoint()
        try await browser.start(endpoint, url: try XCTUnwrap(URL(string: "http://myterm-test.invalid/page")))
        let deadline = Date().addingTimeInterval(15)
        while browser.webView?.title != "Remote fixture", browser.error == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        let view = try XCTUnwrap(browser.webView)
        let script = """
        (() => {
          if (typeof RTCPeerConnection === 'undefined') return 'RTC API unavailable';
          const pc = new RTCPeerConnection({iceServers:[{urls:'stun:127.0.0.1:\(udpPort)'}]});
          window.__mytermRTCProbe = pc;
          pc.createDataChannel('diagnostic');
          pc.createOffer().then(offer => pc.setLocalDescription(offer)).catch(error => window.__mytermRTCError = String(error));
          return 'RTC gathering started';
        })()
        """
        let state: String = try await withCheckedThrowingContinuation { continuation in
            view.evaluateJavaScript(script) { result, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: result as? String ?? "Unexpected RTC result") }
            }
        }
        try await Task.sleep(for: .seconds(4))
        let detail = "\(state); device-local STUN datagrams observed: \(udp.count). No media capture requested."
        let attachment = XCTAttachment(string: detail)
        attachment.name = "WebRTC proxy boundary"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("WEBRTC_BOUNDARY: " + detail)
        view.evaluateJavaScript("window.__mytermRTCProbe?.close()", completionHandler: nil)
        browser.stop()
        await bridge.stop()
    }

    func testOffscreenWKWebViewLoadsRemoteHostnameThroughEncryptedProxy() async throws {
        let fixture = try BrowserHTTPFixture()
        let port = try await fixture.start()
        defer { fixture.stop() }
        let bridge = EncryptedBrowserBridge()
        await bridge.configure(destinationPort: port)
        let endpoint = try await bridge.endpoint()
        let browser = NativeRemoteBrowser()
        try await browser.start(endpoint, url: try XCTUnwrap(URL(string: "http://myterm-test.invalid/page")))
        let deadline = Date().addingTimeInterval(15)
        while browser.webView?.title != "Remote fixture", browser.error == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(browser.webView?.title, "Remote fixture", browser.error ?? "Remote page did not load")
        let destinations = await bridge.destinations()
        XCTAssertTrue(destinations.contains("myterm-test.invalid"))
        browser.stop()
        await bridge.stop()
    }

    func testNativeContentRulesBlockDeviceLoopbackSubresources() async throws {
        let deviceLocal = try BrowserHTTPFixture()
        let localPort = try await deviceLocal.start()
        defer { deviceLocal.stop() }
        let hosts = ["127.0.0.1", "127.1", "0x7f000001", "2130706433", "0177.0.0.1", "127.0x0.0.1", "0x7f.0.0.1", "127%2e0%2e0%2e1", "[::1]", "localhost.", "user@127.0.0.1"]
        let images = hosts.map { "<img src='http://\($0):\(localPort)/pixel'>" }.joined()
        let fixture = try BrowserHTTPFixture(body: "<html><title>Remote fixture</title>\(images)<iframe src='http://user@localhost:\(localPort)/frame'></iframe></html>")
        let port = try await fixture.start()
        defer { fixture.stop() }
        let bridge = EncryptedBrowserBridge()
        await bridge.configure(destinationPort: port)
        let browser = NativeRemoteBrowser()
        let endpoint = try await bridge.endpoint()
        try await browser.start(endpoint, url: try XCTUnwrap(URL(string: "http://myterm-test.invalid/page")))
        let deadline = Date().addingTimeInterval(15)
        while browser.webView?.title != "Remote fixture", browser.error == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(browser.webView?.title, "Remote fixture", browser.error ?? "Remote page did not load")
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(deviceLocal.requests, 0, "Subresources must never contact the companion device's loopback")
        browser.stop()
        await bridge.stop()
    }

    func testOffscreenWKWebViewRejectsLocalhostInsteadOfBypassingProxy() async throws {
        let fixture = try BrowserHTTPFixture()
        let port = try await fixture.start()
        defer { fixture.stop() }
        let bridge = EncryptedBrowserBridge()
        await bridge.configure()
        let endpoint = try await bridge.endpoint()
        let browser = NativeRemoteBrowser()
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/"))
        try await browser.start(endpoint, url: url)
        XCTAssertEqual(browser.error, "Use Mac rendered mode for localhost or IP addresses.")
        browser.webView(try XCTUnwrap(browser.webView), didFinish: nil)
        XCTAssertEqual(browser.error, "Use Mac rendered mode for localhost or IP addresses.",
                       "A late page completion must not erase a policy rejection")
        XCTAssertNil(browser.webView?.url)
        let destinations = await bridge.destinations()
        XCTAssertTrue(destinations.isEmpty)
        await bridge.stop()
        browser.stop()
    }
}
