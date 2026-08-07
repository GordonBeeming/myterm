import SwiftUI

/// SwiftUI recreation is deliberately inert: the caller owns the controller and its WKWebView.
@MainActor
public struct BrowserSessionView: NSViewRepresentable {
    private let session: BrowserSessionController
    private let isActive: Bool
    private let onFocused: (@MainActor () -> Void)?

    public init(
        session: BrowserSessionController,
        isActive: Bool = true,
        onFocused: (@MainActor () -> Void)? = nil
    ) {
        self.session = session
        self.isActive = isActive
        self.onFocused = onFocused
    }

    public func makeNSView(context: Context) -> NSView {
        BrowserSessionHostView(
            contentView: session.webView,
            isActive: isActive,
            onFocused: onFocused
        )
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? BrowserSessionHostView)?.update(
            contentView: session.webView,
            isActive: isActive,
            onFocused: onFocused
        )
    }
}

@MainActor
final class BrowserSessionHostView: NSView {
    private var contentView: NSView
    private var contentConstraints: [NSLayoutConstraint] = []
    private var shouldFocusWhenAttachedToWindow: Bool
    private var onFocused: (@MainActor () -> Void)?
    private var firstResponderObservation: NSKeyValueObservation?
    private var wasContentFirstResponder = false

    init(
        contentView: NSView,
        isActive: Bool,
        onFocused: (@MainActor () -> Void)? = nil
    ) {
        self.contentView = contentView
        shouldFocusWhenAttachedToWindow = isActive
        self.onFocused = onFocused
        super.init(frame: .zero)
        install(contentView)
    }

    func update(
        contentView updatedContentView: NSView,
        isActive: Bool,
        onFocused: (@MainActor () -> Void)? = nil
    ) {
        self.onFocused = onFocused
        setPaneActive(isActive)
        guard contentView !== updatedContentView else { return }

        let previousContentView = contentView
        let ownsPreviousContentView = previousContentView.superview === self
        let focusedView = window?.firstResponder as? NSView
        let shouldTransferFocus = ownsPreviousContentView && (
            focusedView === previousContentView
                || focusedView?.isDescendant(of: previousContentView) == true
        )
        if ownsPreviousContentView {
            previousContentView.removeFromSuperview()
        }

        contentView = updatedContentView
        wasContentFirstResponder = false
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
        firstResponderObservation = nil
        wasContentFirstResponder = false
        guard let window else { return }
        firstResponderObservation = window.observe(\.firstResponder, options: [.initial, .new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.reportFirstResponderIfNeeded()
            }
        }
        if shouldFocusWhenAttachedToWindow {
            focusWhenPossible()
        }
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

    private func reportFirstResponderIfNeeded() {
        let focusedView = window?.firstResponder as? NSView
        let isContentFirstResponder = focusedView === contentView
            || focusedView?.isDescendant(of: contentView) == true
        defer { wasContentFirstResponder = isContentFirstResponder }
        guard isContentFirstResponder, !wasContentFirstResponder else { return }
        onFocused?()
    }
}
