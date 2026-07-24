import AppKit
import Darwin
import Foundation
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
public final class SwiftTermTerminalSession: NSObject, TerminalProcessSession {
    public private(set) var isRunning = false
    public var onEvent: (@MainActor (TerminalSessionEvent) -> Void)?

    public var activeForegroundProcessName: String? {
        guard isRunning,
              terminal.process.childfd >= 0,
              terminal.process.shellPid > 0 else { return nil }
        let foregroundProcessGroup = tcgetpgrp(terminal.process.childfd)
        let shellProcessGroup = getpgid(terminal.process.shellPid)
        guard foregroundProcessGroup > 0,
              shellProcessGroup > 0,
              foregroundProcessGroup != shellProcessGroup else { return nil }

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

    private let configuration: TerminalSessionConfiguration
    private let terminal: MyTermLocalProcessTerminalView
    private var workingDirectoryPoller: ProcessWorkingDirectoryPoller?
    private var lastReportedWorkingDirectory: URL?
    private var didTerminate = false
    private var contentChangeHandler: (@MainActor () -> Void)?

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
        terminal = MyTermLocalProcessTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 480)
        )
        super.init()

        terminal.processDelegate = self
        terminal.onOpenWebURL = { [weak self] url in
            Task { @MainActor [weak self] in
                self?.onEvent?(.openURL(url))
            }
        }
        terminal.onContentChanged = { [weak self] in
            self?.contentChangeHandler?()
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
        terminal.focusWhenPossible()
    }

    public func terminate() {
        guard isRunning else { return }
        stopWorkingDirectoryPolling()
        let foregroundProcessGroup = tcgetpgrp(terminal.process.childfd)
        let shellProcessGroup = getpgid(terminal.process.shellPid)
        if foregroundProcessGroup > 0,
           shellProcessGroup > 0,
           foregroundProcessGroup != shellProcessGroup {
            _ = kill(-foregroundProcessGroup, SIGHUP)
        }
        terminal.terminate()
    }

    public func apply(runtimeConfiguration: TerminalRuntimeConfiguration) {
        terminal.apply(runtimeConfiguration: runtimeConfiguration)
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
final class MyTermLocalProcessTerminalView: LocalProcessTerminalView {
    var onOpenWebURL: ((URL) -> Void)?
    var onContentChanged: (() -> Void)?
    private let contentChangeCoalescer = TerminalContentChangeCoalescer()
    // AppKit owns local monitor tokens and requires the opaque value again for removal.
    // The view is main-actor isolated, while Swift 6 treats deinit as nonisolated.
    nonisolated(unsafe) private var keyEventMonitor: Any?
    private var shouldFocusWhenAttachedToWindow = false
    private var paneIsActive = true
    private var activeCaretColor: NSColor?
    private var wordSelectionInput = TerminalWordSelectionInputState()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        installKeyEventMonitor()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        installKeyEventMonitor()
    }

    deinit {
        if let keyEventMonitor {
            NSEvent.removeMonitor(keyEventMonitor)
        }
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        let originalMouseReporting = allowMouseReporting
        if selectionActive {
            allowMouseReporting = false
        }
        defer { allowMouseReporting = originalMouseReporting }

        super.dataReceived(slice: slice)
        contentChangeCoalescer.notify { [weak self] in
            self?.onContentChanged?()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, shouldFocusWhenAttachedToWindow else { return }
        focusWhenPossible()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
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
        if isActive {
            caretColor = activeCaretColor ?? .selectedControlColor
            activeCaretColor = nil
        } else {
            activeCaretColor = caretColor
            caretColor = .clear
        }
        needsDisplay = true
    }

    func apply(runtimeConfiguration: TerminalRuntimeConfiguration) {
        font = MyTermTerminalFontResolver.resolve(
            named: runtimeConfiguration.fontName,
            size: runtimeConfiguration.fontSize
        )
        optionAsMetaKey = runtimeConfiguration.optionAsMeta
        changeScrollback(runtimeConfiguration.scrollbackLines)
        getTerminal().setCursorStyle(runtimeConfiguration.appearance.cursor.swiftTermStyle)
        nativeForegroundColor = runtimeConfiguration.appearance.foreground?.nsColor ?? .textColor
        nativeBackgroundColor = runtimeConfiguration.appearance.background?.nsColor ?? .textBackgroundColor
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
                normalShellEditing: self.isShellWordSelectionEditing()
            ) {
                self.send(sequence)
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

    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = TerminalLinkRouter.url(from: link) else {
            super.requestOpenLink(source: source, link: link, params: params)
            return
        }
        onOpenWebURL?(url)
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
