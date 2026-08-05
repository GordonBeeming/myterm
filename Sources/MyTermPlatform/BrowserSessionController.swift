import AppKit
@preconcurrency import WebKit
import Foundation
import MyTermCore
import OSLog
import SwiftUI

public struct BrowserSessionState: Equatable, Sendable {
    public fileprivate(set) var url: URL?
    public fileprivate(set) var title: String?
    public fileprivate(set) var canGoBack: Bool
    public fileprivate(set) var canGoForward: Bool
    public fileprivate(set) var isLoading: Bool
    public fileprivate(set) var estimatedProgress: Double
    public fileprivate(set) var errorDescription: String?

    public init(
        url: URL? = nil,
        title: String? = nil,
        canGoBack: Bool = false,
        canGoForward: Bool = false,
        isLoading: Bool = false,
        estimatedProgress: Double = 0,
        errorDescription: String? = nil
    ) {
        self.url = url
        self.title = title
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.isLoading = isLoading
        self.estimatedProgress = estimatedProgress
        self.errorDescription = errorDescription
    }
}

@MainActor
final class MyTermWebView: WKWebView {
    /// Chords the app owns. Empty means "let the page have everything", which is what the plain
    /// `WKWebView` behaviour was before this existed.
    var reservedChords: [KeyChord] = []
    var onMiddleClickURL: ((URL) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // AppKit offers key-downs to the key window's view hierarchy before the main menu, and WebKit
        // answers `true` for any chord the page handles — so a web page silently shadows the app's own
        // menu commands. Returning `false` here leaves the event unclaimed, and AppKit carries on to the
        // menu where the command actually lives. Verified both directions: without this the page's
        // handler runs and the menu item never fires.
        if KeyChordMatcher.matchesAny(reservedChords, event: event) {
            Logger.browserKeyEquivalents.trace(
                "Declining reserved chord so the app menu can claim it: \(event.charactersIgnoringModifiers ?? "", privacy: .public)"
            )
            return false
        }
        return super.performKeyEquivalent(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        openLinkUnderMiddleClick(at: point) { [weak self] handled in
            if !handled {
                self?.forwardOtherMouseDown(event)
            }
        }
    }

    func openLinkUnderMiddleClick(at point: CGPoint, completion: ((Bool) -> Void)? = nil) {
        let documentPoint = CGPoint(x: point.x, y: bounds.height - point.y)
        evaluateJavaScript(Self.linkLookupScript(at: documentPoint)) { [weak self] result, _ in
            guard let self else {
                completion?(false)
                return
            }
            guard let href = result as? String,
                  let url = URL(string: href),
                  let onMiddleClickURL else {
                completion?(false)
                return
            }
            onMiddleClickURL(url)
            completion?(true)
        }
    }

    private func forwardOtherMouseDown(_ event: NSEvent) {
        super.otherMouseDown(with: event)
    }

    static func linkLookupScript(at point: CGPoint) -> String {
        """
        (() => {
          const element = document.elementFromPoint(\(point.x), \(point.y));
          const link = element?.closest?.('a[href]');
          return link?.href ?? null;
        })()
        """
    }
}

private extension Logger {
    static let browserKeyEquivalents = Logger(
        subsystem: "com.gordonbeeming.myterm",
        category: "browser-key-equivalents"
    )
}

enum BrowserSessionAction: Equatable, Sendable {
    case back
    case forward
    case reload
    case reloadFromOrigin
    case stop
    case find(query: String, backwards: Bool)
    case zoomIn
    case zoomOut
    case resetZoom
}

@MainActor
public final class BrowserSessionController: NSObject, ObservableObject {
    @Published public private(set) var state = BrowserSessionState()
    private(set) var lastAction: BrowserSessionAction?

    public let webView: WKWebView
    public var onCloseRequest: (() -> Void)?
    public var onNewTabRequest: ((URL) -> Void)?
    public var allowsLocalFileJavaScript: Bool {
        didSet {
            guard allowsLocalFileJavaScript != oldValue,
                  webView.url?.isFileURL == true else { return }
            reload()
        }
    }
    private var observations = [NSKeyValueObservation]()

    public convenience override init() {
        self.init(configuration: WKWebViewConfiguration())
    }

    public convenience init(allowsLocalFileJavaScript: Bool) {
        self.init(
            configuration: WKWebViewConfiguration(),
            allowsLocalFileJavaScript: allowsLocalFileJavaScript
        )
    }

