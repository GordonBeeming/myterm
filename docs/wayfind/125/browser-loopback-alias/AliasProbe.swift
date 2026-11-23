import Darwin
import Foundation
import Network
import Security
import WebKit

#if os(iOS)
import UIKit
#else
import AppKit
#endif

private enum ProbeError: Error { case configuration, timeout, route(String), invalidResponse }

private func socketAddress<T>(_ host: String, port: UInt16, use: (addrinfo) throws -> T) throws -> T {
    var hints = addrinfo()
    hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV
    hints.ai_socktype = SOCK_STREAM
    var result: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, String(port), &hints, &result) == 0, let result else {
        throw ProbeError.configuration
    }
    defer { freeaddrinfo(result) }
    return try use(result.pointee)
}

private final class LocalObserver: @unchecked Sendable {
    let port: UInt16
    private let source: DispatchSourceRead
    private let lock = NSLock()
    private var connections = 0

    init(host: String) throws {
        let descriptor = try socketAddress(host, port: 0) { address in
            let descriptor = Darwin.socket(address.ai_family, address.ai_socktype, address.ai_protocol)
            guard descriptor >= 0 else { throw ProbeError.route("observer socket failed") }
            guard Darwin.bind(descriptor, address.ai_addr, address.ai_addrlen) == 0,
                  Darwin.listen(descriptor, 16) == 0,
                  fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else {
                let failure = errno
                Darwin.close(descriptor)
                throw ProbeError.route("observer listener failed: \(failure)")
            }
            return descriptor
        }
        var address = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        var service = [CChar](repeating: 0, count: 8)
        let status = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer -> Int32 in
                guard getsockname(descriptor, pointer, &length) == 0 else { return -1 }
                return getnameinfo(pointer, length, nil, 0, &service, 8, NI_NUMERICSERV)
            }
        }
        guard status == 0, let port = UInt16(String(cString: service)), port > 0 else {
            Darwin.close(descriptor)
            throw ProbeError.route("could not read observer port")
        }
        self.port = port
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .global())
        source.setCancelHandler { Darwin.close(descriptor) }
        source.setEventHandler { [weak self] in
            while true {
                let peer = Darwin.accept(descriptor, nil, nil)
                guard peer >= 0 else { break }
                if let self { self.lock.withLock { self.connections += 1 } }
                Darwin.close(peer)
            }
        }
        source.resume()
    }

    func control(host: String) throws {
        try socketAddress(host, port: port) { address in
            let descriptor = Darwin.socket(address.ai_family, address.ai_socktype, address.ai_protocol)
            guard descriptor >= 0 else { throw ProbeError.route("control socket failed") }
            defer { Darwin.close(descriptor) }
            guard Darwin.connect(descriptor, address.ai_addr, address.ai_addrlen) == 0 else {
                throw ProbeError.route("client observer control errno \(errno) at \(host)")
            }
        }
    }

    func count() -> Int { lock.withLock { connections } }
    func stop() { source.cancel() }
}

private func isLiteralLoopback(_ url: URL) -> Bool {
    guard let host = url.host(percentEncoded: false)?.lowercased() else { return false }
    let name = host.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    return name == "localhost" || name.hasSuffix(".localhost") || name.hasPrefix("127.")
        || name == "::1" || name == "[::1]"
}

@MainActor private final class Navigation: NSObject, WKNavigationDelegate {
    let host: String
    let pin: SecCertificate?
    var finished = false
    var error: NSError?
    var acceptedPin = false
    var blockedByPolicy = false

