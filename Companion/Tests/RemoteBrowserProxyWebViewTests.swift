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
    private var headerByteCount = 0
    private var failsRequests = false
    private let initialResponseDelay: TimeInterval
    func setRequestFailure(_ enabled: Bool) { lock.withLock { failsRequests = enabled } }
    var requests: Int { lock.withLock { requestCount } }
    var receivedHeaderBytes: Int { lock.withLock { headerByteCount } }
    init(body: String = "<html><title>Remote fixture</title><a href='/next'>Next</a><p>Host page</p></html>",
         initialResponseDelay: TimeInterval = 0) throws {
        self.body = body
        self.initialResponseDelay = initialResponseDelay
        listener = try NWListener(using: .tcp, on: .any)
    }
    static let bootstrapPath = "/__myterm_bootstrap"
    static let bootstrapTitle = "MYTERM-WEBKIT-READY"

    /// Reads complete requests so TCP fragmentation cannot select the wrong fixture response.
    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [self, queue] connection in
            connection.start(queue: queue)
            receiveHeaders(connection, buffered: Data())
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
    /// HTTP headers can arrive in several tunnel frames even for a small GET request.
    private func receiveHeaders(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [self] data, _, complete, error in
            guard error == nil, let data, !data.isEmpty else { connection.cancel(); return }
            lock.withLock { headerByteCount += data.count }
            var headers = buffered
            headers.append(data)
            guard headers.count <= 8192 else { connection.cancel(); return }
            guard headers.range(of: Data("\r\n\r\n".utf8)) != nil else {
                guard !complete else { connection.cancel(); return }
                receiveHeaders(connection, buffered: headers)
                return
            }
            guard let request = String(data: headers, encoding: .utf8) else { connection.cancel(); return }
            respond(to: request, on: connection)
        }
    }

    /// Bootstrap has no scripts or subresources; all functional pages keep their original body.
    private func respond(to request: String, on connection: NWConnection) {
        let state = lock.withLock {
            requestCount += 1
            return (requestCount, failsRequests)
        }
        if state.1 { connection.cancel(); return }
        if request.lowercased().contains("upgrade: websocket"),
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
        let target = request.components(separatedBy: "\r\n").first?.split(separator: " ").dropFirst().first
        let isBootstrap = target.map(String.init) == Self.bootstrapPath
        let responseBody = isBootstrap ? "<html><title>\(Self.bootstrapTitle)</title></html>" : body
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nCache-Control: no-store\r\nContent-Length: \(responseBody.utf8.count)\r\nConnection: close\r\n\r\n" + responseBody
        let delay = state.0 == 1 ? initialResponseDelay : 0
        queue.asyncAfter(deadline: .now() + delay) {
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
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

private enum BrowserFixtureStartupError: Error {
    case timedOut
    case alreadyRunning
}

@MainActor
private final class BrowserFixtureStartup {
    private var continuation: CheckedContinuation<Void, Error>?
    private var worker: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    /// Callback APIs may ignore cancellation, so a structured task-group race could wait forever.
    func run(limit: Duration, operation: @escaping @MainActor () async throws -> Void) async throws {
        try Task.checkCancellation()
        guard continuation == nil else { throw BrowserFixtureStartupError.alreadyRunning }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.continuation = continuation
                worker = Task { @MainActor [weak self] in
                    do {
                        try Task.checkCancellation()
                        try await operation()
                        self?.finish(.success(()))
                    } catch { self?.finish(.failure(error)) }
                }
                timer = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(for: limit)
                        self?.finish(.failure(BrowserFixtureStartupError.timedOut))
                    } catch is CancellationError {
                        return
                    } catch { self?.finish(.failure(error)) }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
        }
    }

    /// Resume once, and cancel the worker so a late native callback cannot initialize the view.
    private func finish(_ result: Result<Void, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        worker?.cancel()
        timer?.cancel()
        worker = nil
        timer = nil
        continuation.resume(with: result)
    }
}

@MainActor
final class RemoteBrowserProxyWebViewTests: XCTestCase {
    /// Startup errors must release both tunnel endpoints even when the test throws early.
    private func registerCleanup(_ browser: NativeRemoteBrowser, bridge: EncryptedBrowserBridge) {
        addTeardownBlock {
            await MainActor.run { browser.stop() }
            await bridge.stop()
        }
    }

