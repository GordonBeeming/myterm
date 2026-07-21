import SwiftUI

/// A presentation-only bridge. Session creation and process lifetime remain with the caller.
@MainActor
public struct TerminalSessionView: NSViewRepresentable {
    private let session: any TerminalProcessSession
    private let isActive: Bool

    public init(session: any TerminalProcessSession, isActive: Bool = true) {
        self.session = session
        self.isActive = isActive
    }

    public func makeNSView(context: Context) -> NSView {
        session.setPaneActive(isActive)
        return TerminalSessionHostView(contentView: session.terminalView())
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        session.setPaneActive(isActive)
    }
}

@MainActor
private final class TerminalSessionHostView: NSView {
    private let contentView: NSView

    init(contentView: NSView) {
        self.contentView = contentView
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
}
