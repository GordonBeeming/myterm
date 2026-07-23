import SwiftUI

/// A presentation-only bridge. Session creation and process lifetime remain with the caller.
@MainActor
public struct TerminalSessionView: NSViewRepresentable {
    private let session: any TerminalProcessSession
    private let isActive: Bool
    private let onFocused: (@MainActor () -> Void)?

    public init(
        session: any TerminalProcessSession,
        isActive: Bool = true,
        onFocused: (@MainActor () -> Void)? = nil
    ) {
        self.session = session
        self.isActive = isActive
        self.onFocused = onFocused
    }

    public func makeNSView(context: Context) -> NSView {
        session.setPaneActive(isActive)
        return TerminalSessionHostView(contentView: session.terminalView(), onFocused: onFocused)
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        session.setPaneActive(isActive)
        (nsView as? TerminalSessionHostView)?.onFocused = onFocused
    }
}

@MainActor
final class TerminalSessionHostView: NSView {
    private let contentView: NSView
    var onFocused: (@MainActor () -> Void)?
    private var firstResponderObservation: NSKeyValueObservation?
    private var wasFirstResponder = false

    init(contentView: NSView, onFocused: (@MainActor () -> Void)? = nil) {
        self.contentView = contentView
        self.onFocused = onFocused
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        contentView.autoresizingMask = []
        addSubview(contentView)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        contentView.frame = NSRect(
            origin: .zero,
            size: NSSize(width: max(1, bounds.width), height: max(1, bounds.height))
        )
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        firstResponderObservation = window?.observe(\.firstResponder, options: [.initial, .new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.reportFirstResponderIfNeeded()
            }
        }
    }

    private func reportFirstResponderIfNeeded() {
        let isFirstResponder = window?.firstResponder === contentView
        defer { wasFirstResponder = isFirstResponder }
        guard isFirstResponder, !wasFirstResponder else { return }
        onFocused?()
    }
}
