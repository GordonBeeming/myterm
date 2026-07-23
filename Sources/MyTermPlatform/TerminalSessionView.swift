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

    public func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    public func makeNSView(context: Context) -> NSView {
        context.coordinator.update(session: session, isActive: isActive)
        return TerminalSessionHostView(contentView: session.terminalView(), onFocused: onFocused)
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        let terminalView = session.terminalView()
        guard let host = nsView as? TerminalSessionHostView else {
            context.coordinator.update(session: session, isActive: isActive)
            return
        }

        let shouldDeactivatePreviousSession = context.coordinator.isSessionHosted(by: host)
        host.update(contentView: terminalView, onFocused: onFocused)
        context.coordinator.update(
            session: session,
            isActive: isActive,
            shouldDeactivatePreviousSession: shouldDeactivatePreviousSession
        )
    }

    public static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.deactivate()
    }

    @MainActor
    public final class Coordinator {
        private var session: any TerminalProcessSession

        fileprivate init(session: any TerminalProcessSession) {
            self.session = session
        }

        fileprivate func update(
            session updatedSession: any TerminalProcessSession,
            isActive: Bool,
            shouldDeactivatePreviousSession: Bool = true
        ) {
            if session !== updatedSession {
                if shouldDeactivatePreviousSession {
                    session.setPaneActive(false)
                }
                session = updatedSession
            }
            session.setPaneActive(isActive)
        }

        fileprivate func deactivate() {
            session.setPaneActive(false)
        }

        fileprivate func isSessionHosted(by host: TerminalSessionHostView) -> Bool {
            host.owns(session.terminalView())
        }
    }
}

@MainActor
final class TerminalSessionHostView: NSView {
    private var contentView: NSView
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

    func update(contentView updatedContentView: NSView, onFocused: (@MainActor () -> Void)?) {
        self.onFocused = onFocused
        guard contentView !== updatedContentView else { return }

        let previousContentView = contentView
        let ownsPreviousContentView = previousContentView.superview === self
        let shouldTransferFocus = ownsPreviousContentView
            && window?.firstResponder === previousContentView
        if ownsPreviousContentView {
            previousContentView.removeFromSuperview()
        }
        contentView = updatedContentView
        contentView.autoresizingMask = []
        addSubview(contentView)
        needsLayout = true

        if shouldTransferFocus {
            wasFirstResponder = false
            window?.makeFirstResponder(contentView)
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    func owns(_ view: NSView) -> Bool {
        contentView === view && view.superview === self
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
