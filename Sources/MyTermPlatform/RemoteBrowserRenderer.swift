import AppKit
import Foundation
import ImageIO
import MyTermCore
@preconcurrency import WebKit

/// Only typed interactions cross the relay. Page code and every network request execute on the Mac.
@MainActor
public final class RemoteBrowserRenderer: NSObject, WKNavigationDelegate, WKUIDelegate {
    private let webView: WKWebView
    private let window: NSWindow
    private var closed = false
    private var failure: String?
    private var initialURL: URL
    private let artifactRoot: URL?

    public init(url: URL, profile: BrowserDataProfile? = nil, artifactRoot: URL? = nil) {
        initialURL = url
        self.artifactRoot = artifactRoot?.standardizedFileURL
        let configuration = WKWebViewConfiguration()
        if let profile {
            configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: profile.persistentStoreID)
        } else { configuration.websiteDataStore = .nonPersistent() }
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768), configuration: configuration)
        window = NSWindow(contentRect: webView.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    public var isClosed: Bool { closed }

    public func close() {
        closed = true
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        window.close()
    }

    public func interact(_ request: RemoteBrowserRequest) async throws -> RemoteBrowserFrame {
        guard !closed else { throw CancellationError() }
        webView.setFrameSize(NSSize(width: request.width, height: request.height))
        window.setContentSize(webView.frame.size)
        switch request.action {
        case .open:
            if let value = request.url, let url = URL(string: value) {
                if webView.url != (try mapArtifactURL(url)) { try navigate(url) }
            } else if webView.url == nil { try navigate(initialURL) }
        case .navigate:
            guard let value = request.url, let url = URL(string: value) else { throw URLError(.badURL) }
            try navigate(url)
        case .back: webView.goBack()
        case .forward: webView.goForward()
        case .reload: webView.reload()
        case .tap:
            guard let x = request.x, let y = request.y else { throw URLError(.badURL) }
            try tap(x: x, y: y, width: request.width, height: request.height)
        case .scroll:
            _ = try await webView.evaluateJavaScript("window.scrollBy(\(request.deltaX ?? 0),\(request.deltaY ?? 0));")
        case .text:
            guard let text = request.text else { throw URLError(.badURL) }
            guard let input = window.firstResponder as? NSTextInputClient else { throw URLError(.cannotLoadFromNetwork) }
            input.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        case .key:
            guard let key = request.key else { throw URLError(.badURL) }
            try sendKey(key)
        case .close:
            let metadata = frameMetadata()
            close()
            return try RemoteBrowserFrame(image: Data(), width: request.width, height: request.height,
                                      url: metadata.url, title: metadata.title,
                                      canGoBack: false, canGoForward: false, isLoading: false, error: metadata.error)
        case .snapshot: break
        }
        // Navigation starts asynchronously; give layout a turn while keeping the command bounded.
        try await Task.sleep(for: .milliseconds(150))
        let configuration = WKSnapshotConfiguration()
        configuration.rect = webView.bounds
        configuration.snapshotWidth = NSNumber(value: request.width)
        configuration.afterScreenUpdates = false
        let image = try await boundedSnapshot(configuration)
        guard !closed else { throw CancellationError() }
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw URLError(.cannotDecodeContentData)
        }
        let jpeg = try await Task.detached(priority: .userInitiated) {
            try Self.encodeJPEG(cgImage)
        }.value
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        let metadata = frameMetadata()
        return try RemoteBrowserFrame(image: jpeg, width: request.width, height: request.height,
                                  url: metadata.url, title: metadata.title, canGoBack: webView.canGoBack,
                                  canGoForward: webView.canGoForward, isLoading: webView.isLoading, error: metadata.error)
    }

    private func frameMetadata() -> RemoteBrowserFrameMetadata {
        RemoteBrowserFrameMetadata(url: webView.url?.absoluteString ?? initialURL.absoluteString,
                                   title: webView.title ?? "", error: failure)
    }

    private final class SnapshotCompletion {
        var continuation: CheckedContinuation<NSImage, Error>?
        var deadline: Task<Void, Never>?
        func finish(_ result: Result<NSImage, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            deadline?.cancel()
            deadline = nil
            continuation.resume(with: result)
        }
    }

    private func boundedSnapshot(_ configuration: WKSnapshotConfiguration) async throws -> NSImage {
        let completion = SnapshotCompletion()
        return try await withCheckedThrowingContinuation { continuation in
            completion.continuation = continuation
            completion.deadline = Task { [weak self, weak completion] in
                do { try await Task.sleep(for: .seconds(RemoteBrowserTiming.snapshotTimeoutSeconds)) }
                catch { return }
                self?.close()
                completion?.finish(.failure(URLError(.timedOut)))
            }
            webView.takeSnapshot(with: configuration) { image, error in
                if let error { completion.finish(.failure(error)) }
                else if let image { completion.finish(.success(image)) }
                else { completion.finish(.failure(URLError(.cannotDecodeContentData))) }
            }
        }
    }

    nonisolated private static func encodeJPEG(_ image: CGImage) throws -> Data {
        for quality in [0.7, 0.5, 0.3, 0.15, 0.05] {
            try Task.checkCancellation()
            let buffer = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(buffer, "public.jpeg" as CFString, 1, nil) else {
                throw URLError(.cannotDecodeContentData)
            }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw URLError(.cannotDecodeContentData) }
            if buffer.length <= RemoteBrowserFrame.maximumImageBytes { return buffer as Data }
        }
        throw URLError(.dataLengthExceedsMaximum)
    }

    private func tap(x: Double, y: Double, width: Int, height: Int) throws {
        let point = NSPoint(x: x * Double(width), y: webView.isFlipped ? y * Double(height) : (1 - y) * Double(height))
        guard let target = webView.hitTest(point) else { return }
        // This changes only the hidden window's responder. It never orders or activates a window.
        window.makeFirstResponder(target)
        let location = webView.convert(point, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else {
                throw URLError(.cannotLoadFromNetwork)
            }
            if type == .leftMouseDown { target.mouseDown(with: event) }
            else { target.mouseUp(with: event) }
        }
    }

    private func sendKey(_ key: RemoteBrowserKey) throws {
        let mapping: (UInt16, String)
        switch key {
        case .enter: mapping = (36, "\r")
        case .backspace: mapping = (51, "\u{7f}")
        case .tab: mapping = (48, "\t")
        case .escape: mapping = (53, "\u{1b}")
        case .arrowUp: mapping = (126, "\u{f700}")
        case .arrowDown: mapping = (125, "\u{f701}")
        case .arrowLeft: mapping = (123, "\u{f702}")
        case .arrowRight: mapping = (124, "\u{f703}")
        }
        guard let responder = window.firstResponder else { return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: mapping.1, charactersIgnoringModifiers: mapping.1,
                isARepeat: false, keyCode: mapping.0) else { throw URLError(.cannotLoadFromNetwork) }
            if type == .keyDown { responder.keyDown(with: event) }
            else { responder.keyUp(with: event) }
        }
    }

    private func navigate(_ requestedURL: URL) throws {
        let url = try mapArtifactURL(requestedURL)
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.user == nil, url.password == nil else { throw URLError(.unsupportedURL) }
        failure = nil
        webView.load(URLRequest(url: url))
    }

    private func mapArtifactURL(_ url: URL) throws -> URL {
        guard url.isFileURL else { return url }
        guard let artifactRoot else { throw URLError(.unsupportedURL) }
        let root = artifactRoot.path + "/"
        guard url.standardizedFileURL.path.hasPrefix(root),
              var components = URLComponents(url: initialURL, resolvingAgainstBaseURL: false) else {
            throw URLError(.noPermissionsToReadFile)
        }
        components.path = initialURL.deletingLastPathComponent().path + "/" + String(url.standardizedFileURL.path.dropFirst(root.count))
        components.query = url.query; components.fragment = url.fragment
        guard let mapped = components.url else { throw URLError(.badURL) }
        return mapped
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, url.isFileURL {
            if navigationAction.targetFrame?.isMainFrame == true {
                do { try navigate(url) } catch { failure = error.localizedDescription }
            }
            decisionHandler(.cancel)
            return
        }
        guard let url = navigationAction.request.url,
              ["http", "https", "about", "blob", "data"].contains(url.scheme?.lowercased() ?? "") else {
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }

    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            do { try navigate(url) } catch { failure = error.localizedDescription }
        }
        return nil
    }

    public func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                        initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                        decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }

    public func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
        completionHandler()
    }

    public func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        completionHandler(false)
    }

    public func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                        defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                        completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
        completionHandler(nil)
    }

    public func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                        initiatedByFrame frame: WKFrameInfo,
                        completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void) {
        completionHandler(nil)
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // WebKit reports main-frame navigation starts here, including history and page links.
        // Cancelled policy decisions never reach this callback, so their errors remain visible.
        failure = nil
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { failure = error.localizedDescription }
    }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { failure = error.localizedDescription }
    }
}

struct RemoteBrowserFrameMetadata {
    let url: String
    let title: String
    let error: String?

    init(url: String, title: String, error: String?) {
        // A shortened address could point somewhere different when used for mode switching.
        let addressFits = url.utf8.count <= 8192
        self.url = addressFits ? url : ""
        self.title = Self.boundedText(title, maximumBytes: 4096)
        self.error = error.map { Self.boundedText($0, maximumBytes: 2048) }
            ?? (addressFits ? nil : "This page's address is too long to show or reopen.")
    }

    private static func boundedText(_ value: String, maximumBytes: Int) -> String {
        var result = String.UnicodeScalarView()
        var remaining = maximumBytes
        for scalar in value.unicodeScalars {
            let count = scalar.utf8.count
            guard count <= remaining else { break }
            result.append(scalar)
            remaining -= count
        }
        return String(result)
    }
}
