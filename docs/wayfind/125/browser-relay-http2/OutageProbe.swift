import Foundation
import Network
import Security
import WebKit

private final class ClientOriginObserver: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var accepted = 0

    init() throws {
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        listener = try NWListener(using: parameters, on: .any)
    }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            if let self { self.lock.withLock { self.accepted += 1 } }
            connection.cancel()
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    if let port = listener.port { continuation.resume(returning: port.rawValue) }
                    else { continuation.resume(throwing: NSError(domain: "Client origin observer", code: 1)) }
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: .global())
        }
    }

    func count() -> Int { lock.withLock { accepted } }
    func stop() { listener.cancel() }
}

@MainActor enum OutageProbe {
    static func run(relayHost: String, relayPort: UInt16, certificate: SecCertificate) async throws -> [String: Any] {
        let observer = try ClientOriginObserver()
        let clientPort = try await observer.start()
        defer { observer.stop() }
        let host = "outage-origin.localhost.direct"
        guard let endpoint = URL(string: "https://\(relayHost):\(relayPort)"),
              let target = URL(string: "https://\(host):\(clientPort)/outage-proof") else {
            throw NSError(domain: "Outage fixture URL", code: 1)
        }
        var proxy = ProxyConfiguration(relayHops: [.init(http2RelayEndpoint: .url(endpoint))])
        proxy.allowFailover = false
        let store = WKWebsiteDataStore.nonPersistent()
        store.proxyConfigurations = [proxy]
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        let browser = WKWebView(frame: .zero, configuration: configuration)
        let leaf = ApprovedOrigin(server: "A", host: host, port: Int(clientPort), certificate: certificate)
        let inspector = Inspector(server: "A", exception: leaf)
        browser.navigationDelegate = inspector

        let initial = try await load(browser, inspector: inspector, target: target, phase: "initial")
        guard initial["title"] as? String == "ORIGIN_TLS_FIXTURE", observer.count() == 0 else {
            throw NSError(domain: "Outage fixture could not verify the initial proxied route", code: 2)
        }
        try signal("outage-ready")
        try await waitForSignal("outage-stopped")
        let beforeOutage = observer.count()
        let during = try await load(browser, inspector: inspector, target: target, phase: "during")
        let clientConnectionsDuringOutage = observer.count() - beforeOutage
        try signal("outage-observed")
        try await waitForSignal("outage-restored")
        let recovered = try await load(browser, inspector: inspector, target: target, phase: "recovered")
        let clientConnectionsTotal = observer.count()
        guard let observerPort = NWEndpoint.Port(rawValue: clientPort) else {
            throw NSError(domain: "Outage fixture client port", code: 2)
        }
        let positiveControl = NWConnection(host: "127.0.0.1", port: observerPort, using: .tcp)
        positiveControl.start(queue: .global())
        defer { positiveControl.cancel() }
        let observerDeadline = ContinuousClock.now + .seconds(2)
        while observer.count() == clientConnectionsTotal && ContinuousClock.now < observerDeadline {
            try await Task.sleep(for: .milliseconds(30))
        }
        return [
            "initial": initial, "during": during, "recovered": recovered,
            "clientConnectionsDuringOutage": clientConnectionsDuringOutage,
            "clientConnectionsTotal": clientConnectionsTotal,
            "observerPositiveControlConnections": observer.count() - clientConnectionsTotal
        ]
    }

    private static func load(_ browser: WKWebView, inspector: Inspector,
                             target: URL, phase: String) async throws -> [String: Any] {
        guard var components = URLComponents(url: target, resolvingAgainstBaseURL: false) else {
            throw NSError(domain: "Outage fixture URL", code: 1)
        }
        components.queryItems = [URLQueryItem(name: "phase", value: phase)]
        guard let url = components.url else { throw NSError(domain: "Outage fixture URL", code: 1) }
        inspector.finished = false
        inspector.failure = nil
        browser.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4))
        let deadline = ContinuousClock.now + .seconds(5)
        while !inspector.finished && inspector.failure == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(30))
        }
        browser.stopLoading()
        return [
            "requestedURL": url.absoluteString,
            "title": browser.title ?? "",
            "finished": inspector.finished,
            "errorCode": inspector.failure?.code ?? 0
        ]
    }

    private static func signal(_ name: String) throws {
        try Data("ready\n".utf8).write(to: URL(fileURLWithPath: name), options: .atomic)
    }

    private static func waitForSignal(_ name: String) async throws {
        let deadline = ContinuousClock.now + .seconds(6)
        while ContinuousClock.now < deadline {
            if FileManager.default.fileExists(atPath: name) { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw NSError(domain: "Missing outage fixture signal \(name)", code: 3)
    }
}
