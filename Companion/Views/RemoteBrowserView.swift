import Darwin
import MyTermCore
import MyTermRemote
import Network
import Observation
import SwiftUI
import WebKit

@MainActor @Observable
final class NativeRemoteBrowser: NSObject, WKNavigationDelegate, WKUIDelegate {
    var webView: WKWebView?
    var address = ""
    var error: String? { didSet { isNetworkFailure = false } }
    @ObservationIgnored private var isNetworkFailure = false
    var loading = false
    var back = false
    var forward = false
    private(set) var artifactHost = UUID().uuidString.lowercased() + ".myterm-artifact.invalid"
    private var sourceFile: URL?
    private var observations: [NSKeyValueObservation] = []

    func start(_ endpoint: RemoteBrowserProxyEndpoint, url: URL?, sourceFile: URL? = nil) async throws {
        self.sourceFile = sourceFile
        artifactHost = UUID().uuidString.lowercased() + ".myterm-artifact.invalid"
        guard let port = NWEndpoint.Port(rawValue: endpoint.port) else { throw RemoteError.invalidMessage }
        let proxyEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
        var proxy: ProxyConfiguration
        switch endpoint.protocolKind {
        case .httpConnect: proxy = ProxyConfiguration(httpCONNECTProxy: proxyEndpoint, tlsOptions: nil)
        case .socks5: proxy = ProxyConfiguration(socksv5Proxy: proxyEndpoint)
        }
        proxy.matchDomains = ["localhost", "127.0.0.1", "::1", ""]
        proxy.excludedDomains = []
        proxy.allowFailover = false
        proxy.applyCredential(username: endpoint.username, password: endpoint.password)
        error = nil
        let store = WKWebsiteDataStore.nonPersistent()
        store.proxyConfigurations = [proxy]
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        configuration.allowsAirPlayForMediaPlayback = false
        var filters = ["localhost\\.*[:/]", ".*\\.localhost\\.*[:/]", "\\["]
        // Legacy IPv4 accepts decimal, octal, and hexadecimal components, including mixed forms.
        for count in 1...4 {
            for mask in 0..<(1 << count) {
                let parts = (0..<count).map { index in
                    mask & (1 << index) == 0 ? "[0-9]+" : "0x[0-9a-f]+"
                }
                filters.append(parts.joined(separator: "\\.") + "\\.*[:/]")
            }
        }
        var encodedRules: [[String: Any]] = ["https?://", "wss?://"].flatMap { scheme in
            filters.map { host in
                ["trigger": ["url-filter": "^" + scheme + "([^/]*@)?" + host, "url-filter-is-case-sensitive": false],
                 "action": ["type": "block"]]
            }
        }
        encodedRules.append(["trigger": ["url-filter": "^file://"], "action": ["type": "block"]])
        let ruleData = try JSONSerialization.data(withJSONObject: encodedRules)
        guard let rules = String(data: ruleData, encoding: .utf8) else { throw RemoteError.invalidMessage }
        let contentRule: WKContentRuleList = try await withCheckedThrowingContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "myterm-native-local-block",
                encodedContentRuleList: rules) { list, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let list { continuation.resume(returning: list) }
                    else { continuation.resume(throwing: RemoteError.invalidMessage) }
                }
        }
        try Task.checkCancellation()
        configuration.userContentController.add(contentRule)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        observations = [view.observe(\.isLoading) { [weak self] view, _ in
            Task { @MainActor in if self?.webView === view { self?.loading = view.isLoading } }
        }, view.observe(\.canGoBack) { [weak self] view, _ in
            Task { @MainActor in if self?.webView === view { self?.back = view.canGoBack } }
        }, view.observe(\.canGoForward) { [weak self] view, _ in
            Task { @MainActor in if self?.webView === view { self?.forward = view.canGoForward } }
        }, view.observe(\.url) { [weak self] view, _ in
            Task { @MainActor in if self?.webView === view { self?.address = view.url?.absoluteString ?? "" } }
        }]
        webView = view
        if let url { load(Self.remoteURL(url, source: sourceFile, artifactHost: artifactHost)) }
    }

    static func remoteURL(_ url: URL, source: URL? = nil, artifactHost: String) -> URL {
        guard url.isFileURL else { return url }
        var components = URLComponents()
        components.scheme = "http"
        components.host = artifactHost
        let root = (source ?? url).deletingLastPathComponent().standardizedFileURL
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root.path + "/") else { return url }
        components.path = String(path.dropFirst(root.path.count))
        components.query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.query
        components.fragment = url.fragment
        return components.url ?? url
    }

    static func requiresMacRendering(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") || host.contains(":") { return true }
        var address = in_addr()
        return host.withCString { inet_aton($0, &address) == 1 }
    }

    static func addressURL(_ value: String) -> URL? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let input = text.contains("://") ? text : "https://" + text
        guard let url = URL(string: input), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }

    func submit() {
        guard let url = Self.addressURL(address) else { error = "Enter an HTTP or HTTPS address."; return }
        load(url)
    }

    private func load(_ url: URL) {
        guard Self.addressURL(url.absoluteString) != nil else { error = "Unsupported address type."; return }
        guard !Self.requiresMacRendering(url) else {
            error = "Use Mac rendered mode for localhost or IP addresses."
            return
        }
        error = nil
        address = url.absoluteString
        webView?.load(URLRequest(url: url))
    }

    func stop() {
        webView?.stopLoading()
        observations.removeAll()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView = nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = action.request.url, url.isFileURL {
            let remote = Self.remoteURL(url, source: sourceFile, artifactHost: artifactHost)
            if !remote.isFileURL { load(remote) }
            else { error = "This file is outside the shared artifact folder." }
            decisionHandler(.cancel)
            return
        }
        guard let url = action.request.url,
              Self.addressURL(url.absoluteString) != nil || url.absoluteString == "about:blank" else {
            error = "This link uses an unsupported address type."
            decisionHandler(.cancel)
            return
        }
        guard !Self.requiresMacRendering(url) else {
            error = "Use Mac rendered mode for localhost or IP addresses."
            decisionHandler(.cancel)
            return
        }
        if action.targetFrame?.isMainFrame == true { error = nil }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil, let url = action.request.url { load(url) }
        return nil
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard self.webView === webView else { return }
        error = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard self.webView === webView, isNetworkFailure else { return }
        error = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard self.webView === webView else { return }
        report(error)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard self.webView === webView else { return }
        report(error)
    }
    private func report(_ failure: Error) {
        guard (failure as NSError).code != NSURLErrorCancelled else { return }
        loading = false
        error = failure.localizedDescription
        isNetworkFailure = true
    }
}

