import SwiftUI

/// A presentation-only bridge. Session creation and process lifetime remain with the caller.
@MainActor
public struct TerminalSessionView: NSViewRepresentable {
    private let session: any TerminalProcessSession

    public init(session: any TerminalProcessSession) {
        self.session = session
    }

    public func makeNSView(context: Context) -> NSView {
        session.terminalView()
    }

    public func updateNSView(_ nsView: NSView, context: Context) {}
}
