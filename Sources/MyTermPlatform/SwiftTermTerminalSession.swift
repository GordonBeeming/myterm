import AppKit
import Foundation
@preconcurrency import SwiftTerm

@MainActor
public final class SwiftTermTerminalEngine: TerminalEngine {
    public init() {}

    public func makeSession(configuration: TerminalSessionConfiguration) throws -> any TerminalProcessSession {
        try SwiftTermTerminalSession(configuration: configuration)
    }
}

@MainActor
public final class SwiftTermTerminalSession: NSObject, TerminalProcessSession {
    public private(set) var isRunning = false
    public var onEvent: (@MainActor (TerminalSessionEvent) -> Void)?

    private let configuration: TerminalSessionConfiguration
    private let terminal: MyTermLocalProcessTerminalView
    private var workingDirectoryPoller: ProcessWorkingDirectoryPoller?
    private var lastReportedWorkingDirectory: URL?
    private var didTerminate = false

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
        lastReportedWorkingDirectory = configuration.workingDirectory
        terminal = MyTermLocalProcessTerminalView(frame: .zero)
        super.init()

        terminal.processDelegate = self
        terminal.onOpenWebURL = { [weak self] url in
            self?.onEvent?(.openURL(url))
        }
        terminal.autoresizingMask = [.width, .height]
    }

    public func terminalView() -> NSView {
        terminal
    }

    public func start() throws {
        guard !isRunning else { return }

        didTerminate = false
        terminal.startProcess(
            executable: configuration.shell.path,
            args: ["-l"],
            environment: Self.processEnvironment(overrides: configuration.environment),
            execName: "-\(configuration.shell.lastPathComponent)",
            currentDirectory: configuration.workingDirectory.path
        )

        guard terminal.process.running else {
            let failure = TerminalSessionFailure(message: "The terminal process could not start.")
            onEvent?(.failed(failure))
            throw failure
        }
        isRunning = true
        if let command = configuration.initialCommand, !command.isEmpty {
            terminal.send(txt: command + "\n")
        }
        workingDirectoryPoller = ProcessWorkingDirectoryPoller(
            processID: terminal.process.shellPid,
            provider: MacOSProcessWorkingDirectoryProvider(),
            onDirectoryChanged: { [weak self] directory in
                Task { @MainActor [weak self] in
                    self?.emitWorkingDirectoryChanged(directory)
                }
            }
        )
        workingDirectoryPoller?.start(initialDirectory: configuration.workingDirectory)
    }

    public func resize(columns: Int, rows: Int) {
        guard columns > 0, rows > 0 else {
            onEvent?(.failed(TerminalSessionFailure(message: "Terminal dimensions must be positive.")))
            return
        }

        terminal.getTerminal().resize(cols: columns, rows: rows)
        terminal.sizeChanged(source: terminal, newCols: columns, newRows: rows)
        terminal.needsDisplay = true
    }

    public func focus() {
        guard let window = terminal.window else { return }
        window.makeFirstResponder(terminal)
    }

    public func terminate() {
        guard isRunning else { return }
        stopWorkingDirectoryPolling()
        terminal.terminate()
    }

    private func emitTermination(exitCode: Int32?) {
        guard !didTerminate else { return }
        didTerminate = true
        stopWorkingDirectoryPolling()
        isRunning = false
        if exitCode == nil {
            onEvent?(.failed(TerminalSessionFailure(message: "The terminal process ended before reporting an exit code.")))
        }
        onEvent?(.processTerminated(exitCode: exitCode))
    }

    private func emitWorkingDirectoryChanged(_ directory: URL) {
        guard isRunning, directory != lastReportedWorkingDirectory else { return }
        lastReportedWorkingDirectory = directory
        workingDirectoryPoller?.updateCurrentDirectory(directory)
        onEvent?(.workingDirectoryChanged(directory))
    }

    private func stopWorkingDirectoryPolling() {
        workingDirectoryPoller?.stop()
        workingDirectoryPoller = nil
    }

    private static func processEnvironment(overrides: [String: String]) -> [String] {
        var values = [String: String]()
        for entry in Terminal.getEnvironmentVariables(termName: "xterm-256color") {
            let pair = entry.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            values[pair[0]] = pair[1]
        }
        values.merge(overrides) { _, override in override }
        return values.keys.sorted().compactMap { key in values[key].map { "\(key)=\($0)" } }
    }
}

@MainActor
private final class MyTermLocalProcessTerminalView: LocalProcessTerminalView {
    var onOpenWebURL: ((URL) -> Void)?

    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = TerminalLinkRouter.webURL(from: link) else {
            super.requestOpenLink(source: source, link: link, params: params)
            return
        }
        onOpenWebURL?(url)
    }
}

extension SwiftTermTerminalSession: @preconcurrency LocalProcessTerminalViewDelegate {
    public func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

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
