import SwiftUI

/// SwiftUI recreation is deliberately inert: the caller owns the controller and its WKWebView.
@MainActor
public struct BrowserSessionView: NSViewRepresentable {
    private let session: BrowserSessionController

    public init(session: BrowserSessionController) {
        self.session = session
    }

    public func makeNSView(context: Context) -> NSView {
        session.webView
    }

    public func updateNSView(_ nsView: NSView, context: Context) {}
}