    /// Keeps process/bootstrap latency outside the deadline for the actual remote navigation.
    private func startRemoteFixture(_ browser: NativeRemoteBrowser, endpoint: RemoteBrowserProxyEndpoint,
                                    url: URL) async throws {
        var components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        components.path = BrowserHTTPFixture.bootstrapPath
        components.query = nil
        components.fragment = nil
        let bootstrap = try XCTUnwrap(components.url)
        try await BrowserFixtureStartup().run(limit: .seconds(45)) {
            try await browser.start(endpoint, url: bootstrap, dataStore: .nonPersistent())
            while (browser.webView?.title != BrowserHTTPFixture.bootstrapTitle || browser.webView?.isLoading == true),
                  browser.error == nil {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(50))
            }
            guard browser.webView?.title == BrowserHTTPFixture.bootstrapTitle,
                  browser.webView?.isLoading == false else {
                throw NSError(domain: "WebKitFixtureStartup", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: browser.error ?? "WebKit bootstrap did not finish."])
            }
        }
        browser.address = url.absoluteString
        browser.submit()
    }

    /// Native callbacks can ignore cancellation; timing out must still stop late initialization.
    func testBootstrapDeadlineIncludesUncooperativeCallbackStartup() async throws {
        var initialized = false
        let startup = BrowserFixtureStartup()
        do {
            try await startup.run(limit: .milliseconds(100)) {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    Task { @MainActor in
                        do { try await Task.sleep(for: .milliseconds(500)) }
                        catch { XCTFail("The simulated native callback must still return: \(error)") }
                        continuation.resume()
                    }
                }
                try Task.checkCancellation()
                initialized = true
            }
            XCTFail("Startup should time out before its native callback returns")
        } catch BrowserFixtureStartupError.timedOut {
            // The callback still returns later, just like content-rule compilation.
        }
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse(initialized, "A cancelled startup must not initialize the view after its deadline")
    }

    /// Tunnel fragmentation cannot make the fixture respond before the request headers finish.
    func testHTTPFixtureWaitsForCompleteRequestHeaders() async throws {
        let fixture = try BrowserHTTPFixture()
        let port = try await fixture.start()
        defer { fixture.stop() }
        let connection = NWConnection(host: "127.0.0.1", port: try XCTUnwrap(NWEndpoint.Port(rawValue: port)), using: .tcp)
        connection.start(queue: .global())
        defer { connection.cancel() }
        let prefix = "GET /__myterm_bootstrap HTTP/1.1\r\nHost: myterm-test.invalid\r\n"
        try await sendHeaderPart(Data(prefix.utf8), on: connection)
        let partialDeadline = Date().addingTimeInterval(5)
        while fixture.receivedHeaderBytes < prefix.utf8.count, Date() < partialDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(fixture.receivedHeaderBytes, prefix.utf8.count)
        XCTAssertEqual(fixture.requests, 0, "Receiving bytes is not yet a complete HTTP request")
        try await sendHeaderPart(Data("\r\n".utf8), on: connection)
        let completeDeadline = Date().addingTimeInterval(5)
        while fixture.requests == 0, Date() < completeDeadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(fixture.requests, 1)
        var response = Data()
        try await BrowserFixtureStartup().run(limit: .seconds(5)) {
            response = try await self.receiveFixtureResponse(on: connection)
        }
        XCTAssertTrue(String(decoding: response, as: UTF8.self).contains(BrowserHTTPFixture.bootstrapTitle),
                      "The response must be routed using the complete buffered request")
    }

    /// The sender queues fragments independently, matching the encrypted tunnel's byte stream.
    private func sendHeaderPart(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    /// Read through EOF so a fragmented response cannot hide which fixture route was selected.
    private func receiveFixtureResponse(on connection: NWConnection) async throws -> Data {
        var response = Data()
        while true {
            let chunk = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data?, Bool), Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, complete, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: (data, complete)) }
                }
            }
            if let bytes = chunk.0 { response.append(bytes) }
            guard response.count <= 8192 else { throw RemoteError.messageTooLarge }
            if chunk.1 { return response }
            guard chunk.0?.isEmpty == false else { throw RemoteError.invalidMessage }
            try Task.checkCancellation()
        }
    }

    /// A delayed initial response must not consume the functional navigation budget.
    func testFixtureBootstrapDoesNotConsumeTheRemoteNavigationDeadline() async throws {
        let fixture = try BrowserHTTPFixture(initialResponseDelay: 6)
        let port = try await fixture.start()
        defer { fixture.stop() }
        let bridge = EncryptedBrowserBridge()
        await bridge.configure(destinationPort: port)
        let browser = NativeRemoteBrowser()
        registerCleanup(browser, bridge: bridge)
        defer { browser.stop() }
        let endpoint = try await bridge.endpoint()
        try await startRemoteFixture(browser, endpoint: endpoint,
            url: XCTUnwrap(URL(string: "http://myterm-test.invalid/page")))
        let deadline = Date().addingTimeInterval(5)
        while browser.webView?.title != "Remote fixture", Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(browser.webView?.title, "Remote fixture", "Bootstrap must finish before this deadline starts")
        await bridge.stop()
    }

    /// A successful navigation must clear old failures without losing back/forward state.
    func testNativeNavigationClearsFailedReloadWhenGoingBackAndReloading() async throws {
        let fixture = try BrowserHTTPFixture()
        let port = try await fixture.start()
        defer { fixture.stop() }
        let bridge = EncryptedBrowserBridge()
        await bridge.configure(destinationPort: port)
        let browser = NativeRemoteBrowser()
        registerCleanup(browser, bridge: bridge)
        let endpoint = try await bridge.endpoint()
        try await startRemoteFixture(browser, endpoint: endpoint, url: try XCTUnwrap(URL(string: "http://myterm-test.invalid/first")))
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

    /// Bootstrap traffic cannot substitute for the WebSocket's own destination and frame.
    func testNativeWebSocketFlowsThroughEncryptedRemoteProxy() async throws {
        let socketHost = "myterm-websocket.invalid"
        let fixture = try BrowserHTTPFixture(body: "<html><title>Remote fixture</title><script>let s=new WebSocket('ws://\(socketHost)/socket');s.onmessage=e=>document.title=e.data;</script></html>")
        let port = try await fixture.start()
        defer { fixture.stop() }
        let bridge = EncryptedBrowserBridge()
        await bridge.configure(destinationPort: port)
        let browser = NativeRemoteBrowser()
        registerCleanup(browser, bridge: bridge)
        let endpoint = try await bridge.endpoint()
        try await startRemoteFixture(browser, endpoint: endpoint, url: try XCTUnwrap(URL(string: "http://myterm-test.invalid/page")))
        let deadline = Date().addingTimeInterval(15)
        while browser.webView?.title != "Remote websocket", browser.error == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(browser.webView?.title, "Remote websocket", browser.error ?? "WebSocket did not deliver its text frame")
        let destinations = await bridge.destinations()
        XCTAssertGreaterThanOrEqual(destinations.filter { $0 == "myterm-test.invalid" }.count, 2)
        XCTAssertTrue(destinations.contains(socketHost), "The WebSocket must open its own encrypted-proxy destination")
        browser.stop()
        await bridge.stop()
    }

    /// Media permission prompts must not change the proxy-boundary diagnostic.
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
        registerCleanup(browser, bridge: bridge)
        let endpoint = try await bridge.endpoint()
        try await startRemoteFixture(browser, endpoint: endpoint, url: try XCTUnwrap(URL(string: "http://myterm-test.invalid/page")))
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

    /// A remote-only hostname must resolve through the host tunnel, never on the device.
    func testOffscreenWKWebViewLoadsRemoteHostnameThroughEncryptedProxy() async throws {
        let fixture = try BrowserHTTPFixture()
        let port = try await fixture.start()
        defer { fixture.stop() }
        let bridge = EncryptedBrowserBridge()
        await bridge.configure(destinationPort: port)
        let endpoint = try await bridge.endpoint()
        let browser = NativeRemoteBrowser()
        registerCleanup(browser, bridge: bridge)
        try await startRemoteFixture(browser, endpoint: endpoint, url: try XCTUnwrap(URL(string: "http://myterm-test.invalid/page")))
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

    /// Loopback protection must include obfuscated addresses as well as localhost.
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
        registerCleanup(browser, bridge: bridge)
        let endpoint = try await bridge.endpoint()
        try await startRemoteFixture(browser, endpoint: endpoint, url: try XCTUnwrap(URL(string: "http://myterm-test.invalid/page")))
        let deadline = Date().addingTimeInterval(15)
        while browser.webView?.title != "Remote fixture", browser.error == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(browser.webView?.title, "Remote fixture", browser.error ?? "Remote page did not load")
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(deviceLocal.requests, 0, "Subresources must never contact the companion device's loopback")
        XCTAssertEqual(deviceLocal.receivedHeaderBytes, 0, "Even a partial loopback request must be blocked")
        browser.stop()
        await bridge.stop()
    }

    /// A late navigation callback cannot undo a policy denial or enable direct traffic.
    func testOffscreenWKWebViewRejectsLocalhostInsteadOfBypassingProxy() async throws {
        let fixture = try BrowserHTTPFixture()
        let port = try await fixture.start()
        defer { fixture.stop() }
        let bridge = EncryptedBrowserBridge()
        await bridge.configure()
        let endpoint = try await bridge.endpoint()
        let browser = NativeRemoteBrowser()
        registerCleanup(browser, bridge: bridge)
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/"))
        try await browser.start(endpoint, url: url, dataStore: .nonPersistent())
        XCTAssertEqual(browser.error, "Use Mac rendered mode for localhost or IP addresses.")
        browser.webView(try XCTUnwrap(browser.webView), didFinish: nil)
        XCTAssertEqual(browser.error, "Use Mac rendered mode for localhost or IP addresses.",
                       "A late page completion must not erase a policy rejection")
        XCTAssertNil(browser.webView?.url)
        let destinations = await bridge.destinations()
        XCTAssertTrue(destinations.isEmpty)
        XCTAssertEqual(fixture.requests, 0, "A denied address must not bypass the proxy")
        XCTAssertEqual(fixture.receivedHeaderBytes, 0, "Even partial direct loopback traffic must be blocked")
        await bridge.stop()
        browser.stop()
    }
}
