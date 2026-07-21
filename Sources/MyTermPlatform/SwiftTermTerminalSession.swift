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
    private let terminal: LocalProcessTerminalView
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
        terminal = LocalProcessTerminalView(frame: .zero)
        super.init()

        terminal.processDelegate = self
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
            execName: "-\(configuration.shell.lastPathComponent)",
            currentDirectory: configuration.workingDirectory.path
        )

        guard terminal.process.running else {
            let failure = TerminalSessionFailure(message: "The terminal process could not start.")
            onEvent?(.failed(failure))
            throw failure
        }
        isRunning = true
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
        terminal.terminate()
    }

    private func emitTermination(exitCode: Int32?) {
        guard !didTerminate else { return }
        didTerminate = true
        isRunning = false
        if exitCode == nil {
            onEvent?(.failed(TerminalSessionFailure(message: "The terminal process ended before reporting an exit code.")))
        }
        onEvent?(.processTerminated(exitCode: exitCode))
    }
}

extension SwiftTermTerminalSession: @preconcurrency LocalProcessTerminalViewDelegate {
    public func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    public func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        onEvent?(.titleChanged(title))
    }

    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let workingDirectory = TerminalWorkingDirectoryNormalizer.normalize(directory) else { return }
        onEvent?(.workingDirectoryChanged(workingDirectory))
    }

    public func processTerminated(source: TerminalView, exitCode: Int32?) {
        emitTermination(exitCode: exitCode)
    }
}
