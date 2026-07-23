import SwiftUI

/// SwiftUI recreation is deliberately inert: the caller owns the controller and its WKWebView.
@MainActor
public struct BrowserSessionView: NSViewRepresentable {
    private let session: BrowserSessionController
    private let isActive: Bool

    public init(session: BrowserSessionController, isActive: Bool = true) {
        self.session = session
        self.isActive = isActive
    }

    public func makeNSView(context: Context) -> NSView {
        BrowserSessionHostView(contentView: session.webView, isActive: isActive)
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? BrowserSessionHostView)?.setPaneActive(isActive)
    }
}

@MainActor
final class BrowserSessionHostView: NSView {
    private let contentView: NSView
    private var shouldFocusWhenAttachedToWindow: Bool

    init(contentView: NSView, isActive: Bool) {
        self.contentView = contentView
        shouldFocusWhenAttachedToWindow = isActive
        super.init(frame: .zero)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, shouldFocusWhenAttachedToWindow else { return }
        focusWhenPossible()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    func setPaneActive(_ isActive: Bool) {
        // Before attachment this decides whether workspace restoration should focus the browser.
        // Once attached, toolbar controls own the responder chain and must not lose focus to WebKit.
        guard window == nil else { return }
        shouldFocusWhenAttachedToWindow = isActive
    }

    private func focusWhenPossible() {
        guard let window else {
            shouldFocusWhenAttachedToWindow = true
            return
        }
        shouldFocusWhenAttachedToWindow = false
        window.makeFirstResponder(contentView)
    }
}
