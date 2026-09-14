import MyTermRemoteProtocol
import SwiftTerm
import SwiftUI

/// Pushed for a TERMINAL tab. Attaches for as long as this screen is on screen and detaches the
/// instant it is not, so the host only streams bytes to sessions a device is actually showing.
struct TerminalScreen: View {
    let tab: RemoteTab
    let store: RemoteSessionStore

    /// Bumped by the keyboard button. The terminal view acts on each change.
    @State private var keyboardRequest = 0

    var body: some View {
        TerminalHostView(
            store: store,
            tabID: tab.id,
            generation: store.client.connectionGeneration,
            isConnected: store.client.hostName != nil,
            keyboardRequest: keyboardRequest
        )
        .background(Color.black)
        .overlay {
            if let reason = store.attachRefusal {
                ContentUnavailableView(
                    "Can’t Open This Tab",
                    systemImage: "terminal",
                    description: Text(reason.prefix(1).uppercased() + reason.dropFirst() + ".")
                )
                .background(Color.black)
                .foregroundStyle(.white)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Only while connected: a dropped connection is the banner's story, not this one's.
            if store.client.hostName != nil, !store.client.allowsMutation {
                // Told here, at the point of typing, rather than only in the tree. A blank terminal
                // that ignores every key would otherwise look broken.
                Label("View only. Typing is turned off on the Mac.", systemImage: "eye")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(.black)
                    .accessibilityIdentifier("terminal.viewOnly")
            }
        }
        .navigationTitle(tab.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(Color.black, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            if store.client.allowsMutation {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Keyboard", systemImage: "keyboard") { keyboardRequest += 1 }
                        .accessibilityIdentifier("terminal.keyboard")
                }
            }
        }
    }
}

/// Bridges SwiftTerm's UIKit `TerminalView` into SwiftUI and wires it to one attached session.
///
/// This never spawns a process. Bytes only ever arrive from `RemoteClient`, and typed input only
/// ever leaves through `RemoteClient.sendInput(_:to:)` — the device is a screen onto the host's
/// session, not a terminal in its own right.
private struct TerminalHostView: UIViewRepresentable {
    let store: RemoteSessionStore
    let tabID: String
    /// Changes when the device reconnects. The attachment died with the old socket, so the screen
    /// attaches again rather than staying frozen on the last byte the old one delivered.
    let generation: Int
    let isConnected: Bool
    let keyboardRequest: Int

    func makeUIView(context: Context) -> FittingTerminalView {
        let terminalView = FittingTerminalView(frame: .zero)
        terminalView.terminalDelegate = context.coordinator
        terminalView.accessibilityIdentifier = "terminal"
        context.coordinator.terminalView = terminalView
        context.coordinator.attachIfNeeded(tabID: tabID, generation: generation, isConnected: isConnected)
        return terminalView
    }

    func updateUIView(_ uiView: FittingTerminalView, context: Context) {
        context.coordinator.attachIfNeeded(tabID: tabID, generation: generation, isConnected: isConnected)
        context.coordinator.handleKeyboardRequest(keyboardRequest)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store)
    }

    static func dismantleUIView(_ uiView: FittingTerminalView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator {
        private let store: RemoteSessionStore
        weak var terminalView: FittingTerminalView?
        private var session: UUID?
        private var attachedGeneration: Int?
        private var handledKeyboardRequest = 0

        init(store: RemoteSessionStore) {
            self.store = store
        }

        func attachIfNeeded(tabID: String, generation: Int, isConnected: Bool) {
            guard isConnected, attachedGeneration != generation else { return }
            attachedGeneration = generation
            session = nil
            store.claimAttachment(
                owner: self,
                onAttach: { [weak self] attached in
                    guard let self else { return }
                    session = attached.session
                    // The view's own resize and feed wrap the emulator call in the bookkeeping that
                    // repaints. Reaching past them to `getTerminal()` updates the grid and draws nothing.
                    terminalView?.resize(cols: attached.columns, rows: attached.rows)
                    terminalView?.hostGrid = (attached.columns, attached.rows)
                },
                onOutput: { [weak self] bytes, session in
                    guard let self, self.session == session else { return }
                    terminalView?.feed(byteArray: bytes[...])
                },
                onResync: { [weak self] session in
                    guard let self, self.session == session else { return }
                    // The host's own next snapshot already begins with a reset; clearing local state
                    // here just keeps this screen from showing stale content in the gap before it lands.
                    terminalView?.feed(byteArray: Array("\u{1B}c".utf8)[...])
                }
            )
            store.client.attach(tabID: tabID)
        }

        func handleKeyboardRequest(_ request: Int) {
            guard request != handledKeyboardRequest, let terminalView else { return }
            handledKeyboardRequest = request
            if terminalView.isFirstResponder {
                terminalView.resignFirstResponder()
            } else {
                terminalView.becomeFirstResponder()
            }
        }

        func detach() {
            store.releaseAttachment(owner: self)
            if let session {
                store.client.detach(session: session)
            }
        }
    }
}

extension TerminalHostView.Coordinator: @preconcurrency TerminalViewDelegate {
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard let session else { return }
        store.client.sendInput(Array(data), to: session)
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// A terminal that shrinks its font until the Mac's grid fits the space it has.
///
/// One process has one window size, and the device is a mirror rather than a second window, so the
/// grid stays at whatever the Mac's pane uses. Without this the extra columns simply run off the
/// side and the view scrolls sideways, and the bottom rows, where the prompt lives, fall below the
/// keyboard. Scaling the type is the only lever the device holds.
final class FittingTerminalView: TerminalView {
    /// The Mac pane's grid. Zero until the host answers the attach.
    var hostGrid: (columns: Int, rows: Int) = (0, 0) {
        didSet { fitFontToBounds() }
    }

    /// Setting `font` lays the view out again, so the applied size is remembered to stop that
    /// becoming a loop.
    private var appliedFontSize: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        fitFontToBounds()
    }

    private func fitFontToBounds() {
        guard hostGrid.columns > 0, bounds.width > 0, bounds.height > 0 else { return }
        let size = Self.fittingFontSize(grid: hostGrid, in: bounds.size)
        guard abs(size - appliedFontSize) > 0.5 else { return }
        appliedFontSize = size
        font = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Advance width and line height both scale with point size for a fixed-pitch face, so one
    /// measurement at a reference size gives the size that fits without searching for it. The
    /// tighter of the two dimensions wins.
    ///
    /// The floor keeps text legible even when the Mac's pane is far larger than the device: below it
    /// the view clips again, which is better than type nobody can read.
    static func fittingFontSize(grid: (columns: Int, rows: Int), in size: CGSize) -> CGFloat {
        let reference: CGFloat = 12
        let probe = UIFont.monospacedSystemFont(ofSize: reference, weight: .regular)
        let advance = ("M" as NSString).size(withAttributes: [.font: probe]).width
        guard advance > 0, grid.columns > 0 else { return reference }

        var ideal = (size.width / CGFloat(grid.columns)) * reference / advance
        if grid.rows > 0 {
            let lineHeight = ceil(probe.ascender - probe.descender + probe.leading)
            ideal = min(ideal, (size.height / CGFloat(grid.rows)) * reference / lineHeight)
        }
        return min(max(ideal.rounded(.down), 6), 18)
    }
}
