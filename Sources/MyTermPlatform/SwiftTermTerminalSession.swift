import AppKit
import Darwin
import Foundation
import MyTermCore
import MyTermContinuity
import OSLog
@preconcurrency import SwiftTerm
import UniformTypeIdentifiers

@MainActor
public final class SwiftTermTerminalEngine: TerminalEngine {
    public init() {}

    public func makeSession(configuration: TerminalSessionConfiguration) throws -> any TerminalProcessSession {
        try SwiftTermTerminalSession(configuration: configuration)
    }
}

@MainActor
public final class SwiftTermTerminalSession: NSObject, TerminalProcessSession, TerminalRemoteSession {
    public private(set) var isRunning = false
    public var isStarting: Bool { persistentStartTask != nil }
    public var survivesApplicationTermination: Bool {
        #if DEBUG || MYTERM_RUST_WORKSPACES
        if rustWorkspace != nil { return rustConnection != nil && isRunning }
        #endif
        return persistentConnection != nil && isRunning
    }
    public var onEvent: (@MainActor (TerminalSessionEvent) -> Void)?

    public var activeForegroundProcessName: String? {
        #if DEBUG || MYTERM_RUST_WORKSPACES
        if rustWorkspace != nil {
            guard isRunning, let shellPID = rustShellPID else { return nil }
            var info = proc_bsdinfo()
            let expected = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(shellPID, PROC_PIDTBSDINFO, 0, &info, expected) == expected,
                  let foreground = pid_t(exactly: info.e_tpgid), foreground > 0,
                  foreground != getpgid(shellPID) else { return nil }
            return Self.processGroupName(foreground)
        }
        #endif
        if persistentConnection != nil {
            // The app no longer owns the PTY. The foreground process group is reported by
            // the host rather than guessed from the helper's or shell's process name.
            return persistentForegroundProcessName
        }
        guard isRunning,
              terminal.process.childfd >= 0,
              terminal.process.shellPid > 0 else { return nil }
        let foregroundProcessGroup = tcgetpgrp(terminal.process.childfd)
        let shellProcessGroup = getpgid(terminal.process.shellPid)
        guard foregroundProcessGroup > 0,
              shellProcessGroup > 0,
              foregroundProcessGroup != shellProcessGroup else { return nil }

        return Self.processGroupName(foregroundProcessGroup)
    }

