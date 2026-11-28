#if DEBUG || MYTERM_RUST_WORKSPACES
import Foundation
import MyTermContinuity
import Observation

/// A workspace’s saved shell belongs to its local server. Launch and recovery use that same authority.
@MainActor
public final class LocalRustWorkspaceTerminalEngine: TerminalEngine {
    public static var bundledExecutable: URL? { LocalRustTerminalEndpoint.bundledExecutable }
    private let backend: LocalRustWorkspaceBackend

    public init(namespace: URL, executable: URL?) {
        let connect: LocalRustWorkspaceBackend.Connect = { starting in
            guard let executable else {
                throw LocalRustTerminalError.launch("The Rust terminal server is missing from this app bundle.")
            }
            return try await LocalRustTerminalEndpoint(namespace: namespace, bundledExecutable: executable).connect(starting: starting)
        }
        backend = LocalRustWorkspaceBackend(namespace: namespace, connect: connect)
    }

    init(namespace: URL, connect: @escaping LocalRustWorkspaceBackend.Connect) {
        backend = LocalRustWorkspaceBackend(namespace: namespace, connect: connect)
    }

    public func makeSession(configuration: TerminalSessionConfiguration) throws -> any TerminalProcessSession {
        guard let paneID = configuration.continuityIdentifier else {
            throw TerminalSessionFailure(message: "A local Rust terminal must belong to a saved workspace pane.")
        }
        let session = try SwiftTermTerminalSession(configuration: configuration)
        session.useRustWorkspaceBackend(backend, paneID: paneID)
        return session
    }

    public func hasSavedSelection(paneID: UUID) throws -> Bool {
        try backend.selection(paneID: paneID) != nil
    }

    public func stopExisting(paneID: UUID) async throws {
        try await backend.stopExisting(paneID: paneID)
    }
}

@MainActor
@Observable
public final class LocalRustWorkspaceRecovery {
    public enum Action: Equatable {
        case reattach, startNewShell, retryStartup, takeControl
    }

    public internal(set) var action: Action?
}

@MainActor
final class LocalRustWorkspaceBackend {
    typealias Connect = @Sendable (_ starting: Bool) async throws -> LocalRustTerminalConnection

    struct Selection: Codable, Equatable, Sendable {
        let sessionID: UUID
        let clientID: UUID
    }

    static var usesCheckpointProtocol: Bool {
        #if MYTERM_WEZTERM_CHECKPOINT
        true
        #else
        false
        #endif
    }

    let connect: Connect
    private let namespace: URL

    init(namespace: URL, connect: @escaping Connect) {
        self.namespace = namespace
        self.connect = connect
    }

    func selection(paneID: UUID) throws -> Selection? {
        do {
            return try JSONDecoder().decode(Selection.self, from: Data(contentsOf: selectionURL(paneID: paneID)))
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
    }

    /// Record the attempt before contacting the service. If the app quits before the reply,
    /// it can use the same identity to check for the existing shell after restart.
    func recordLaunch(paneID: UUID, replacing previous: Selection?) throws -> Selection {
        let selection = Selection(sessionID: UUID(), clientID: previous?.clientID ?? UUID())
        try SessionHostSocket.prepareDirectory(namespace)
        try JSONEncoder().encode(selection).write(to: selectionURL(paneID: paneID), options: .atomic)
        return selection
    }

    func stopExisting(paneID: UUID, observed: LocalRustTerminalConnection.Controller? = nil) async throws {
        guard let selection = try selection(paneID: paneID) else { return }
        do {
            do {
                try await stop(selection, observed: observed)
            } catch LocalRustTerminalError.controlChanged where observed != nil {
                try await stop(selection, observed: nil)
            }
        } catch LocalRustTerminalError.missingServer {
            // A stopped daemon cannot retain an in-memory session.
        } catch LocalRustTerminalError.missingSession {
            // The live daemon has no session with this identity.
        }
        guard try self.selection(paneID: paneID) == selection else { return }
        try FileManager.default.removeItem(at: selectionURL(paneID: paneID))
    }

    private func stop(_ selection: Selection, observed: LocalRustTerminalConnection.Controller?) async throws {
        let controller: LocalRustTerminalConnection.Controller
        let metadataConnection: LocalRustTerminalConnection?
        if let observed {
            controller = observed
            metadataConnection = nil
        } else {
            let connection = try await connect(false)
            metadataConnection = connection
            if Self.usesCheckpointProtocol {
                controller = try await connection.workspaceControl(sessionID: selection.sessionID, clientID: selection.clientID)
            } else {
                try connection.beginWorkspace(sessionID: selection.sessionID, clientID: selection.clientID, launch: nil)
                controller = try await connection.workspaceAttachment().control
            }
        }
        defer { metadataConnection?.disconnect() }
        guard controller.owner == selection.clientID else {
            throw TerminalSessionFailure(message: "The terminal is controlled by another client.")
        }
        let stopConnection = try await connect(false)
        defer { stopConnection.disconnect() }
        try await stopConnection.stopExistingWorkspace(sessionID: selection.sessionID, clientID: selection.clientID,
                                                        observed: controller)
    }

    private func selectionURL(paneID: UUID) -> URL {
        namespace.appendingPathComponent(paneID.uuidString + ".json")
    }
}
#endif
