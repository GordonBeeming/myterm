@preconcurrency import WebKit
import Foundation
import MyTermCore
import SwiftUI

public struct BrowserSessionState: Equatable, Sendable {
    public fileprivate(set) var url: URL?
    public fileprivate(set) var title: String?
    public fileprivate(set) var canGoBack: Bool
    public fileprivate(set) var canGoForward: Bool
    public fileprivate(set) var isLoading: Bool
    public fileprivate(set) var errorDescription: String?

    public init(
        url: URL? = nil,
        title: String? = nil,
        canGoBack: Bool = false,
        canGoForward: Bool = false,
        isLoading: Bool = false,
        errorDescription: String? = nil
    ) {
        self.url = url
        self.title = title
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.isLoading = isLoading
        self.errorDescription = errorDescription
    }
}

@MainActor
public final class BrowserSessionController: NSObject, ObservableObject {
    @Published public private(set) var state = BrowserSessionState()

    public let webView: WKWebView
    private var observations = [NSKeyValueObservation]()

    public convenience override init() {
        self.init(configuration: WKWebViewConfiguration())
    }

    public convenience init(profile: BrowserDataProfile) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: profile.persistentStoreID)
        self.init(configuration: configuration)
    }

    public init(configuration: WKWebViewConfiguration) {
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        webView.navigationDelegate = self
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
        ]
        refreshState()
    }

    deinit {
        observations.forEach { $0.invalidate() }
    }

    public func load(address: String) throws {
        try load(url: BrowserURLNormalizer.normalize(address))
    }

    public func load(url: URL) throws {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw BrowserURLNormalizationError.invalidAddress(url.absoluteString)
        }
        state.errorDescription = nil
        webView.load(URLRequest(url: url))
    }

    public func goBack() {
        guard webView.canGoBack else { return }
        webView.goBack()
    }

    public func goForward() {
        guard webView.canGoForward else { return }
        webView.goForward()
    }

    public func reload() {
        webView.reload()
    }

    private func refreshState() {
        state.url = webView.url
        state.title = webView.title
        state.canGoBack = webView.canGoBack
        state.canGoForward = webView.canGoForward
        state.isLoading = webView.isLoading
    }

    private func record(error: Error) {
        state.errorDescription = error.localizedDescription
        state.isLoading = false
    }
}

extension BrowserSessionController: WKNavigationDelegate {
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