    private static func processGroupName(_ foregroundProcessGroup: pid_t) -> String {
        var name = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = name.withUnsafeMutableBytes { buffer in
            proc_name(foregroundProcessGroup, buffer.baseAddress, UInt32(buffer.count))
        }
        guard length > 0 else { return "Unknown foreground process" }
        return String(
            decoding: name.prefix(Int(length)).map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    }

    public var foregroundClaudeConfiguration: ClaudeConfiguration? {
        guard isRunning else { return nil }
        let shell = attachedShellPID ?? terminal.process.shellPid
        return ClaudeProcessConfiguration.configuration(belowShell: shell)
    }

    public var foregroundClaudeConversation: AgentSessionHandle? {
        guard isRunning, activeForegroundProcessName != nil else { return nil }
        return ClaudeProcessConfiguration.conversation(belowShell: attachedShellPID ?? terminal.process.shellPid)
    }

    private let configuration: TerminalSessionConfiguration
    private var runtimeConfiguration: TerminalRuntimeConfiguration
    private let terminal: MyTermLocalProcessTerminalView
    private var persistentConnection: PersistentTerminalConnection?
    #if DEBUG || MYTERM_RUST_WORKSPACES
    private var rustWorkspace: (backend: LocalRustWorkspaceBackend, paneID: UUID)?
    private enum RustStartup { case restore, reattach, replace }
    private var rustStartupRetry: RustStartup?
    public private(set) var rustRecovery: LocalRustWorkspaceRecovery?
    private var rustConnection: LocalRustTerminalConnection?
    private var rustShellPID: pid_t?
    private var rustController: LocalRustTerminalConnection.Controller?
    private var rustClientID: UUID?
    private var rustReadTask: Task<Void, Never>?
    private var rustCheckpointAttached = false
    private struct RustGeometry: Equatable {
        let columns: Int
        let rows: Int
        let cellPixels: LocalRustTerminalConnection.CellPixels?
    }
    private var rustRequestedGeometry: RustGeometry?
    private var rustMaySendInput: Bool {
        rustController?.ownerConnected == true && rustController?.owner == rustClientID
    }
    #endif
    private var attachedShellPID: pid_t? {
        #if DEBUG || MYTERM_RUST_WORKSPACES
        if let rustShellPID { return rustShellPID }
        #endif
        return persistentConnection?.attachment.pid
    }
    private var hostSequence: UInt64 = 0
    private struct RequestedHostGeometry: Equatable { let columns: Int; let rows: Int }
    private var requestedHostGeometry: RequestedHostGeometry?
    private var requestedImageGeometry: SessionHostImageGeometry?
    private var persistentStartTask: Task<Void, Never>?
    private enum PendingStartDisposition { case attach, stop, detach }
    private var pendingStartDisposition = PendingStartDisposition.attach
    private var persistentForegroundProcessName: String?
    private var remoteControllerActive = false
    private var reportedGeometryLimit = false
    private var workingDirectoryPoller: ProcessWorkingDirectoryPoller?
    private var lastReportedWorkingDirectory: URL?
    private var foregroundProcessTimer: Timer?
    private var lastReportedForegroundProcessName: String?
    private var didTerminate = false
    private var startupToken: String?
    private var startupReadinessTimer: Timer?
    /// How long a new shell has to signal readiness before the pane says it is still waiting.
    /// The saved command is still sent when the shell does become ready.
    var startupReadinessGracePeriod: TimeInterval = 10
    private var startupCommandOverdue = false
    private var contentChangeHandler: (@MainActor () -> Void)?
    public private(set) var remoteGeneration = UUID()
    public private(set) var remoteSequence: UInt64 = 0
    private var remoteOutputHandler: (@MainActor (TerminalRemoteOutput) -> Void)?
    private var remoteGeometryHandler: (@MainActor (TerminalRemoteGeometry) -> Void)?
    public private(set) var remoteGeometry: TerminalRemoteGeometry
    private var remoteReplayBuffer: [TerminalRemoteOutput] = []
    private var remoteReplayHead = 0
    private var remoteReplayBytes = 0
    private var remoteCaptureEnabled = false
    private var remoteTakeControlHandler: (@MainActor () -> Void)?
    private static let maximumRemoteReplayBytes = 4 * 1_024 * 1_024
    private static let maximumRemoteReplayFrames = 4_096
    private static let maximumRemoteInputBytes = 1_024 * 1_024

    public init(configuration: TerminalSessionConfiguration) throws {
        guard configuration.shell.isFileURL,
              FileManager.default.isExecutableFile(atPath: configuration.shell.path)
        else {
            throw TerminalSessionFailure(message: "The configured login shell is not executable: \(configuration.shell.path)")
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: configuration.workingDirectory.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue
        else {
            throw TerminalSessionFailure(message: "The requested working directory does not exist: \(configuration.workingDirectory.path)")
        }

        self.configuration = configuration
        runtimeConfiguration = configuration.runtimeConfiguration
        lastReportedWorkingDirectory = configuration.workingDirectory
        terminal = MyTermLocalProcessTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 480)
        )
        remoteGeometry = TerminalRemoteGeometry(
            generation: remoteGeneration,
            columns: terminal.getTerminal().cols,
            rows: terminal.getTerminal().rows
        )
        super.init()

        terminal.currentWorkingDirectory = configuration.workingDirectory
        terminal.processDelegate = self
        terminal.onOpenWebURL = { [weak self] url in
            Task { @MainActor [weak self] in
                self?.onEvent?(.openURL(url))
            }
        }
        terminal.onContentChanged = { [weak self] in
            self?.contentChangeHandler?()
        }
        terminal.onAgentActivity = { [weak self] report in
            Task { @MainActor [weak self] in
                guard let self else { return }
                #if DEBUG || MYTERM_RUST_WORKSPACES
                if self.rustWorkspace != nil, !self.isRunning { return }
                #endif
                self.onEvent?(.agentActivity(report))
            }
        }
        terminal.onShellReady = { [weak self] token in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning, self.startupToken == token else { return }
                self.startupReadinessTimer?.invalidate()
                self.startupReadinessTimer = nil
                self.startupToken = nil
                self.sendInitialCommand()
                if self.startupCommandOverdue {
                    self.startupCommandOverdue = false
                    self.onEvent?(.initialCommandSentAfterDelay)
                }
            }
        }
        terminal.autoresizingMask = [.width, .height]
        terminal.apply(runtimeConfiguration: configuration.runtimeConfiguration)
        if let restoredOutput = configuration.restoredOutput {
            terminal.presentPersistedOutput(restoredOutput)
        }
    }

    public func terminalView() -> NSView {
        terminal
    }

    public func start() throws {
        guard !isRunning, persistentStartTask == nil else { return }
        #if DEBUG || MYTERM_RUST_WORKSPACES
        if rustWorkspace != nil {
            try retireLegacyWorkspaceHost(then: .restore)
            return
        }
        #endif
        try startNewProcess(runInitialCommand: true)
    }

    private func startNewProcess(runInitialCommand: Bool,
                                 replacingLostRustSession: (sessionID: UUID, clientID: UUID)? = nil) throws {
        guard !isRunning, persistentStartTask == nil else { return }
        pendingStartDisposition = .attach

        didTerminate = false
        remoteGeneration = UUID()
        remoteGeometry = TerminalRemoteGeometry(
            generation: remoteGeneration,
            columns: terminal.getTerminal().cols,
            rows: terminal.getTerminal().rows
        )
        remoteSequence = 0
        remoteReplayBuffer.removeAll(keepingCapacity: true)
        remoteReplayHead = 0
        remoteReplayBytes = 0
        var environment = configuration.environment
        environment["MYTERM_PERSISTENT_SCROLLBACK_LINES"] = String(min(runtimeConfiguration.scrollbackLines, 100_000))
        startupReadinessTimer?.invalidate()
        startupReadinessTimer = nil
        startupToken = nil
        startupCommandOverdue = false
        var arguments = configuration.shellArguments
        var startupFailure: TerminalSessionFailure?
        if runInitialCommand, configuration.initialCommand?.isEmpty == false {
            startupToken = UUID().uuidString
            environment["MYTERM_STARTUP_TOKEN"] = startupToken
            environment["MYTERM_STARTUP_PARENT_PID"] = String(getpid())
            do {
                switch configuration.shell.lastPathComponent {
                case "zsh":
                    guard let zdotdir = environment["ZDOTDIR"],
                          let readiness = try? String(contentsOfFile: "\(zdotdir)/_myterm_startup", encoding: .utf8),
                          readiness.hasPrefix("# MyTerm shell readiness v1\n") else {
                        throw TerminalSessionFailure(message: "The zsh startup integration is unavailable. The saved command was not sent.")
                    }
                case "bash":
                    guard let resources = environment["MYTERM_RESOURCE_DIR"],
                          FileManager.default.isReadableFile(atPath: "\(resources)/myterm-bash-startup") else {
                        throw TerminalSessionFailure(message: "The bash startup integration is unavailable. The saved command was not sent.")
                    }
                    let home = environment["HOME"] ?? ProcessInfo.processInfo.environment["HOME"]
                        ?? FileManager.default.homeDirectoryForCurrentUser.path
                    _ = try BashStartupIntegration.install(in: URL(fileURLWithPath: home, isDirectory: true))
                case "fish":
                    guard let resources = environment["MYTERM_RESOURCE_DIR"],
                          FileManager.default.isReadableFile(atPath: "\(resources)/myterm-fish-startup.fish") else {
                        throw TerminalSessionFailure(message: "The fish startup integration is unavailable. The saved command was not sent.")
                    }
                    let path = "\(resources)/myterm-fish-startup.fish".replacingOccurrences(of: "'", with: "'\\''")
                    arguments += ["--init-command", "source '\(path)'"]
                default:
                    throw TerminalSessionFailure(message: "Automatic startup commands require zsh, bash or fish. Run the saved command manually in this custom shell.")
                }
            } catch {
                startupFailure = TerminalSessionFailure(message: error.localizedDescription)
                startupToken = nil
                environment.removeValue(forKey: "MYTERM_STARTUP_TOKEN")
                environment.removeValue(forKey: "MYTERM_STARTUP_PARENT_PID")
            }
        }
        #if DEBUG || MYTERM_RUST_WORKSPACES
        if let rustWorkspace {
            let previous: LocalRustWorkspaceBackend.Selection?
            if let replacingLostRustSession {
                previous = .init(sessionID: replacingLostRustSession.sessionID, clientID: replacingLostRustSession.clientID)
            } else {
                previous = try rustWorkspace.backend.selection(paneID: rustWorkspace.paneID)
            }
            let selection = try rustWorkspace.backend.recordLaunch(paneID: rustWorkspace.paneID, replacing: previous)
            let launchEnvironment = Self.processEnvironmentValues(overrides: environment)
            let size = SessionHostGeometry.fit(columns: terminal.getTerminal().cols, rows: terminal.getTerminal().rows)
            let useCheckpoint = LocalRustWorkspaceBackend.usesCheckpointProtocol
            let cellPixels = useCheckpoint ? rustCellPixels : nil
            let launch = LocalRustTerminalConnection.WorkspaceLaunch(
                shell: configuration.shell.path, arguments: arguments,
                cwd: configuration.workingDirectory.path, environment: launchEnvironment,
                columns: size.columns, rows: size.rows, cellWidth: cellPixels?.width, cellHeight: cellPixels?.height,
                scrollback: useCheckpoint ? min(runtimeConfiguration.scrollbackLines, 100_000) : nil)
            startRustAttachment(selection: selection, launch: launch, startupFailure: startupFailure,
                                runInitialCommand: runInitialCommand)
            return
        }
        #endif
        if let identifier = configuration.continuityIdentifier,
           let directory = configuration.continuityDirectory {
            let shell = configuration.shell
            let workingDirectory = configuration.workingDirectory
            let processEnvironment = Self.processEnvironment(overrides: environment)
            let launchArguments = arguments
            let columns = terminal.getTerminal().cols
            let rows = terminal.getTerminal().rows
            let imageGeometry = imageHostGeometry
            let preparedFailure = startupFailure
            let helperURL = configuration.continuityHelperURL
            terminal.acceptsUserInput = false
            terminal.setConnectionPending(true)
            // Process launch and the socket handshake can wait on another process. They must
            // not serialize the main thread while dozens of saved panes are being restored.
            persistentStartTask = Task { @MainActor in
                let result = await PersistentTerminalConnection.connectAsync(identifier: identifier, namespace: directory,
                    shell: shell, arguments: launchArguments, environment: processEnvironment,
                    directory: workingDirectory, columns: columns, rows: rows, helperURL: helperURL,
                    imageGeometry: imageGeometry)
                defer { self.persistentStartTask = nil; self.terminal.setConnectionPending(false) }
                switch result {
                case .success(let connection):
                    if self.pendingStartDisposition != .attach {
                        if self.pendingStartDisposition == .stop {
                            do { try await connection.stop() }
                            catch {
                                connection.closeConnection()
                                await self.stopPersistentHost(identifier: identifier, directory: directory)
                            }
                        }
                        connection.closeConnection()
                        return
                    }
                    do {
                        try self.attachPersistentConnection(connection, startupFailure: preparedFailure)
                        self.terminal.acceptsUserInput = !self.remoteControllerActive
                    } catch {
                        connection.closeConnection()
                        self.persistentConnection = nil
                        self.isRunning = false
                        self.onEvent?(.failed(TerminalSessionFailure(message: error.localizedDescription)))
                    }
                case .failure(let error):
                    if self.pendingStartDisposition == .stop {
                        await self.stopPersistentHost(identifier: identifier, directory: directory)
                    } else if self.pendingStartDisposition == .attach {
                        self.onEvent?(.failed(TerminalSessionFailure(message: error.localizedDescription)))
                    }
                }
            }
            return
        }
        terminal.startProcess(executable: configuration.shell.path, args: arguments,
            environment: Self.processEnvironment(overrides: environment),
            execName: "-\(configuration.shell.lastPathComponent)",
            currentDirectory: configuration.workingDirectory.path)
        try finishStartup(startupFailure: startupFailure)
    }

    #if DEBUG || MYTERM_RUST_WORKSPACES
    private func startRustWorkspace(_ startup: RustStartup) throws {
        guard let rustWorkspace else { return }
        switch startup {
        case .restore:
            if let selection = try rustWorkspace.backend.selection(paneID: rustWorkspace.paneID) {
                startRustAttachment(selection: selection, launch: nil, startupFailure: nil,
                                    runInitialCommand: false, restoresLostShell: true)
            } else {
                try startNewProcess(runInitialCommand: true)
            }
        case .reattach:
            guard let selection = try rustWorkspace.backend.selection(paneID: rustWorkspace.paneID) else {
                throw LocalRustTerminalError.missingSession
            }
            startRustAttachment(selection: selection, launch: nil, startupFailure: nil, runInitialCommand: false)
        case .replace:
            try startNewProcess(runInitialCommand: false)
        }
        rustStartupRetry = nil
    }

    /// Retire this pane's authenticated legacy helper before a Rust shell can resume its agent.
    private func retireLegacyWorkspaceHost(then startup: RustStartup) throws {
        guard let identifier = configuration.continuityIdentifier,
              let directory = configuration.continuityDirectory else {
            try startRustWorkspace(startup)
            return
        }
        let socket = PersistentTerminalConnection.socketDirectory(namespace: directory)
            .appendingPathComponent(identifier.uuidString + ".sock")
        guard FileManager.default.fileExists(atPath: socket.path)
                || FileManager.default.fileExists(atPath: socket.path + ".lock") else {
            try startRustWorkspace(startup)
            return
        }
        pendingStartDisposition = .attach
        terminal.setConnectionPending(true)
        persistentStartTask = Task { @MainActor in
            let result = await PersistentTerminalConnection.stopExistingAsync(identifier: identifier, namespace: directory,
                environment: configuration.environment, helperURL: configuration.continuityHelperURL, waitsForExit: true)
            persistentStartTask = nil
            terminal.setConnectionPending(false)
            if pendingStartDisposition == .stop, let rustWorkspace {
                stopRustWorkspace(rustWorkspace)
            }
            guard pendingStartDisposition == .attach else { return }
            if case .failure(let error) = result {
                rustStartupRetry = startup
                rustRecovery?.action = .retryStartup
                onEvent?(.failed(TerminalSessionFailure(message: "Could not stop the previous terminal session. \(error.localizedDescription)")))
                return
            }
            do { try startRustWorkspace(startup) }
            catch { onEvent?(.failed(TerminalSessionFailure(message: error.localizedDescription))) }
        }
    }

    func useRustWorkspaceBackend(_ backend: LocalRustWorkspaceBackend, paneID: UUID) {
        rustWorkspace = (backend, paneID)
        rustRecovery = LocalRustWorkspaceRecovery()
        terminal.acceptsUserInput = false
        terminal.onPersistentInput = { [weak self] bytes in
            guard let self, self.isRunning, self.rustMaySendInput else { return }
            do { try self.sendProcessInput(bytes) }
            catch { self.onEvent?(.runtimeNotice(error.localizedDescription)) }
        }
        terminal.onPersistentResizeRequest = { [weak self] columns, rows in
            guard let self, !self.remoteControllerActive else { return }
            self.resize(columns: columns, rows: rows)
        }
        terminal.onPersistentResize = { [weak self] columns, rows in
            self?.recordRemoteGeometry(columns: columns, rows: rows)
        }
        terminal.onPersistentImageGeometryChanged = { [weak self] in self?.resizeRustToFit() }
    }

    public func performRustRecoveryAction() {
        guard let rustWorkspace, let action = rustRecovery?.action, persistentStartTask == nil else { return }
        do {
            switch action {
            case .reattach:
                try retireLegacyWorkspaceHost(then: .reattach)
            case .startNewShell:
                try retireLegacyWorkspaceHost(then: .replace)
            case .retryStartup:
                guard let rustStartupRetry else { return }
                try retireLegacyWorkspaceHost(then: rustStartupRetry)
            case .takeControl:
                guard let rustController, let rustConnection else { return }
                try rustConnection.takeWorkspaceControl(observed: rustController)
                rustRecovery?.action = nil
            }
        } catch {
            onEvent?(.failed(TerminalSessionFailure(message: error.localizedDescription)))
        }
    }

    public func waitForPendingRustWorkspaceStart() async {
        guard rustWorkspace != nil else { return }
        while let task = persistentStartTask { await task.value }
    }

    private func startRustAttachment(selection: LocalRustWorkspaceBackend.Selection,
                                     launch: LocalRustTerminalConnection.WorkspaceLaunch?,
                                     startupFailure: TerminalSessionFailure?, runInitialCommand: Bool,
                                     restoresLostShell: Bool = false) {
        guard let rustWorkspace else { return }
        pendingStartDisposition = .attach
        rustRecovery?.action = nil
        terminal.setConnectionPending(true)
        persistentStartTask = Task { @MainActor in
            var pendingConnection: LocalRustTerminalConnection?
            var restoreWithNewShell = false
            defer {
                pendingConnection?.disconnect()
                self.persistentStartTask = nil
                self.terminal.setConnectionPending(false)
                self.updateRustInputAvailability()
                if restoreWithNewShell, self.pendingStartDisposition == .attach {
                    do {
                        if try rustWorkspace.backend.selection(paneID: rustWorkspace.paneID) == selection {
                            try self.startNewProcess(runInitialCommand: true,
                                                     replacingLostRustSession: (selection.sessionID, selection.clientID))
                        } else {
                            try self.startRustWorkspace(.reattach)
                        }
                    } catch { self.rustAttachmentFailed(error) }
                }
            }
            do {
                let connection = try await rustWorkspace.backend.connect(launch != nil)
                pendingConnection = connection
                if self.pendingStartDisposition == .stop {
                    self.stopRustWorkspace(rustWorkspace)
                    return
                }
                guard self.pendingStartDisposition == .attach else { return }
                try connection.beginWorkspace(sessionID: selection.sessionID, clientID: selection.clientID, launch: launch,
                                              checkpoint: LocalRustWorkspaceBackend.usesCheckpointProtocol)
                let attachment = try await connection.workspaceAttachment()
                if self.pendingStartDisposition == .stop {
                    connection.disconnect()
                    self.stopRustWorkspace(rustWorkspace, observed: attachment.control)
                    return
                }
                guard self.pendingStartDisposition == .attach else { return }

                if let checkpoint = attachment.checkpoint {
                    #if MYTERM_WEZTERM_CHECKPOINT
                    try self.terminal.importWezTermCheckpoint(
                        checkpoint.bytes, expectedSequence: checkpoint.sequence, adoptingServerGeometry: true
                    )
                    try connection.acknowledgeWorkspaceCheckpoint(sequence: checkpoint.sequence)
                    #else
                    _ = checkpoint
                    throw LocalRustTerminalError.checkpointUnavailable
                    #endif
                } else {
                    guard let launch, !LocalRustWorkspaceBackend.usesCheckpointProtocol else {
                        throw LocalRustTerminalError.checkpointUnavailable
                    }
                    self.terminal.getTerminal().resetToInitialState()
                    self.terminal.applyTerminalGeometry(columns: launch.columns, rows: launch.rows)
                    try self.terminal.invalidateAfterCheckpointImport()
                }
                self.rustCheckpointAttached = attachment.checkpoint != nil
                self.terminal.sendsTerminalResponses = !self.rustCheckpointAttached
                self.terminal.apply(runtimeConfiguration: self.runtimeConfiguration)
                self.remoteGeneration = UUID()
                self.remoteSequence = 0
                self.remoteReplayBuffer.removeAll(keepingCapacity: true)
                self.remoteReplayHead = 0
                self.remoteReplayBytes = 0
                self.rustConnection = connection
                self.rustShellPID = attachment.shellPID
                self.rustClientID = selection.clientID
                self.isRunning = true
                self.applyRustController(attachment.control)
                self.onEvent?(.transportAttached)
                self.recordRemoteGeometry(columns: self.terminal.getTerminal().cols, rows: self.terminal.getTerminal().rows)
                try self.finishStartup(startupFailure: startupFailure, runInitialCommand: runInitialCommand)
                let currentSession: @MainActor () -> SwiftTermTerminalSession? = { [weak self = self] in self }
                self.rustReadTask = Task { @MainActor in
                    await Self.readRustEvents(connection, session: currentSession)
                }
                pendingConnection = nil
                if launch != nil, self.startupToken == nil, (!runInitialCommand || self.configuration.initialCommand == nil) {
                    self.onEvent?(.idleShellStarted)
                }
            } catch {
                if self.pendingStartDisposition == .stop {
                    pendingConnection?.disconnect()
                    self.stopRustWorkspace(rustWorkspace)
                } else if self.pendingStartDisposition == .attach {
                    if restoresLostShell {
                        switch error {
                        case LocalRustTerminalError.missingServer:
                            restoreWithNewShell = true
                        case LocalRustTerminalError.missingSession:
                            // Old servers report a missing session for incompatible attachments too.
                            // Query control separately to distinguish an existing shell from a dead one.
                            do {
                                let probe = try await rustWorkspace.backend.connect(false)
                                defer { probe.disconnect() }
                                _ = try await probe.workspaceControl(sessionID: selection.sessionID, clientID: selection.clientID)
                            } catch LocalRustTerminalError.missingSession, LocalRustTerminalError.missingServer {
                                restoreWithNewShell = true
                            } catch { }
                        default: break
                        }
                    }
                    if self.pendingStartDisposition == .stop {
                        pendingConnection?.disconnect()
                        self.stopRustWorkspace(rustWorkspace)
                        return
                    }
                    guard self.pendingStartDisposition == .attach, !restoreWithNewShell else { return }
                    self.rustAttachmentFailed(error)
                }
            }
        }
    }

    private static func readRustEvents(_ connection: LocalRustTerminalConnection,
                                       session: @escaping @MainActor () -> SwiftTermTerminalSession?) async {
        do {
            while !Task.isCancelled {
                let event = try await connection.nextWorkspaceEvent()
                guard let session = session(), session.rustConnection === connection else { return }
                session.handleRustEvent(event)
            }
        } catch {
            guard let session = session(), session.rustConnection === connection else { return }
            session.rustAttachmentFailed(error)
        }
    }

    private func handleRustEvent(_ event: LocalRustTerminalConnection.WorkspaceEvent) {
        switch event {
        case .output(let data):
            terminal.dataReceived(slice: [UInt8](data)[...])
        case .geometry(let columns, let rows, let cellPixels):
            guard (cellPixels != nil) == rustCheckpointAttached else {
                rustAttachmentFailed(LocalRustTerminalError.invalidMessage)
                return
            }
            if let cellPixels {
                let scale = terminal.imageRenderingGeometry.displayScale
                let width = CGFloat(cellPixels.width) / scale
                let height = CGFloat(cellPixels.height) / scale
                terminal.authoritativeImageGeometry = TerminalImageGeometry(
                    cellSize: CGSize(width: width, height: height),
                    viewportSize: CGSize(width: width * CGFloat(columns), height: height * CGFloat(rows)),
                    displayScale: scale
                )
            }
            terminal.applyTerminalGeometry(columns: columns, rows: rows)
            recordRemoteGeometry(columns: columns, rows: rows)
        case .control(let controller, let rejected):
            applyRustController(controller)
            if rejected {
                onEvent?(.runtimeNotice("Terminal control changed before the request was accepted."))
            }
        }
    }

    private func applyRustController(_ controller: LocalRustTerminalConnection.Controller) {
        let previouslyControlled = rustMaySendInput
        rustController = controller
        rustRecovery?.action = rustMaySendInput ? nil : .takeControl
        updateRustInputAvailability()
        if rustMaySendInput && !previouslyControlled {
            rustRequestedGeometry = nil
            resizeRustToFit()
        }
    }

    private var rustCellPixels: LocalRustTerminalConnection.CellPixels {
        let metrics = terminal.imageRenderingGeometry
        return LocalRustTerminalConnection.CellPixels(
            width: UInt16(clamping: max(1, Int((metrics.cellSize.width * metrics.displayScale).rounded()))),
            height: UInt16(clamping: max(1, Int((metrics.cellSize.height * metrics.displayScale).rounded())))
        )
    }

    private func resizeRustToFit() {
        guard !remoteControllerActive else { return }
        let fitted = terminal.fittedTerminalGeometry()
        resizeRustProcess(columns: fitted.columns, rows: fitted.rows)
    }

    private func resizeRustProcess(columns: Int, rows: Int) {
        guard rustMaySendInput, let rustConnection else { return }
        let fitted = SessionHostGeometry.fit(columns: columns, rows: rows)
        let cellPixels = rustCheckpointAttached ? rustCellPixels : nil
        let requested = RustGeometry(columns: fitted.columns, rows: fitted.rows, cellPixels: cellPixels)
        guard requested != rustRequestedGeometry else { return }
        rustRequestedGeometry = requested
        rustConnection.resize(columns: fitted.columns, rows: fitted.rows, cellPixels: cellPixels)
    }

    private func updateRustInputAvailability() {
        terminal.acceptsUserInput = isRunning && !isStarting && rustMaySendInput && !remoteControllerActive
        terminal.automaticallyResizesTerminal = !remoteControllerActive && rustMaySendInput
    }

    private func rustAttachmentFailed(_ error: Error) {
        closeRustAttachment()
        switch error {
        case LocalRustTerminalError.missingServer, LocalRustTerminalError.missingSession:
            rustRecovery?.action = .startNewShell
        case LocalRustTerminalError.sessionEnded(let message):
            rustRecovery?.action = .startNewShell
            emitTermination(exitCode: nil, explanation: message)
            return
        default:
            rustRecovery?.action = .reattach
        }
        onEvent?(.failed(TerminalSessionFailure(message: error.localizedDescription)))
    }

    private func closeRustAttachment() {
        stopWorkingDirectoryPolling()
        rustConnection?.disconnect()
        rustConnection = nil
        rustReadTask?.cancel()
        rustReadTask = nil
        rustShellPID = nil
        rustController = nil
        rustCheckpointAttached = false
        rustRequestedGeometry = nil
        isRunning = false
        updateRustInputAvailability()
    }

    private func stopRustWorkspace(_ workspace: (backend: LocalRustWorkspaceBackend, paneID: UUID),
                                   observed: LocalRustTerminalConnection.Controller? = nil) {
        Task { @MainActor in
            do { try await workspace.backend.stopExisting(paneID: workspace.paneID, observed: observed) }
            catch {
                Logger(subsystem: "com.gordonbeeming.myterm", category: "terminal-continuity")
                    .error("Could not stop Rust terminal: \(error.localizedDescription, privacy: .public)")
                self.onEvent?(.failed(TerminalSessionFailure(message: error.localizedDescription)))
            }
        }
    }
    #endif

    func attachPersistentConnection(_ connection: PersistentTerminalConnection,
                                            startupFailure: TerminalSessionFailure?) throws {
        var startupFailure = startupFailure
        persistentConnection = connection
        hostSequence = connection.attachment.sequence ?? 0
        requestedHostGeometry = nil
        requestedImageGeometry = nil
        try applyAuthoritativeImageGeometry(connection.attachment.imageGeometry)
        if let checkpoint = connection.attachment.bytes { try terminal.getTerminal().importCheckpoint(checkpoint) }
        recordRemoteGeometry(columns: terminal.getTerminal().cols, rows: terminal.getTerminal().rows)
        terminal.needsDisplay = true
        terminal.onPersistentInput = { [weak self] bytes in
            guard let self else { return }
            do { try self.sendProcessInput(bytes) }
            catch { self.onEvent?(.failed(TerminalSessionFailure(message: error.localizedDescription))) }
        }
        terminal.onPersistentImageGeometryChanged = { [weak self] in
            guard let self, let connection = self.persistentConnection else { return }
            do {
                try connection.send(.init(kind: "configure", generation: connection.attachment.generation,
                    scrollbackLines: min(self.runtimeConfiguration.scrollbackLines, 100_000),
                    imageGeometry: self.imageHostGeometry))
            } catch { self.onEvent?(.failed(TerminalSessionFailure(message: error.localizedDescription))) }
        }
        terminal.onPersistentResizeRequest = { [weak self] columns, rows in
            guard let self else { return }
            guard !self.remoteControllerActive else { return }
            do { try self.resizePersistentProcess(columns: columns, rows: rows) }
            catch { self.onEvent?(.failed(TerminalSessionFailure(message: error.localizedDescription))) }
        }
        terminal.onPersistentResize = { [weak self] columns, rows in self?.recordRemoteGeometry(columns: columns, rows: rows) }
        // Checkpoints include the old emulator options and dimensions. Reapply the
        // current preferences, then explicitly fit both emulators to the native view.
        terminal.apply(runtimeConfiguration: runtimeConfiguration)
        try connection.send(.init(kind: "configure", generation: connection.attachment.generation, scrollbackLines: min(runtimeConfiguration.scrollbackLines, 100_000), imageGeometry: imageHostGeometry))
        terminal.resizeToFit()
        if !remoteControllerActive {
            let fitted = terminal.fittedTerminalGeometry()
            try resizePersistentProcess(columns: fitted.columns, rows: fitted.rows)
        }
        connection.onMessage = { [weak self] message in self?.handleHostMessage(message) }
        connection.onFailure = { [weak self] error in
            guard let self else { return }
            self.stopWorkingDirectoryPolling()
            self.isRunning = false
            self.onEvent?(.failed(TerminalSessionFailure(message: error.localizedDescription)))
        }
        if !connection.createdHost {
            // Reattaching resumes the same process, never an agent resume command.
            startupToken = nil
            startupFailure = nil
        }
        isRunning = true
        if let pending = connection.attachment.pendingActivities, !pending.isEmpty {
            for activity in pending { onEvent?(.restoredAgentActivity(activity)) }
        } else if let activity = connection.attachment.activity {
            onEvent?(.restoredAgentActivity(activity))
        }
        if connection.createdHost, connection.attachment.text == startupToken,
           startupToken != nil {
            startupToken = nil
        }
        connection.beginReading()
        if let omitted = connection.attachment.omittedScrollbackLines, omitted > 0 {
            onEvent?(.runtimeNotice("Reattached to the running terminal with its most recent history. \(omitted) older lines were omitted from this view to keep the checkpoint bounded; the host retains its configured history."))
        }
        if connection.createdHost, configuration.restoredOutput?.isEmpty == false {
            onEvent?(.runtimeNotice("The previous terminal host is unavailable. A new shell was started; saved output is a preview of the previous process. Any saved agent conversation is resumed separately."))
        }
        try finishStartup(startupFailure: startupFailure)
        if connection.createdHost, configuration.initialCommand == nil {
            onEvent?(.idleShellStarted)
        }
    }

    private func finishStartup(startupFailure: TerminalSessionFailure?, runInitialCommand: Bool = true) throws {
        guard attachedShellPID != nil || terminal.process.running else {
            let failure = TerminalSessionFailure(message: "The terminal process could not start.")
            onEvent?(.failed(failure))
            throw failure
        }
        isRunning = true
        if let startupFailure {
            onEvent?(.initialCommandFailed(startupFailure))
        } else if runInitialCommand, startupToken == nil, persistentConnection?.createdHost != false {
            sendInitialCommand()
        } else if startupToken != nil {
            // The token stays live past the grace period. Many shells start at once after a login,
            // and a shell that is only slow must still receive its command. Readiness is signalled
            // as its first prompt opens, so the user has not had a prompt to type at before then.
            let timer = Timer(timeInterval: startupReadinessGracePeriod, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isRunning, self.startupToken != nil else { return }
                    self.startupReadinessTimer = nil
                    self.startupCommandOverdue = true
                    let command = self.configuration.initialCommand ?? ""
                    self.onEvent?(.runtimeNotice(
                        "Shell startup is taking longer than usual. The saved command will run when the shell is ready. If the prompt appears and it does not run, run it manually: \(command)"
                    ))
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            startupReadinessTimer = timer
        }
        workingDirectoryPoller = ProcessWorkingDirectoryPoller(
            processID: attachedShellPID ?? terminal.process.shellPid,
            provider: MacOSProcessWorkingDirectoryProvider(),
            onDirectoryChanged: { [weak self] directory in
                Task { @MainActor [weak self] in
                    self?.emitWorkingDirectoryChanged(directory)
                }
            }
        )
        workingDirectoryPoller?.start(initialDirectory: configuration.workingDirectory)
        startForegroundProcessPolling()
    }

    private func sendInitialCommand() {
        if let command = configuration.initialCommand, !command.isEmpty {
            let cleanup = configuration.shell.lastPathComponent == "bash" ? " _myterm_finish_startup 2>/dev/null; " : ""
            terminal.send(txt: cleanup + command + "\n")
        }
    }

    /// Asks the kernel who is in front of the shell, on the same cadence as the working directory.
    ///
    /// An agent that is killed never runs its SessionEnd hook, so the pane would keep saying it
    /// holds an agent. The shell coming back to the front is the one signal that survives a kill.
    private func startForegroundProcessPolling() {
        lastReportedForegroundProcessName = nil
        pollForegroundProcess()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollForegroundProcess() }
        }
        RunLoop.main.add(timer, forMode: .common)
        foregroundProcessTimer = timer
    }

    private func pollForegroundProcess() {
        guard isRunning else { return }
        let name = activeForegroundProcessName
        guard name != lastReportedForegroundProcessName else { return }
        lastReportedForegroundProcessName = name
        onEvent?(.foregroundProcessChanged(name))
    }

    public func resize(columns: Int, rows: Int) {
        guard columns > 0, rows > 0 else {
            onEvent?(.failed(TerminalSessionFailure(message: "Terminal dimensions must be positive.")))
            return
        }

        #if DEBUG || MYTERM_RUST_WORKSPACES
        if rustWorkspace != nil {
            resizeRustProcess(columns: columns, rows: rows)
            return
        }
        #endif
        if persistentConnection != nil {
            do { try resizePersistentProcess(columns: columns, rows: rows) }
            catch { onEvent?(.failed(TerminalSessionFailure(message: error.localizedDescription))) }
            return
        }

        terminal.getTerminal().resize(cols: columns, rows: rows)
        terminal.sizeChanged(source: terminal, newCols: columns, newRows: rows)
        terminal.needsDisplay = true
        recordRemoteGeometry(columns: terminal.getTerminal().cols, rows: terminal.getTerminal().rows)
    }

    public func focus() {
        terminal.focusWhenPossible()
    }

    public func showFind() {
        // SwiftTerm only exposes its find bar through the AppKit text-finder action, which reads
        // the action out of the sender's tag, so a detached menu item is the way to drive it.
        let action = NSMenuItem()
        action.tag = NSTextFinder.Action.showFindInterface.rawValue
        terminal.performTextFinderAction(action)
    }

    public func terminate() {
        if persistentStartTask != nil {
            pendingStartDisposition = .stop
            terminal.setConnectionPending(false)
            return
        }
        stopWorkingDirectoryPolling()
        #if DEBUG || MYTERM_RUST_WORKSPACES
        if let rustWorkspace {
            let observed = rustController
            closeRustAttachment()
            stopRustWorkspace(rustWorkspace, observed: observed)
            return
        }
        #endif
        if let connection = persistentConnection {
            persistentConnection = nil
            isRunning = false
            Task { @MainActor in
                do { try await connection.stop() }
                catch {
                    if let identifier = configuration.continuityIdentifier, let directory = configuration.continuityDirectory {
                        await stopPersistentHost(identifier: identifier, directory: directory)
                    } else { onEvent?(.failed(TerminalSessionFailure(message: error.localizedDescription))) }
                }
            }
            return
        }
        if let identifier = configuration.continuityIdentifier, let directory = configuration.continuityDirectory {
            Task { await stopPersistentHost(identifier: identifier, directory: directory) }
            return
        }
        guard isRunning else { return }
        let foregroundProcessGroup = tcgetpgrp(terminal.process.childfd)
        let shellProcessGroup = getpgid(terminal.process.shellPid)
        if foregroundProcessGroup > 0,
           shellProcessGroup > 0,
           foregroundProcessGroup != shellProcessGroup {
            _ = kill(-foregroundProcessGroup, SIGHUP)
        }
        terminal.terminate()
    }

    public func detach() {
        if persistentStartTask != nil {
            if pendingStartDisposition != .stop { pendingStartDisposition = .detach }
            terminal.setConnectionPending(false)
            return
        }
        #if DEBUG || MYTERM_RUST_WORKSPACES
        if rustWorkspace != nil {
            closeRustAttachment()
            return
        }
        #endif
        guard let connection = persistentConnection else {
            if configuration.continuityIdentifier == nil { terminate() }
            return
        }
        stopWorkingDirectoryPolling()
        startupReadinessTimer?.invalidate()
        startupReadinessTimer = nil
        connection.closeConnection()
        persistentConnection = nil
        isRunning = false
    }

    private func stopPersistentHost(identifier: UUID, directory: URL) async {
        let result = await PersistentTerminalConnection.stopExistingAsync(identifier: identifier, namespace: directory,
            environment: configuration.environment, helperURL: configuration.continuityHelperURL)
        if case .failure(let error) = result {
            Logger(subsystem: "com.gordonbeeming.myterm", category: "terminal-continuity")
                .error("Could not stop persistent terminal: \(error.localizedDescription, privacy: .public)")
            onEvent?(.failed(TerminalSessionFailure(message: error.localizedDescription)))
        }
    }

    public func insertLocalText(_ text: String) throws {
        guard isRunning else { throw TerminalRemoteSessionError.notRunning }
        guard terminal.acceptsUserInput else { throw TerminalRemoteSessionError.unavailable }
        guard !text.isEmpty, text.utf8.count <= 64 * 1_024,
              !text.unicodeScalars.contains(where: { ($0.value < 32 && $0 != "\n" && $0 != "\t") || $0.value == 127 }) else {
            throw TerminalRemoteSessionError.invalidInput
        }
        guard terminal.getTerminal().bracketedPasteMode || !text.contains("\n") else {
            throw TerminalSessionFailure(message: "This terminal has not enabled bracketed paste. Multiline text cannot be inserted safely. Wait for a compatible prompt or insert one line at a time.")
        }
        let paste = terminal.getTerminal().bracketedPasteMode
            ? "\u{1b}[200~" + text + "\u{1b}[201~" : text
        try sendProcessInput(Data(paste.utf8))
    }

    private func sendProcessInput(_ bytes: Data) throws {
        // AppKit may commit empty text (for example a paste without a text value).
        // It is a no-op, not a terminal protocol message.
        guard !bytes.isEmpty else { return }
        guard isRunning else { throw TerminalRemoteSessionError.notRunning }
        #if DEBUG || MYTERM_RUST_WORKSPACES
        if rustWorkspace != nil {
            guard rustMaySendInput, let rustConnection else { throw TerminalRemoteSessionError.unavailable }
            guard rustConnection.sendInput([UInt8](bytes)[...]) else { throw LocalRustTerminalError.backpressure }
            return
        }
        #endif
        if let connection = persistentConnection {
            try connection.send(.init(kind: "input", bytes: bytes, generation: connection.attachment.generation))
        } else {
            terminal.process.send(data: [UInt8](bytes)[...])
        }
    }

    private func applyAuthoritativeImageGeometry(_ geometry: SessionHostImageGeometry?) throws {
        guard let geometry else { throw SessionHostError.incompatibleVersion }
        guard geometry.isValid else { throw SessionHostError.invalidFrame }
        terminal.authoritativeImageGeometry = TerminalImageGeometry(
            cellSize: CGSize(width: geometry.cellWidth, height: geometry.cellHeight),
            viewportSize: CGSize(width: geometry.viewportWidth, height: geometry.viewportHeight),
            displayScale: geometry.displayScale)
    }

    private var imageHostGeometry: SessionHostImageGeometry {
        let metrics = terminal.imageRenderingGeometry
        return SessionHostImageGeometry(cellWidth: metrics.cellSize.width, cellHeight: metrics.cellSize.height,
            viewportWidth: metrics.viewportSize.width, viewportHeight: metrics.viewportSize.height,
            displayScale: metrics.displayScale)
    }

    private func resizePersistentProcess(columns: Int, rows: Int) throws {
        guard let connection = persistentConnection else { return }
        let fitted = SessionHostGeometry.fit(columns: columns, rows: rows)
        if fitted.columns != columns || fitted.rows != rows {
            if !reportedGeometryLimit {
                reportedGeometryLimit = true
                onEvent?(.runtimeNotice("This terminal viewport was limited to \(fitted.columns) columns by \(fitted.rows) rows so it can be restored safely. Increase the font size or reduce the pane size to use fewer cells."))
            }
        } else { reportedGeometryLimit = false }
        let requested = RequestedHostGeometry(columns: fitted.columns, rows: fitted.rows)
        let imageGeometry = imageHostGeometry
        guard requested != requestedHostGeometry || imageGeometry != requestedImageGeometry else { return }
        if requestedHostGeometry == nil, imageGeometry == requestedImageGeometry,
           terminal.getTerminal().cols == fitted.columns, terminal.getTerminal().rows == fitted.rows { return }
        try connection.send(.init(kind: "resize", columns: fitted.columns, rows: fitted.rows,
                                  generation: connection.attachment.generation, imageGeometry: imageGeometry))
        requestedHostGeometry = requested
        requestedImageGeometry = imageGeometry
    }

    private func handleHostMessage(_ message: SessionHostMessage) {
        switch message.kind {
        case "output", "geometry":
            guard message.generation == persistentConnection?.attachment.generation,
                  message.sequence == hostSequence + 1 else {
                persistentConnection?.closeConnection()
                isRunning = false
                onEvent?(.failed(TerminalSessionFailure(message: "The terminal host stream lost its output order. Reattach before continuing.")))
                return
            }
            do { try applyAuthoritativeImageGeometry(message.imageGeometry) }
            catch {
                persistentConnection?.closeConnection()
                isRunning = false
                onEvent?(.failed(TerminalSessionFailure(message: "The terminal host sent invalid image geometry.")))
                return
            }
            hostSequence += 1
            if message.kind == "geometry" {
                guard let columns = message.columns, let rows = message.rows,
                      (2...1_024).contains(columns), (1...1_024).contains(rows),
                      columns * rows <= SessionHostGeometry.maximumCellsPerBuffer else {
                    onEvent?(.failed(TerminalSessionFailure(message: "The terminal host sent invalid geometry.")))
                    return
                }
                if let checkpoint = message.bytes {
                    do {
                        try terminal.getTerminal().importCheckpoint(checkpoint)
                        guard terminal.getTerminal().cols == columns, terminal.getTerminal().rows == rows else {
                            throw SessionHostError.invalidFrame
                        }
                        try terminal.invalidateAfterCheckpointImport()
                        // An authoritative checkpoint replaces the rendering baseline, not
                        // the process. Remote viewers use generation mismatch to resync.
                        remoteGeneration = UUID()
                        remoteSequence = 0
                        remoteReplayBuffer.removeAll(keepingCapacity: true)
                        remoteReplayHead = 0
                        remoteReplayBytes = 0
                    } catch {
                        persistentConnection?.closeConnection()
                        isRunning = false
                        onEvent?(.failed(TerminalSessionFailure(message: error.localizedDescription)))
                        return
                    }
                } else { terminal.applyTerminalGeometry(columns: columns, rows: rows) }
                if requestedHostGeometry == RequestedHostGeometry(columns: columns, rows: rows) {
                    requestedHostGeometry = nil
                }
                recordRemoteGeometry(columns: columns, rows: rows)
                return
            }
            guard let bytes = message.bytes else { return }
            terminal.dataReceived(slice: [UInt8](bytes)[...])
        case "foreground":
            persistentForegroundProcessName = message.text
            terminal.persistentShellIsForeground = message.text == nil
        case "exited":
            persistentConnection?.closeConnection()
            persistentConnection = nil
            emitTermination(exitCode: message.exitCode, explanation: message.text)
        case "error": onEvent?(.failed(TerminalSessionFailure(message: message.text ?? "Terminal host error.")))
        case "inputError": onEvent?(.initialCommandFailed(TerminalSessionFailure(message: message.text ?? "The terminal could not accept this input.")))
        default: onEvent?(.failed(TerminalSessionFailure(message: "Unexpected terminal host message.")))
        }
    }

    public func apply(runtimeConfiguration: TerminalRuntimeConfiguration) {
        self.runtimeConfiguration = runtimeConfiguration
        terminal.apply(runtimeConfiguration: runtimeConfiguration)
        #if DEBUG || MYTERM_RUST_WORKSPACES
        if rustWorkspace != nil { resizeRustToFit() }
        #endif
        if let connection = persistentConnection {
            do { try connection.send(.init(kind: "configure", generation: connection.attachment.generation, scrollbackLines: min(runtimeConfiguration.scrollbackLines, 100_000), imageGeometry: imageHostGeometry)) }
            catch { onEvent?(.initialCommandFailed(TerminalSessionFailure(message: error.localizedDescription))) }
        }
    }

    public func contentSnapshot(maximumCharacters: Int) -> String {
        terminal.renderedText(maximumCharacters: maximumCharacters)
    }

    public func setContentChangeHandler(_ handler: (@MainActor () -> Void)?) {
        contentChangeHandler = handler
    }

    public func setPaneActive(_ isActive: Bool) {
        terminal.setPaneActive(isActive)
    }

    public func setRemoteOutputHandler(_ handler: (@MainActor (TerminalRemoteOutput) -> Void)?) {
        remoteOutputHandler = handler
    }

    public func setRemoteGeometryHandler(_ handler: (@MainActor (TerminalRemoteGeometry) -> Void)?) {
        remoteGeometryHandler = handler
    }

    public func setRemoteCaptureEnabled(_ enabled: Bool) {
        guard remoteCaptureEnabled != enabled else { return }
        remoteCaptureEnabled = enabled
        if enabled {
            terminal.onRawOutput = { [weak self] bytes in
                self?.recordRemoteOutput(bytes)
            }
        } else {
            terminal.onRawOutput = nil
            remoteReplayBuffer.removeAll(keepingCapacity: false)
            remoteReplayHead = 0
            remoteReplayBytes = 0
        }
    }

    public func remoteCheckpoint() throws -> TerminalRemoteCheckpoint {
        guard isRunning else { throw TerminalRemoteSessionError.notRunning }
        return TerminalRemoteCheckpoint(
            generation: remoteGeneration,
            sequence: remoteSequence,
            bytes: try terminal.getTerminal().exportCheckpoint()
        )
    }

    public func remoteReplay(after sequence: UInt64) throws -> [TerminalRemoteOutput] {
        guard sequence <= remoteSequence else { throw TerminalRemoteSessionError.staleGeneration }
        guard sequence < remoteSequence else { return [] }
        guard remoteCaptureEnabled,
              remoteReplayHead < remoteReplayBuffer.count,
              let first = remoteReplayBuffer[remoteReplayHead...].first,
              sequence >= first.sequence - 1 else {
            throw TerminalRemoteSessionError.replayGap
        }
        return remoteReplayBuffer[remoteReplayHead...].filter { $0.sequence > sequence }
    }

    public func sendRemoteInput(_ bytes: Data, generation: UUID) throws {
        guard generation == remoteGeneration else { throw TerminalRemoteSessionError.staleGeneration }
        guard isRunning else { throw TerminalRemoteSessionError.notRunning }
        guard !bytes.isEmpty, bytes.count <= Self.maximumRemoteInputBytes else {
            throw TerminalRemoteSessionError.invalidInput
        }
        try sendProcessInput(bytes)
    }

    public func resizeRemotely(columns: Int, rows: Int, generation: UUID) throws {
        guard generation == remoteGeneration else { throw TerminalRemoteSessionError.staleGeneration }
        guard isRunning else { throw TerminalRemoteSessionError.notRunning }
        guard (2...1_024).contains(columns), (1...1_024).contains(rows) else {
            throw TerminalRemoteSessionError.invalidInput
        }
        resize(columns: columns, rows: rows)
    }

    public func pasteRemoteImage(_ payload: RemoteTerminalImagePayload) throws {
        guard payload.generation == remoteGeneration else {
            throw TerminalRemoteSessionError.staleGeneration
        }
        guard isRunning else { throw TerminalRemoteSessionError.notRunning }
        switch payload.contentType {
        case .png:
            guard payload.bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) else {
                throw TerminalRemoteSessionError.invalidInput
            }
        case .jpeg:
            guard payload.bytes.starts(with: [0xFF, 0xD8, 0xFF]) else {
                throw TerminalRemoteSessionError.invalidInput
            }
        }
        guard let image = NSImage(data: payload.bytes), image.isValid else {
            throw TerminalRemoteSessionError.invalidInput
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects([image]) else {
            throw TerminalRemoteSessionError.invalidInput
        }
        try sendProcessInput(Data([0x16]))
    }

    public func setRemoteControllerActive(_ active: Bool) {
        remoteControllerActive = active
        #if DEBUG || MYTERM_RUST_WORKSPACES
        if rustWorkspace != nil {
            updateRustInputAvailability()
            terminal.setRemoteControlBanner(active: active) { [weak self] in
                self?.remoteTakeControlHandler?()
            }
            if !active { resizeRustToFit() }
            return
        }
        #endif
        terminal.acceptsUserInput = !active && !isStarting
        terminal.automaticallyResizesTerminal = !active
        terminal.setRemoteControlBanner(active: active) { [weak self] in
            self?.remoteTakeControlHandler?()
        }
        if !active {
            terminal.resizeToFit()
        }
    }

    public func setRemoteTakeControlHandler(_ handler: (@MainActor () -> Void)?) {
        remoteTakeControlHandler = handler
    }

    private func emitTermination(exitCode: Int32?, explanation: String? = nil) {
        guard !didTerminate else { return }
        didTerminate = true
        stopWorkingDirectoryPolling()
        isRunning = false
        if let explanation {
            // A raw status would replace the host's account of who stopped the shell and why.
            onEvent?(.failed(TerminalSessionFailure(message: explanation)))
            onEvent?(.processTerminated(exitCode: nil))
            return
        }
        if exitCode == nil {
            onEvent?(.failed(TerminalSessionFailure(message: "The terminal process ended before reporting an exit code.")))
        }
        onEvent?(.processTerminated(exitCode: exitCode))
    }

    private func emitWorkingDirectoryChanged(_ directory: URL) {
        guard isRunning, directory != lastReportedWorkingDirectory else { return }
        lastReportedWorkingDirectory = directory
        terminal.currentWorkingDirectory = directory
        workingDirectoryPoller?.updateCurrentDirectory(directory)
        onEvent?(.workingDirectoryChanged(directory))
    }

    private func stopWorkingDirectoryPolling() {
        startupReadinessTimer?.invalidate()
        startupReadinessTimer = nil
        startupToken = nil
        startupCommandOverdue = false
        workingDirectoryPoller?.stop()
        workingDirectoryPoller = nil
        foregroundProcessTimer?.invalidate()
        foregroundProcessTimer = nil
    }

    func recordRemoteOutput(_ bytes: Data) {
        guard remoteCaptureEnabled, !bytes.isEmpty else { return }
        remoteSequence &+= 1
        let output = TerminalRemoteOutput(
            generation: remoteGeneration,
            sequence: remoteSequence,
            bytes: bytes
        )
        remoteReplayBuffer.append(output)
        remoteReplayBytes += bytes.count
        while remoteReplayBytes > Self.maximumRemoteReplayBytes
                || remoteReplayBuffer.count - remoteReplayHead > Self.maximumRemoteReplayFrames {
            remoteReplayBytes -= remoteReplayBuffer[remoteReplayHead].bytes.count
            remoteReplayHead += 1
        }
        if remoteReplayHead > 1_024,
           remoteReplayHead * 2 > remoteReplayBuffer.count {
            remoteReplayBuffer.removeFirst(remoteReplayHead)
            remoteReplayHead = 0
        }
        remoteOutputHandler?(output)
    }

    func recordRemoteGeometry(columns: Int, rows: Int) {
        let geometry = TerminalRemoteGeometry(
            generation: remoteGeneration,
            columns: columns,
            rows: rows
        )
        guard geometry != remoteGeometry else { return }
        remoteGeometry = geometry
        remoteGeometryHandler?(geometry)
    }

    private static func processEnvironment(overrides: [String: String]) -> [String] {
        let values = processEnvironmentValues(overrides: overrides)
        return values.keys.sorted().compactMap { key in values[key].map { "\(key)=\($0)" } }
    }

    private static func processEnvironmentValues(overrides: [String: String]) -> [String: String] {
        var values = [String: String]()
        for entry in Terminal.getEnvironmentVariables(termName: "xterm-256color") {
            let pair = entry.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            values[pair[0]] = pair[1]
        }
        values.merge(overrides) { _, override in override }
        return values
    }
}

