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
        (nsView as? BrowserSessionHostView)?.update(contentView: session.webView, isActive: isActive)
    }
}

@MainActor
final class BrowserSessionHostView: NSView {
    private var contentView: NSView
    private var contentConstraints: [NSLayoutConstraint] = []
    private var shouldFocusWhenAttachedToWindow: Bool

    init(contentView: NSView, isActive: Bool) {
        self.contentView = contentView
        shouldFocusWhenAttachedToWindow = isActive
        super.init(frame: .zero)
        install(contentView)
    }

    func update(contentView updatedContentView: NSView, isActive: Bool) {
        setPaneActive(isActive)
        guard contentView !== updatedContentView else { return }

        let previousContentView = contentView
        let ownsPreviousContentView = previousContentView.superview === self
        let shouldTransferFocus = ownsPreviousContentView
            && window?.firstResponder === previousContentView
        if ownsPreviousContentView {
            previousContentView.removeFromSuperview()
        }

        contentView = updatedContentView
        install(updatedContentView)

        if shouldTransferFocus {
            shouldFocusWhenAttachedToWindow = false
            window?.makeFirstResponder(updatedContentView)
        }
    }

    func owns(_ view: NSView) -> Bool {
        contentView === view && view.superview === self
    }

    private func install(_ contentView: NSView) {
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)
        contentConstraints = [
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]
        NSLayoutConstraint.activate(contentConstraints)
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

    override func willRemoveSubview(_ subview: NSView) {
        super.willRemoveSubview(subview)
        guard subview === contentView else { return }
        NSLayoutConstraint.deactivate(contentConstraints)
        contentConstraints = []
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