private struct NativeBrowserSurface: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct RemoteBrowserView: View {
    let scene: SceneModel
    let route: BrowserRoute
    /// Sits beside the mode picker rather than over it. Floated on top, the tab's actions menu
    /// landed on the picker's trailing segment and covered its label.
    ///
    /// Erased rather than generic so the pure helpers on this type stay callable without naming
    /// an accessory that has nothing to do with them.
    var accessory: () -> AnyView = { AnyView(EmptyView()) }
    @State private var native = NativeRemoteBrowser()
    @State private var mode = "native"
    @State private var rendered: RemoteBrowserFrame?
    @State private var renderAddress = ""
    @FocusState private var isEditingAddress: Bool
    @State private var renderError: String?
    @State private var text = ""
    @State private var busy = false
    @State private var generation = UUID()
    @State private var proxyOwner: UUID?
    @State private var rendererOwner: UUID?
    @State private var initialized = false
    @State private var retryID = UUID()
    @State private var fallbackURL: URL?
    @State private var actionRevision = 0
    @State private var viewport = CGSize(width: 1024, height: 768)

    private var preferenceKey: String { "browserMode." + route.connectionID.relayOrigin + "." + route.hostID.uuidString }

    var body: some View {
        @Bindable var native = native
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Browser mode", selection: Binding(get: { mode }, set: { value in
                    UserDefaults.standard.set(value, forKey: preferenceKey)
                    mode = value
                })) {
                    Text("Native proxy").tag("native")
                    Text("Mac rendered").tag("rendered")
                }.pickerStyle(.segmented)
                accessory()
            }.padding(8)
            if mode == "native" {
                HStack {
                    Button("Back", systemImage: "chevron.left") { native.webView?.goBack() }.disabled(!native.back)
                    Button("Forward", systemImage: "chevron.right") { native.webView?.goForward() }.disabled(!native.forward)
                    addressField($native.address) { native.submit() }
                    Button(native.loading ? "Stop" : "Reload", systemImage: native.loading ? "xmark" : "arrow.clockwise") {
                        if native.loading { native.webView?.stopLoading() } else { native.webView?.reload() }
                    }
                }.padding(8)
                if native.loading { ProgressView().progressViewStyle(.linear) }
                if let error = native.error {
                    errorLabel(error)
                    Button("Open with Mac rendered mode") {
                        fallbackURL = NativeRemoteBrowser.addressURL(native.address)
                        UserDefaults.standard.set("rendered", forKey: preferenceKey)
                        mode = "rendered"
                    }.padding(.bottom, 8)
                }
                if let webView = native.webView { NativeBrowserSurface(webView: webView) }
                else if native.error != nil {
                    ContentUnavailableView("Browser unavailable", systemImage: "network.slash")
                } else { ProgressView("Connecting browser").frame(maxWidth: .infinity, maxHeight: .infinity) }
            } else {
                renderedBrowser
            }
        }.buttonStyle(.plain)
        .onAppear {
            guard !initialized else { return }
            if let url = route.url, NativeRemoteBrowser.requiresMacRendering(url) { mode = "rendered" }
            else { mode = UserDefaults.standard.string(forKey: preferenceKey) == "rendered" ? "rendered" : "native" }
            initialized = true
        }
        .task(id: "\(initialized)|\(mode)|\(retryID)") {
            if initialized { await startMode() }
        }
        .onDisappear {
            generation = UUID()
            native.stop()
            let owner = proxyOwner
            let renderOwner = rendererOwner
            proxyOwner = nil
            rendererOwner = nil
            Task {
                if let owner { await scene.closeBrowserProxy(route, owner: owner) }
                do { try await closeRenderer(renderOwner) }
                catch { await DiagnosticsLog.shared.record(category: "browser", "renderer cleanup failed", detail: error.localizedDescription) }
            }
        }
    }

    private func addressField(_ binding: Binding<String>, submit: @escaping () -> Void) -> some View {
        TextField("Address on connected Mac", text: binding)
            .focused($isEditingAddress)
            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            .submitLabel(.go).onSubmit(submit).accessibilityIdentifier("remote-browser-address")
    }

    private func errorLabel(_ value: String) -> some View {
        Text(value).font(.caption).foregroundStyle(.red).padding(8)
    }

    private var renderedBrowser: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Back", systemImage: "chevron.left") { send(.back) }.disabled(rendered?.canGoBack != true)
                Button("Forward", systemImage: "chevron.right") { send(.forward) }.disabled(rendered?.canGoForward != true)
                addressField($renderAddress) { send(.navigate, url: NativeRemoteBrowser.addressURL(renderAddress)?.absoluteString ?? renderAddress) }
                Button("Reload", systemImage: "arrow.clockwise") { send(.reload) }
            }.padding(8)
            if busy || rendered?.isLoading == true { ProgressView().progressViewStyle(.linear) }
            if let error = renderError ?? rendered?.error {
                errorLabel(error)
                Button("Retry Mac browser") { retryID = UUID() }.padding(.bottom, 8)
            }
            GeometryReader { geometry in
                if let frame = rendered, let image = UIImage(data: frame.image) {
                    let fit = Self.fittedSize(image: CGSize(width: frame.width, height: frame.height), bounds: geometry.size)
                    Image(uiImage: image).resizable().frame(width: fit.width, height: fit.height)
                        .contentShape(Rectangle())
                        .gesture(SpatialTapGesture().onEnded { value in
                            send(.tap, x: Double(value.location.x / fit.width), y: Double(value.location.y / fit.height))
                        })
                        .simultaneousGesture(DragGesture(minimumDistance: 12).onEnded { value in
                            send(.scroll, deltaX: Double(-value.translation.width * CGFloat(frame.width) / fit.width),
                                 deltaY: Double(-value.translation.height * CGFloat(frame.height) / fit.height))
                        })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if renderError != nil {
                    ContentUnavailableView("Browser unavailable", systemImage: "network.slash")
                } else { ProgressView("Rendering on Mac").frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
            .onGeometryChange(for: CGSize.self) { Self.renderViewport($0.size) } action: { viewport = $0 }
            HStack {
                TextField("Type into focused field on Mac", text: $text).autocorrectionDisabled()
                    .onSubmit { sendText() }
                Button("Send", systemImage: "paperplane") { sendText() }.disabled(text.isEmpty)
                Button("Enter") { send(.key, key: .enter) }
                Button("⌫") { send(.key, key: .backspace) }
                Button("Tab") { send(.key, key: .tab) }
            }.padding(8)
        }
    }

    static func renderingURL(_ url: URL?, source: URL?, artifactHost: String) -> URL? {
        guard let url, url.host == artifactHost else { return url }
        guard let source, source.isFileURL else { return nil }
        let root = source.deletingLastPathComponent().standardizedFileURL
        let relative = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let result = root.appendingPathComponent(relative).standardizedFileURL
        guard result.path.hasPrefix(root.path + "/") else { return nil }
        var components = URLComponents(url: result, resolvingAgainstBaseURL: false)
        components?.query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.query
        components?.fragment = url.fragment
        return components?.url
    }

    static func pollDelay(failures: Int) -> Double {
        min(8, 0.8 * pow(2, Double(max(0, min(4, failures)))))
    }

    static func renderViewport(_ available: CGSize) -> CGSize {
        CGSize(width: max(320, min(1600, available.width.rounded())),
               height: max(240, min(1200, available.height.rounded())))
    }

    static func fittedSize(image: CGSize, bounds: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / image.width, bounds.height / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }

    private func startMode() async {
        let token = UUID()
        generation = token
        let previousRendererOwner = rendererOwner
        rendererOwner = nil
        let renderedURL = rendered.flatMap { $0.url.isEmpty ? nil : URL(string: $0.url) }
        let previousURL = fallbackURL?.absoluteString ?? (mode == "rendered"
            ? Self.renderingURL(native.webView?.url ?? renderedURL, source: route.url, artifactHost: native.artifactHost)?.absoluteString
            : renderedURL?.absoluteString)
        fallbackURL = nil
        native.stop()
        busy = false
        renderError = nil
        if let owner = proxyOwner { await scene.closeBrowserProxy(route, owner: owner) }
        proxyOwner = nil
        guard generation == token, !Task.isCancelled else { return }
        do {
            if mode == "native" {
                do { try await closeRenderer(previousRendererOwner) }
                catch {
                    await DiagnosticsLog.shared.record(category: "browser", "renderer cleanup failed", detail: error.localizedDescription)
                }
                guard generation == token, !Task.isCancelled else { return }
                proxyOwner = token
                let endpoint = try await scene.openBrowserProxy(route, owner: token)
                guard generation == token, !Task.isCancelled else {
                    await scene.closeBrowserProxy(route, owner: token)
                    return
                }
                try await native.start(endpoint, url: previousURL.flatMap(URL.init(string:)) ?? route.url, sourceFile: route.url)
            } else {
                rendered = nil
                rendererOwner = token
                let frame = try await browserCommand(.open, url: previousURL, rendererID: token)
                guard generation == token, !Task.isCancelled else { return }
                rendered = frame
                renderAddress = rendered?.url ?? ""
                var failures = 0
                while !Task.isCancelled, generation == token {
                    try await Task.sleep(for: .seconds(Self.pollDelay(failures: failures)))
                    guard !busy else { continue }
                    let revision = actionRevision
                    do {
                        let action: RemoteBrowserAction = failures >= 3 ? .open : .snapshot
                        let recoveryURL = rendered?.url
                        let recoveryScheme = recoveryURL.flatMap(URL.init(string:))?.scheme?.lowercased() ?? ""
                        let address = action == .open && ["http", "https", "file"].contains(recoveryScheme) ? recoveryURL : nil
                        let frame = try await browserCommand(action, url: address, rendererID: token)
                        guard generation == token else { return }
                        if !busy, actionRevision == revision {
                            rendered = frame
                            if !isEditingAddress { renderAddress = frame.url }
                        }
                        renderError = nil
                        failures = 0
                    } catch is CancellationError { return }
                    catch {
                        guard generation == token else { return }
                        failures = min(failures + 1, 4)
                        renderError = error.localizedDescription
                    }
                }
            }
        } catch is CancellationError { return }
        catch {
            guard generation == token else { return }
            if mode == "native" { native.error = error.localizedDescription }
            else { renderError = error.localizedDescription }
        }
    }

    private func sendText() {
        guard !busy, !text.isEmpty else { return }
        let value = text
        send(.text, text: value)
    }

    private func send(_ action: RemoteBrowserAction, url: String? = nil, x: Double? = nil, y: Double? = nil,
                      deltaX: Double? = nil, deltaY: Double? = nil, text: String? = nil, key: RemoteBrowserKey? = nil) {
        guard !busy else { return }
        busy = true
        actionRevision += 1
        let token = generation
        Task {
            defer { if generation == token { busy = false } }
            do {
                let frame = try await browserCommand(action, url: url, x: x, y: y,
                    deltaX: deltaX, deltaY: deltaY, text: text, key: key, rendererID: token)
                guard generation == token else { return }
                rendered = frame
                if action == .text, self.text == text { self.text = "" }
                renderAddress = frame.url
                renderError = nil
            } catch RemoteError.timedOut {
                if generation == token {
                    renderError = "The response timed out. The Mac may have already applied this action; check the page before retrying."
                }
            } catch { if generation == token { renderError = error.localizedDescription } }
        }
    }

    private func closeRenderer(_ owner: UUID?) async throws {
        guard let owner else { return }
        let request = try RemoteBrowserRequest(action: .close, rendererID: owner)
        _ = try await scene.command(.browserInteract, metadata: MessageMetadata(
            hostID: route.hostID, workspaceID: route.workspaceID, groupID: route.groupID, tabID: route.tabID),
            payload: JSONEncoder().encode(request))
    }

    private func browserCommand(_ action: RemoteBrowserAction, url: String? = nil,
        x: Double? = nil, y: Double? = nil, deltaX: Double? = nil, deltaY: Double? = nil,
        text: String? = nil, key: RemoteBrowserKey? = nil, rendererID: UUID? = nil) async throws -> RemoteBrowserFrame {
        let request = try RemoteBrowserRequest(action: action, rendererID: rendererID, width: Int(viewport.width), height: Int(viewport.height), url: url, x: x, y: y,
            deltaX: deltaX.map { max(-2000, min(2000, $0)) },
            deltaY: deltaY.map { max(-2000, min(2000, $0)) }, text: text, key: key)
        let data = try await scene.command(.browserInteract, metadata: MessageMetadata(
            hostID: route.hostID, workspaceID: route.workspaceID, groupID: route.groupID, tabID: route.tabID),
            payload: JSONEncoder().encode(request))
        return try JSONDecoder().decode(RemoteBrowserFrame.self, from: data ?? Data())
    }
}