@MainActor
final class MyTermLocalProcessTerminalView: LocalProcessTerminalView {
    var onPersistentInput: ((Data) -> Void)?
    var onPersistentResize: ((Int, Int) -> Void)?
    var onPersistentResizeRequest: ((Int, Int) -> Void)?
    var onPersistentImageGeometryChanged: (() -> Void)?
    var persistentShellIsForeground = true

    override func terminalResizeRequested(source: TerminalView, columns: Int, rows: Int) -> Bool {
        guard let onPersistentResizeRequest else { return false }
        onPersistentResizeRequest(columns, rows)
        return true
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if let onPersistentInput { onPersistentInput(Data(data)) }
        else { super.send(source: source, data: data) }
    }

    override func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        if let onPersistentResize { onPersistentResize(newCols, newRows) }
        else { super.sizeChanged(source: source, newCols: newCols, newRows: newRows) }
    }
    var onOpenWebURL: ((URL) -> Void)?
    var onContentChanged: (() -> Void)?
    var onAgentActivity: ((AgentActivityReport) -> Void)?
    var onShellReady: ((String) -> Void)?
    var onRawOutput: ((Data) -> Void)?
    var currentWorkingDirectory: URL?
    private let contentChangeCoalescer = TerminalContentChangeCoalescer()
    // AppKit owns local monitor tokens and requires the opaque value again for removal.
    // The view is main-actor isolated, while Swift 6 treats deinit as nonisolated.
    nonisolated(unsafe) private var keyEventMonitor: Any?
    private var shouldFocusWhenAttachedToWindow = false
    private var paneIsActive = true
    /// Colour the caret takes whenever this pane is active. Held separately because an
    /// inactive pane parks `caretColor` at `.clear`, and a theme change while parked must
    /// still be what the caret comes back as.
    private var themeCaretColor: NSColor = .textColor
    private var wordSelectionInput = TerminalWordSelectionInputState()
    private var wordSelectionResolutionGeneration = 0
    private var emacsWordSelectionEnabled = true
    private var remoteControlBanner: RemoteControlBannerView?
    private var connectionPendingLabel: NSTextField?
    private var pendingLinkClickRowText: String?
    private var isSelectingTextForCurrentGesture = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        installKeyEventMonitor()
        applyDefaultCaretColors()
        installAgentActivityHandler()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        installKeyEventMonitor()
        applyDefaultCaretColors()
        installAgentActivityHandler()
    }

    func setConnectionPending(_ pending: Bool) {
        connectionPendingLabel?.removeFromSuperview()
        connectionPendingLabel = nil
        guard pending else { return }
        let label = NSTextField(labelWithString: "Connecting terminal…")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.backgroundColor = .windowBackgroundColor
        label.drawsBackground = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityIdentifier("terminal-connecting")
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
        connectionPendingLabel = label
    }

    private func installAgentActivityHandler() {
        getTerminal().registerOscHandler(code: 7338) { [weak self] payload in
            guard let token = String(bytes: payload, encoding: .utf8) else { return }
            self?.onShellReady?(token)
        }
        getTerminal().registerOscHandler(code: AgentActivityMarker.oscCode) { [weak self] payload in
            guard let self,
                  let text = String(bytes: payload, encoding: .utf8),
                  let report = AgentActivityMarker.report(fromPayload: text) else {
                return
            }
            self.onAgentActivity?(report)
        }
    }

    deinit {
        if let keyEventMonitor {
            NSEvent.removeMonitor(keyEventMonitor)
        }
    }

    func setRemoteControlBanner(active: Bool, takeControl: @escaping @MainActor () -> Void) {
        if active {
            let banner = remoteControlBanner ?? RemoteControlBannerView()
            banner.takeControl = takeControl
            if banner.superview == nil { addSubview(banner) }
            remoteControlBanner = banner
            needsLayout = true
        } else {
            remoteControlBanner?.removeFromSuperview()
            remoteControlBanner = nil
        }
    }

    override func layout() {
        super.layout()
        guard let banner = remoteControlBanner else { return }
        let width = min(max(280, bounds.width * 0.55), bounds.width)
        banner.frame = NSRect(
            x: max(0, (bounds.width - width) / 2),
            y: max(0, bounds.height - 44),
            width: width,
            height: 36
        )
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        onRawOutput?(Data(slice))
        let originalMouseReporting = allowMouseReporting
        if selectionActive {
            allowMouseReporting = false
        }
        defer { allowMouseReporting = originalMouseReporting }

        super.dataReceived(slice: slice)
        let hadPendingMovement = wordSelectionInput.hasPendingMovement
        let pendingInput = wordSelectionInput.observeCursorPosition(
            terminalInputCursorPosition(),
            characterDistance: terminalInputCharacterDistance
        )
        if let pendingInput {
            send(pendingInput)
        }
        if hadPendingMovement,
           (pendingInput != nil || !wordSelectionInput.hasPendingMovement) {
            scheduleWordSelectionResolutionIfNeeded()
        }
        contentChangeCoalescer.notify { [weak self] in
            self?.onContentChanged?()
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let previous = frame.size
        super.setFrameSize(newSize)
        if previous != newSize { onPersistentImageGeometryChanged?() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if window != nil { onPersistentImageGeometryChanged?() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onPersistentImageGeometryChanged?() }
        guard window != nil, shouldFocusWhenAttachedToWindow else { return }
        focusWhenPossible()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        isSelectingTextForCurrentGesture = false
        super.mouseDown(with: event)
        isSelectingTextForCurrentGesture = selectionActive
    }

    override func mouseDragged(with event: NSEvent) {
        isSelectingTextForCurrentGesture = true
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if event.modifierFlags.contains(.command), !isSelectingTextForCurrentGesture {
            pendingLinkClickRowText = terminalRowText(at: event)
        }
        defer {
            pendingLinkClickRowText = nil
            isSelectingTextForCurrentGesture = false
        }
        super.mouseUp(with: event)
    }

    func focusWhenPossible() {
        guard let window else {
            shouldFocusWhenAttachedToWindow = true
            return
        }
        shouldFocusWhenAttachedToWindow = false
        window.makeFirstResponder(self)
    }

    func setPaneActive(_ isActive: Bool) {
        guard paneIsActive != isActive else { return }
        paneIsActive = isActive
        updateCaretColor()
        needsDisplay = true
    }

    /// Seeds the caret from the system text colours so a view built before its first
    /// `apply(runtimeConfiguration:)` never shows SwiftTerm's accent-coloured default.
    private func applyDefaultCaretColors() {
        caretTextColor = .textBackgroundColor
        updateCaretColor()
    }

    private func updateCaretColor() {
        caretColor = paneIsActive ? themeCaretColor : .clear
    }

    func apply(runtimeConfiguration: TerminalRuntimeConfiguration) {
        font = MyTermTerminalFontResolver.resolve(
            named: runtimeConfiguration.fontName,
            size: runtimeConfiguration.fontSize
        )
        optionAsMetaKey = runtimeConfiguration.optionAsMeta
        emacsWordSelectionEnabled = runtimeConfiguration.emacsWordSelectionEnabled
        changeScrollback(runtimeConfiguration.scrollbackLines)
        getTerminal().setCursorStyle(runtimeConfiguration.appearance.cursor.swiftTermStyle)
        let foreground = runtimeConfiguration.appearance.foreground?.nsColor ?? .textColor
        let background = runtimeConfiguration.appearance.background?.nsColor ?? .textBackgroundColor
        nativeForegroundColor = foreground
        nativeBackgroundColor = background
        // SwiftTerm fills the block caret with `caretColor` and redraws the covered glyph in
        // `caretTextColor`, so tying those to the theme's text and background colours makes the
        // caret an inverse block at full text contrast. Left unset, SwiftTerm defaults the caret
        // to the macOS accent colour, which barely registers against a dark terminal background.
        themeCaretColor = foreground
        caretTextColor = background
        updateCaretColor()
        needsDisplay = true
    }

    func renderedText(maximumCharacters: Int) -> String {
        let terminal = getTerminal()

        // SwiftTerm does not expose the inactive normal buffer line-by-line. Keep
        // the existing behavior while an alternate-screen app is active, but use
        // a bounded tail walk for the normal buffer so snapshotting does not copy
        // and decode the full scrollback on every content change.
        guard !terminal.isCurrentBufferAlternate else {
            let data = terminal.getBufferAsData(kind: .normal)
            let text = String(data: data, encoding: .utf8) ?? ""
            return TerminalOutputSnapshot.plainText(from: text, maximumCharacters: maximumCharacters)
        }

        let buffer = terminal.buffer
        let firstRow = buffer.totalLinesTrimmed
        var rowAfterLast = firstRow + buffer.yDisp + terminal.rows
        while terminal.getScrollInvariantLine(row: rowAfterLast) != nil {
            rowAfterLast += 1
        }

        var lines: [String] = []
        var collectedCharacters = 0
        var row = rowAfterLast - 1
        while row >= firstRow, collectedCharacters < maximumCharacters,
              let line = terminal.getScrollInvariantLine(row: row) {
            let text = line.translateToString(trimRight: true)
            lines.append(text)
            collectedCharacters += text.count + 1
            row -= 1
        }

        let text = lines.reversed().joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        return TerminalOutputSnapshot.plainText(from: text, maximumCharacters: maximumCharacters)
    }

    func presentPersistedOutput(_ output: String, maximumCharacters: Int = 8_192) {
        let prelude = TerminalOutputSnapshot.plainText(from: output, maximumCharacters: maximumCharacters)
        guard !prelude.isEmpty else { return }
        feed(text: prelude)
    }

    nonisolated static func isShellWordSelectionEditing(
        isAlternateScreen: Bool,
        childFileDescriptor: Int32,
        shellProcessID: pid_t,
        foregroundProcessGroup: pid_t,
        shellProcessGroup: pid_t
    ) -> Bool {
        !isAlternateScreen
            && childFileDescriptor >= 0
            && shellProcessID > 0
            && foregroundProcessGroup > 0
            && shellProcessGroup > 0
            && foregroundProcessGroup == shellProcessGroup
    }

    private func isShellWordSelectionEditing() -> Bool {
        if onPersistentInput != nil {
            return !getTerminal().isCurrentBufferAlternate && persistentShellIsForeground
        }
        let childFileDescriptor = process.childfd
        let shellProcessID = process.shellPid
        guard !getTerminal().isCurrentBufferAlternate,
              childFileDescriptor >= 0,
              shellProcessID > 0 else {
            return false
        }
        return Self.isShellWordSelectionEditing(
            isAlternateScreen: false,
            childFileDescriptor: childFileDescriptor,
            shellProcessID: shellProcessID,
            foregroundProcessGroup: tcgetpgrp(childFileDescriptor),
            shellProcessGroup: getpgid(shellProcessID)
        )
    }

    private func installKeyEventMonitor() {
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window?.firstResponder === self else { return event }
            let input = TerminalInputEvent(
                keyCode: event.keyCode,
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                modifiers: TerminalInputModifiers(event.modifierFlags)
            )
            let kittyKeyboardEnabled = !self.getTerminal().keyboardEnhancementFlags.isEmpty
            if let sequence = self.wordSelectionInput.sequence(
                for: input,
                kittyKeyboardEnabled: kittyKeyboardEnabled,
                normalShellEditing: self.isShellWordSelectionEditing(),
                emacsLineEditing: self.emacsWordSelectionEnabled,
                cursorPosition: self.terminalInputCursorPosition(),
                characterDistance: self.terminalInputCharacterDistance
            ) {
                self.send(sequence)
                self.scheduleWordSelectionResolutionIfNeeded()
                return nil
            }
            let shouldInspectPasteboard = input.keyCode == 9 && input.modifiers.meaningful == [.command]
            guard let sequence = TerminalInputTranslator.sequence(
                for: input,
                kittyKeyboardEnabled: kittyKeyboardEnabled,
                clipboardContainsImage: shouldInspectPasteboard && TerminalPasteboard.containsImage(in: .general)
            ) else {
                return event
            }
            self.send(sequence)
            return nil
        }
    }

    private func scheduleWordSelectionResolutionIfNeeded() {
        wordSelectionResolutionGeneration &+= 1
        guard wordSelectionInput.hasPendingMovement else { return }
        let generation = wordSelectionResolutionGeneration

        Task { @MainActor [weak self] in
            // A shell emits no cursor response when a word motion hits the
            // input boundary. Wait briefly for a real response, then resolve
            // that silent boundary motion so later selection keys can proceed.
            try? await Task.sleep(for: .milliseconds(200))
            guard let self,
                  self.wordSelectionResolutionGeneration == generation,
                  self.wordSelectionInput.hasPendingMovement else {
                return
            }
            self.resolveTimedOutWordSelectionMovement()
        }
    }

    private func resolveTimedOutWordSelectionMovement() {
        let position = terminalInputCursorPosition()
        if let pendingInput = wordSelectionInput.observeCursorPosition(
            position,
            characterDistance: terminalInputCharacterDistance
        ) {
            send(pendingInput)
            scheduleWordSelectionResolutionIfNeeded()
            return
        }
        guard wordSelectionInput.hasPendingMovement else {
            scheduleWordSelectionResolutionIfNeeded()
            return
        }
        if let pendingInput = wordSelectionInput.resolvePendingMovementAsNoOp(at: position) {
            send(pendingInput)
        }
        scheduleWordSelectionResolutionIfNeeded()
    }

    private func terminalInputCursorPosition() -> TerminalInputCursorPosition {
        let terminal = getTerminal()
        let buffer = terminal.buffer
        return .live(
            column: buffer.x,
            row: buffer.y,
            lineCount: terminalBufferLineCount(terminal),
            viewportRows: terminal.rows
        )
    }

    /// SwiftTerm exposes the live cursor relative to `yBase`, but keeps `yBase`
    /// internal. Derive it from the active buffer's current line count instead
    /// of using `yDisp`, which points at scrollback while the user is scrolled up.
    private func terminalBufferLineCount(_ terminal: Terminal) -> Int {
        let buffer = terminal.buffer
        let firstRow = buffer.totalLinesTrimmed
        var lowerBound = firstRow
        var upperBound = firstRow + buffer.getCorrectBufferLength(terminal.rows)

        while lowerBound < upperBound {
            let row = lowerBound + (upperBound - lowerBound) / 2
            if terminal.getScrollInvariantLine(row: row) == nil {
                upperBound = row
            } else {
                lowerBound = row + 1
            }
        }

        return lowerBound - firstRow
    }

    private func terminalInputCharacterDistance(
        from first: TerminalInputCursorPosition,
        to second: TerminalInputCursorPosition
    ) -> Int {
        getTerminal().getText(
            start: Position(col: first.column, row: first.row),
            end: Position(col: second.column, row: second.row)
        ).count
    }

    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard !isSelectingTextForCurrentGesture else { return }
        guard let url = TerminalLinkRouter.url(
            from: link,
            clickedRowText: pendingLinkClickRowText,
            workingDirectory: currentWorkingDirectory
        ) else {
            if let url = TerminalLinkRouter.externalURL(from: link) {
                super.requestOpenLink(source: source, link: url.absoluteString, params: params)
            }
            return
        }
        onOpenWebURL?(url)
    }

    private func terminalRowText(at event: NSEvent) -> String? {
        let terminal = getTerminal()
        guard terminal.rows > 0,
              let cellSize = cellSizeInPixels(source: terminal),
              cellSize.height > 0 else {
            return nil
        }

        let backingScale = max(window?.backingScaleFactor ?? 1, 1)
        let cellHeight = CGFloat(cellSize.height) / backingScale
        let localPoint = convert(event.locationInWindow, from: nil)
        let screenRow = min(
            max(Int((bounds.height - localPoint.y) / cellHeight), 0),
            terminal.rows - 1
        )
        let bufferRow = screenRow + terminal.buffer.yDisp
        return terminal.getText(
            start: Position(col: 0, row: bufferRow),
            end: Position(col: terminal.cols, row: bufferRow)
        )
    }
}