    init(host: String, pin: SecCertificate?) {
        self.host = host
        self.pin = pin
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = action.request.url, isLiteralLoopback(url) {
            blockedByPolicy = true
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard let pin, space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              space.host == host, space.port == 443, let trust = space.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        _ = SecTrustEvaluateWithError(trust, nil)
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first,
              (SecCertificateCopyData(leaf) as Data) == (SecCertificateCopyData(pin) as Data) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        var scoped: SecTrust?
        guard SecTrustCreateWithCertificates(leaf, SecPolicyCreateSSL(true, host as CFString), &scoped) == errSecSuccess,
              let scoped, SecTrustSetAnchorCertificates(scoped, [pin] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(scoped, true) == errSecSuccess,
              SecTrustEvaluateWithError(scoped, nil) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        acceptedPin = true
        completionHandler(.useCredential, URLCredential(trust: scoped))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.error = error as NSError
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.error = error as NSError
    }
}

@MainActor private func measure(directory: URL, certificate: URL) async throws -> Data {
    let environment = ProcessInfo.processInfo.environment
    guard let host = environment["MYTERM_ALIAS_HOST"], let address = environment["MYTERM_ALIAS_PROXY"],
          let proxy = URL(string: address), let base = URL(string: "https://\(host)"),
          let pin = SecCertificateCreateWithData(nil, try Data(contentsOf: certificate) as CFData) else {
        throw ProbeError.configuration
    }
    let ipv4 = try LocalObserver(host: "127.0.0.1")
    defer { ipv4.stop() }
    let ipv6 = try LocalObserver(host: "::1")
    defer { ipv6.stop() }
    for (address, observer) in [("127.0.0.1", ipv4), ("::1", ipv6)] {
        try observer.control(host: address)
        let limit = ContinuousClock.now + .seconds(4)
        while observer.count() == 0 && ContinuousClock.now < limit {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard observer.count() > 0 else { throw ProbeError.route("client observer control failed at \(address)") }
    }
    func totalConnections() -> Int { ipv4.count() + ipv6.count() }
    let startingConnections = totalConnections()

    let ruleStore = WKContentRuleListStore(url: directory.appendingPathComponent("content-rules"))
    let forms = [#"localhost[:/]"#, #"[^/:]+\.localhost[:/]"#, #"127\.[0-9.]+[:/]"#, #"\[::1\][:/]"#]
    let filters: [[String: Any]] = forms.map {
        ["trigger": ["url-filter": "^https?://([^/]*@)?" + $0, "url-filter-is-case-sensitive": false],
         "action": ["type": "block"]]
    }
    let loopbackRules = String(decoding: try JSONSerialization.data(withJSONObject: filters), as: UTF8.self)
    let rules: WKContentRuleList = try await withCheckedThrowingContinuation { continuation in
        guard let ruleStore else { continuation.resume(throwing: ProbeError.configuration); return }
        ruleStore.compileContentRuleList(forIdentifier: "loopback-fixture", encodedContentRuleList: loopbackRules) { list, error in
            if let list { continuation.resume(returning: list) }
            else { continuation.resume(throwing: error ?? ProbeError.configuration) }
        }
    }

    func browser() -> WKWebView {
        var routing = ProxyConfiguration(relayHops: [.init(http2RelayEndpoint: .url(proxy))])
        routing.allowFailover = false
        let store = WKWebsiteDataStore.nonPersistent()
        store.proxyConfigurations = [routing]
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        configuration.defaultWebpagePreferences.isLockdownModeEnabled = true
        configuration.userContentController.add(rules)
        return WKWebView(frame: .zero, configuration: configuration)
    }

    guard let unknown = URL(string: "https://unknown.dev.myterm.test/login") else { throw ProbeError.configuration }
    let wrongHostname = try await navigate(browser(), to: unknown, host: host, pin: pin)
    let unapproved = try await navigate(browser(), to: base.appendingPathComponent("login"), host: host, pin: nil)
    let view = browser()
    let login = try await navigate(view, to: base.appendingPathComponent("login"), host: host, pin: pin)
    guard login.finished, view.title == "ASSIGNED_LOOPBACK_ORIGIN" else {
        throw ProbeError.route("alias login did not load: \(login.error?.code ?? 0)")
    }
    let finalURL = view.url?.absoluteString ?? ""
    let state = try await view.callAsyncJavaScript("""
        const response = await fetch('/session');
        const session = await response.json();
        localStorage.setItem('fixture-alias', 'saved-at-alias');
        const frame = document.createElement('iframe');
        const loaded = new Promise(resolve => { frame.onload = resolve; });
        frame.srcdoc = '<!doctype html><p>frame</p>';
        document.body.append(frame);
        await loaded;
        return {origin: location.origin, color: getComputedStyle(document.getElementById('marker')).color,
                signedIn: session.signedIn, serverHost: session.host, localStorage: localStorage.getItem('fixture-alias'),
                webRTC: typeof RTCPeerConnection, embeddedWebRTC: typeof frame.contentWindow.RTCPeerConnection};
        """, arguments: [:], in: nil, contentWorld: .page)
    let localURLs = ["http://localhost:\(ipv4.port)/probe", "http://127.0.0.1:\(ipv4.port)/probe",
                     "http://[::1]:\(ipv6.port)/probe"]
    let beforeSubresources = totalConnections()
    let subresources = try await view.callAsyncJavaScript("""
        return await Promise.all(urls.map(async url => {
            try { await fetch(url, {mode: 'no-cors', signal: AbortSignal.timeout(2500)}); return 'loaded'; }
            catch { return 'blocked'; }
        }));
        """, arguments: ["urls": localURLs], in: nil, contentWorld: .page)
    let afterSubresources = totalConnections()
    var literalNavigations: [[String: Any]] = []
    for address in localURLs {
        guard let url = URL(string: address) else { throw ProbeError.configuration }
        let typedAddress = try await navigate(view, to: url, host: host, pin: pin)
        let navigation = Navigation(host: host, pin: pin)
        view.navigationDelegate = navigation
        _ = try await view.callAsyncJavaScript("location.assign(url); return 'requested';",
                                               arguments: ["url": address], in: nil, contentWorld: .page)
        let deadline = ContinuousClock.now + .seconds(2)
        while !navigation.blockedByPolicy && navigation.error == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(30))
        }
        literalNavigations.append(["url": address, "appBlockedBeforeLoad": typedAddress.blockedByPolicy,
                                   "pageBlockedByDelegate": navigation.blockedByPolicy])
    }
    return try JSONSerialization.data(withJSONObject: [
        "clientOS": ProcessInfo.processInfo.operatingSystemVersionString,
        "unconfiguredAliasLoaded": wrongHostname.finished,
        "unconfiguredAliasError": wrongHostname.error?.code ?? 0,
        "unapprovedCertificateError": unapproved.error?.code ?? 0,
        "scopedCertificateAccepted": login.acceptedPin,
        "finalURL": finalURL,
        "page": state as? [String: Any] ?? [:],
        "loopbackSubresources": subresources as? [String] ?? [],
        "literalNavigations": literalNavigations,
        "observerConnectionsDuringSubresources": afterSubresources - beforeSubresources,
        "observerConnectionsDuringNavigations": totalConnections() - afterSubresources,
        "observerControlConnections": startingConnections,
        "observerBrowserConnections": totalConnections() - startingConnections
    ], options: [.prettyPrinted, .sortedKeys])
}

@MainActor private func navigate(_ view: WKWebView, to target: URL, host: String, pin: SecCertificate?) async throws -> Navigation {
    let delegate = Navigation(host: host, pin: pin)
    if isLiteralLoopback(target) {
        delegate.blockedByPolicy = true
        return delegate
    }
    view.navigationDelegate = delegate
    view.load(URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6))
    let deadline = ContinuousClock.now + .seconds(7)
    while !delegate.finished && delegate.error == nil && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(30))
    }
    if !delegate.finished && delegate.error == nil { view.stopLoading(); throw ProbeError.timeout }
    return delegate
}

#if os(iOS)
@main final class AliasApp: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = AliasScene.self
        return configuration
    }
}
final class AliasScene: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        self.window = window
        window.makeKeyAndVisible()
        Task {
            let output = URL.documentsDirectory.appendingPathComponent("alias-results.json")
            do {
                guard let certificate = Bundle.main.url(forResource: "origin", withExtension: "der") else {
                    throw ProbeError.configuration
                }
                let data = try await measure(directory: .documentsDirectory, certificate: certificate)
                try data.write(to: output, options: .atomic)
            } catch {
                if let data = try? JSONSerialization.data(withJSONObject: ["fixtureError": String(describing: error)]) {
                    try? data.write(to: output, options: .atomic)
                }
            }
        }
    }
}
#else
@main struct DesktopAliasProbe {
    @MainActor static func main() async {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        do {
            let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            let data = try await measure(directory: directory, certificate: directory.appendingPathComponent("origin.der"))
            print(String(decoding: data, as: UTF8.self))
        } catch {
            fputs("Alias fixture failed: \(error)\n", stderr)
            exit(1)
        }
    }
}
#endif
