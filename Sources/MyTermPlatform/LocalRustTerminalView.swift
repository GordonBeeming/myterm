#if DEBUG
import AppKit
import Foundation
import MyTermContinuity
import Observation
import SwiftTerm
import SwiftUI

@MainActor
public struct LocalRustTerminalView: View {
    public static let windowID = "local-rust-terminal"

    public static var bundledExecutable: URL? { LocalRustTerminalEndpoint.bundledExecutable }

    private let namespace: URL
    private let executable: URL
    @State private var session: LocalRustTerminalSession?

    public init(namespace: URL, executable: URL) {
        self.namespace = namespace
        self.executable = executable
    }

    public var body: some View {
        Group {
            if let session { terminalContent(session) }
            else { ProgressView() }
        }
        .task {
            if session == nil { session = LocalRustTerminalSession(namespace: namespace, executable: executable) }
        }
        .onDisappear { session?.detach() }
    }

    private func terminalContent(_ session: LocalRustTerminalSession) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text(session.status)
                        .accessibilityIdentifier("rustTerminalStatus")
                    if session.inputRejected {
                        HStack {
                            Text("Input could not be queued. Retry with less text after the shell catches up.")
                                .foregroundStyle(.secondary)
                            Button("Dismiss") { session.dismissInputWarning() }
                                .buttonStyle(.link)
                        }
                    }
                }
                Spacer()
                if let id = session.selectedID {
                    Button("Reattach to Saved Shell") { session.reattach(id) }
                        .disabled(session.isBusy || session.isAttached)
                }
                if let id = session.previousID {
                    Button("Reattach to Previous Shell") { session.reattach(id) }
                        .disabled(session.isBusy || session.isAttached)
                }
                Button(session.selectedID == nil ? "Start Shell" : "Start New Shell") { session.start() }
                    .disabled(!session.canStart)
            }
            .padding(12)
            Divider()
            RustTerminalSurface(terminal: session.terminal)
        }
    }
}

@MainActor
private struct RustTerminalSurface: NSViewRepresentable {
    let terminal: TerminalView

    func makeNSView(context: Context) -> TerminalView { terminal }
    func updateNSView(_ nsView: TerminalView, context: Context) {}
}

@MainActor
@Observable
private final class LocalRustTerminalSession: NSObject {
    private struct Selection: Codable {
        var saved: UUID?
        var pending: UUID?
    }

    private let endpoint: LocalRustTerminalEndpoint
    private let selectionURL: URL
    private var selection = Selection()
    private var canReplace = false
    private var selectionReadable = true
    private var connection: LocalRustTerminalConnection?
    private var work: Task<Void, Never>?
    let terminal = TerminalView(frame: .zero)

    private(set) var status = "Start a shell on the local Rust server."
    private(set) var isBusy = false
    private(set) var isAttached = false
    private(set) var inputRejected = false

    var selectedID: UUID? { selection.pending ?? selection.saved }
    var previousID: UUID? { selection.pending == nil ? nil : selection.saved }
    var canStart: Bool { selectionReadable && !isBusy && !isAttached && (selectedID == nil || canReplace) }

    init(namespace: URL, executable: URL) {
        endpoint = LocalRustTerminalEndpoint(namespace: namespace, bundledExecutable: executable)
        selectionURL = namespace.appendingPathComponent("rust-terminal-selection.json")
        super.init()
        terminal.terminalDelegate = self
        do {
            selection = try JSONDecoder().decode(Selection.self, from: Data(contentsOf: selectionURL))
            if selectedID != nil { status = "Reattach to your saved shell." }
        } catch CocoaError.fileReadNoSuchFile {
            // The first start records its session identity before sending the request.
        } catch {
            selectionReadable = false
            status = "Could not read the saved shell: \(error.localizedDescription)"
        }
    }

    func start() {
        guard canStart else { return }
        connect(id: UUID(), starting: true)
    }

    func reattach(_ id: UUID) {
        guard !isBusy, !isAttached else { return }
        connect(id: id, starting: false)
    }

    func dismissInputWarning() { inputRejected = false }

    func detach() {
        work?.cancel()
        work = nil
        connection?.disconnect()
        connection = nil
        isBusy = false
        isAttached = false
        canReplace = false
        inputRejected = false
        if selectionReadable {
            status = selectedID == nil ? "Start a shell on the local Rust server." : "Reattach to your saved shell."
        }
    }

    private func connect(id: UUID, starting: Bool) {
        let endpoint = endpoint
        isBusy = true
        status = starting ? "Starting the local shell…" : "Reattaching to the saved shell…"
        work = Task { [weak self] in
            var ready = false
            var selectionBeforeStart: Selection?
            do {
                let connection = try await endpoint.connect(starting: starting)
                try Task.checkCancellation()
                guard let self else { return }
                if starting {
                    selectionBeforeStart = self.selection
                    try self.record(Selection(saved: self.selection.saved, pending: id))
                }
                self.connection = connection
                try connection.begin(id: id, starting: starting)
                try await self.consume(connection, id: id, didAttach: { ready = true })
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.connection?.disconnect()
                self.connection = nil
                self.isBusy = false
                self.isAttached = false
                self.inputRejected = false
                switch error {
                case LocalRustTerminalError.missingServer, LocalRustTerminalError.server:
                    self.canReplace = true
                default:
                    self.canReplace = false
                }
                self.status = error.localizedDescription
                if !ready, case LocalRustTerminalError.server = error, let selectionBeforeStart {
                    do {
                        try self.record(selectionBeforeStart)
                    } catch {
                        self.status += " The saved shell selection could not be restored: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    private func consume(_ connection: LocalRustTerminalConnection, id: UUID, didAttach: () -> Void) async throws {
        var expectingReady = true
        while true {
            let event = try await connection.nextEvent(expectingReady: expectingReady)
            try Task.checkCancellation()
            switch event {
            case let .ready(serverPID, shellPID):
                expectingReady = false
                didAttach()
                terminal.getTerminal().resetToInitialState()
                let grid = terminal.getTerminal()
                connection.resize(columns: grid.cols, rows: grid.rows)
                status = "Server PID \(serverPID) · Shell PID \(shellPID)"
                do {
                    try record(Selection(saved: id))
                } catch {
                    status += " · Could not update the saved shell: \(error.localizedDescription)"
                }
                isBusy = false
                isAttached = true
                terminal.window?.makeFirstResponder(terminal)
            case let .output(payload):
                terminal.feed(byteArray: Array(payload)[...])
            }
        }
    }

    private func record(_ updated: Selection) throws {
        try SessionHostSocket.prepareDirectory(endpoint.namespace)
        try JSONEncoder().encode(updated).write(to: selectionURL, options: .atomic)
        selection = updated
    }
}

extension LocalRustTerminalSession: @preconcurrency TerminalViewDelegate {
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        if isAttached { connection?.resize(columns: newCols, rows: newRows) }
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if isAttached, let connection, !connection.sendInput(data) { inputRejected = true }
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func bell(source: TerminalView) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
#endif