@MainActor
private final class RemoteControlBannerView: NSVisualEffectView {
    var takeControl: (@MainActor () -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8

        let label = NSTextField(labelWithString: "Input is paused on this Mac")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = .labelColor
        let button = NSButton(title: "Take Control", target: self, action: #selector(takeControlPressed))
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .rounded
        addSubview(label)
        addSubview(button)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 8),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    @objc private func takeControlPressed() {
        takeControl?()
    }
}

enum TerminalPasteboard {
    static func containsImage(in pasteboard: NSPasteboard) -> Bool {
        if pasteboard.availableType(from: [.png, .tiff]) != nil {
            return true
        }

        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] else {
            return false
        }
        return fileURLs.contains { url in
            guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
            return type.conforms(to: .image)
        }
    }
}

private extension TerminalInputModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        var modifiers: TerminalInputModifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.capsLock) { modifiers.insert(.capsLock) }
        if flags.contains(.numericPad) { modifiers.insert(.numericPad) }
        self = modifiers
    }
}

private enum MyTermTerminalFontResolver {
    static func resolve(named name: String?, size: Double) -> NSFont {
        let resolvedSize = max(CGFloat(size), 1)
        if let name, let font = NSFont(name: name, size: resolvedSize) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: resolvedSize, weight: .regular)
    }
}

private extension TerminalColor {
    var nsColor: NSColor {
        NSColor(
            red: CGFloat(red) / CGFloat(UInt16.max),
            green: CGFloat(green) / CGFloat(UInt16.max),
            blue: CGFloat(blue) / CGFloat(UInt16.max),
            alpha: 1
        )
    }
}

private extension TerminalCursorConfiguration {
    var swiftTermStyle: CursorStyle {
        switch (shape, blinks) {
        case (.block, true): .blinkBlock
        case (.block, false): .steadyBlock
        case (.underline, true): .blinkUnderline
        case (.underline, false): .steadyUnderline
        case (.bar, true): .blinkBar
        case (.bar, false): .steadyBar
        }
    }
}

extension SwiftTermTerminalSession: @preconcurrency LocalProcessTerminalViewDelegate {
    public func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        recordRemoteGeometry(columns: newCols, rows: newRows)
    }

    public func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        onEvent?(.titleChanged(title))
    }

    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let workingDirectory = TerminalWorkingDirectoryNormalizer.normalize(directory) else { return }
        emitWorkingDirectoryChanged(workingDirectory)
    }

    public func processTerminated(source: TerminalView, exitCode: Int32?) {
        emitTermination(exitCode: exitCode)
    }
}