    public convenience init(
        profile: BrowserDataProfile,
        reservedChords: [KeyChord] = [],
        allowsLocalFileJavaScript: Bool = false
    ) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: profile.persistentStoreID)
        self.init(
            configuration: configuration,
            reservedChords: reservedChords,
            allowsLocalFileJavaScript: allowsLocalFileJavaScript
        )
    }

    public init(
        configuration: WKWebViewConfiguration,
        reservedChords: [KeyChord] = [],
        allowsLocalFileJavaScript: Bool = false
    ) {
        if #available(macOS 15.0, *) {
            // WebKit's macOS header hides this public property when the deployment target is below 15.
            configuration.setValue(
                NSWritingToolsBehavior.none.rawValue,
                forKey: "writingToolsBehavior"
            )
        }
        let webView = MyTermWebView(frame: .zero, configuration: configuration)
        webView.reservedChords = reservedChords
        self.webView = webView
        self.allowsLocalFileJavaScript = allowsLocalFileJavaScript
        super.init()

        webView.onMiddleClickURL = { [weak self] url in
            self?.onNewTabRequest?(url)
        }
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observations = [
            webView.observe(\.url, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refreshState() }
            },
            webView.observe(\.title, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refreshState() }
            },
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refreshState() }
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refreshState() }
            },
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refreshState() }
            },
            webView.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refreshState() }
            },
        ]
        refreshState()
    }

    deinit {
        observations.forEach { $0.invalidate() }
    }

    public func load(address: String) throws {
        try load(url: BrowserURLNormalizer.normalize(address))
    }

    static func fileReadAccessBoundary(for url: URL) -> URL {
        url.deletingLastPathComponent()
    }

    public func load(url: URL) throws {
        switch url.scheme?.lowercased() {
        case "http", "https":
            state.errorDescription = nil
            webView.load(URLRequest(url: url))
        case "file":
            guard url.isFileURL,
                  !url.path.isEmpty,
                  FileManager.default.fileExists(atPath: url.path) else {
                throw BrowserURLNormalizationError.invalidAddress(url.absoluteString)
            }
            state.errorDescription = nil
            webView.loadFileURL(
                url,
                allowingReadAccessTo: Self.fileReadAccessBoundary(for: url)
            )
        default:
            throw BrowserURLNormalizationError.invalidAddress(url.absoluteString)
        }
    }

    public func goBack() {
        guard webView.canGoBack else { return }
        lastAction = .back
        webView.goBack()
    }

    public func goForward() {
        guard webView.canGoForward else { return }
        lastAction = .forward
        webView.goForward()
    }

    public func reload() {
        lastAction = .reload
        webView.reload()
    }

    public func reloadFromOrigin() {
        lastAction = .reloadFromOrigin
        webView.reloadFromOrigin()
    }

    public func stopLoading() {
        lastAction = .stop
        webView.stopLoading()
    }

    public func find(
        _ query: String,
        backwards: Bool = false,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard !query.isEmpty else {
            completion?(false)
            return
        }
        lastAction = .find(query: query, backwards: backwards)
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        webView.find(query, configuration: configuration) { result in
            completion?(result.matchFound)
        }
    }

    public func zoomIn() {
        lastAction = .zoomIn
        webView.pageZoom = min(webView.pageZoom + 0.1, 5)
    }

    public func zoomOut() {
        lastAction = .zoomOut
        webView.pageZoom = max(webView.pageZoom - 0.1, 0.25)
    }

    public func resetZoom() {
        lastAction = .resetZoom
        webView.pageZoom = 1
    }

    static func configureNavigationPreferences(
        _ preferences: WKWebpagePreferences,
        for url: URL?,
        allowsLocalFileJavaScript: Bool = false
    ) {
        preferences.allowsContentJavaScript = url?.isFileURL != true || allowsLocalFileJavaScript
    }

    static func isHandledContentNavigation(_ error: Error) -> Bool {
        let error = error as NSError
        // WebKit reports this private-domain code after its built-in PDF or
        // media viewer successfully takes ownership of a navigation.
        return error.domain == "WebKitErrorDomain" && error.code == 204
    }

    func decideNavigationPolicy(
        for url: URL?,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping @MainActor @Sendable (
            WKNavigationActionPolicy,
            WKWebpagePreferences
        ) -> Void
    ) {
        Self.configureNavigationPreferences(
            preferences,
            for: url,
            allowsLocalFileJavaScript: allowsLocalFileJavaScript
        )
        decisionHandler(.allow, preferences)
    }

    func handleNewWindowRequest(_ request: URLRequest, buttonNumber: Int?) {
        if buttonNumber == 2,
           let url = request.url,
           let onNewTabRequest {
            onNewTabRequest(url)
            return
        }
        webView.load(request)
    }

    private func refreshState() {
        state.url = webView.url
        state.title = webView.title
        state.canGoBack = webView.canGoBack
        state.canGoForward = webView.canGoForward
        state.isLoading = webView.isLoading
        state.estimatedProgress = webView.estimatedProgress
    }

    private func record(error: Error) {
        if Self.isHandledContentNavigation(error) {
            state.errorDescription = nil
            refreshState()
            return
        }
        state.errorDescription = error.localizedDescription
        state.isLoading = false
    }
}

extension BrowserSessionController: WKUIDelegate {
    public func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.targetFrame == nil else { return nil }
        handleNewWindowRequest(
            navigationAction.request,
            buttonNumber: navigationAction.buttonNumber
        )
        return nil
    }

    public func webViewDidClose(_ webView: WKWebView) {
        onCloseRequest?()
    }
}

extension BrowserSessionController: WKNavigationDelegate {
    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping @MainActor @Sendable (
            WKNavigationActionPolicy,
            WKWebpagePreferences
        ) -> Void
    ) {
        decideNavigationPolicy(
            for: navigationAction.request.url,
            preferences: preferences,
            decisionHandler: decisionHandler
        )
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        state.errorDescription = nil
        refreshState()
    }

    public func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        record(error: error)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        record(error: error)
    }
}
