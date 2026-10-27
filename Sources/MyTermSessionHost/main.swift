import AppKit
import Darwin
import Foundation
import MyTermContinuity
import MyTermCore
import OSLog
@preconcurrency import SwiftTerm

@MainActor
final class SessionHost: @preconcurrency LocalProcessDelegate, @preconcurrency TerminalDelegate {
    private var listener: Int32 = -1
    private let controllerAuthentication: SessionHostClientAuthentication
    private var client: Int32 = -1
    private var clientIdentity = UUID()
    private var listenerSource: DispatchSourceRead?
    private var clientSource: DispatchSourceRead?
    private var rejectedClients: [Int32: (identity: UUID, source: DispatchSourceRead)] = [:]
    private var hasDelayedFixtureRead = false
    private var outputSource: DispatchSourceWrite?
    private var outputIdleTimer: DispatchSourceTimer?
    private var pendingOutput: [Data?] = []
    private var outputFrameIndex = 0
    private var outputFrameOffset = 0
    private var pendingOutputBytes = 0
    private var closingClient = false
    // One maximum-sized checkpoint plus ordinary output fits, with bounded memory even
    // when a controller stops reading. Overflow detaches it; the host retains its state.
    private let maximumPendingOutputBytes = 64 * 1_024 * 1_024
    private var finishing = false
    private var decoder = SessionHostDecoder()
    private let initialColumns: Int
    private let initialRows: Int
    private let shellName: String
    private let ownershipDescriptor: Int32
    private lazy var emulator: Terminal = {
        var options = TerminalOptions.default
        options.cols = initialColumns; options.rows = initialRows
        let configured = Int(ProcessInfo.processInfo.environment["MYTERM_PERSISTENT_SCROLLBACK_LINES"] ?? "5000") ?? 5_000
        options.scrollback = min(max(configured, 0), 100_000)
        options.kittyImageCacheLimitBytes = 8 * 1_024 * 1_024
        let terminal = Terminal(delegate: self, options: options)
        terminal.registerOscHandler(code: 7338) { [weak self] bytes in
            self?.readyToken = String(bytes: bytes, encoding: .utf8)
        }
        terminal.registerOscHandler(code: AgentActivityMarker.oscCode) { [weak self] bytes in
            guard let payload = String(bytes: bytes, encoding: .utf8),
                  let report = AgentActivityMarker.report(fromPayload: payload) else { return }
            self?.recordActivity(report)
        }
        return terminal
    }()
    private lazy var process = LocalProcess(delegate: self, deliversTerminationAfterOutput: true)
    private let path: String
    private let generation = UUID()
    private var sequence: UInt64 = 0
    private var stopping = false
    private var stopReason: String?
    private var awaitingGroupCleanup = false
    private var completionDeferred = false
    private var readyToken: String?
    private var inputSource: DispatchSourceWrite?
    private var terminationSource: DispatchSourceSignal?
    private var pendingInput = Data()
    private var foregroundTimer: Timer?
    private var lastForegroundName: String?
    private var clientHasOmittedHistory = false
    private var pendingGeometry: (columns: Int, rows: Int, imageGeometry: SessionHostImageGeometry?)?
    private var imageGeometry: SessionHostImageGeometry
    private var geometryFlushScheduled = false
    private var latestActivity: AgentActivityReport?
    private var pendingActivities: [String: [AgentActivityReport]] = [:]
    private let logger = Logger(subsystem: "com.gordonbeeming.myterm.session-host", category: "lifecycle")

    init(path: String, shell: String, arguments: [String], directory: String, columns: Int, rows: Int) throws {
        guard let encodedGeometry = ProcessInfo.processInfo.environment["MYTERM_PERSISTENT_IMAGE_GEOMETRY"],
              let geometryBytes = Data(base64Encoded: encodedGeometry),
              let measuredGeometry = try? JSONDecoder().decode(SessionHostImageGeometry.self, from: geometryBytes),
              measuredGeometry.isValid else { throw SessionHostError.invalidFrame }
        self.imageGeometry = measuredGeometry
        self.path = path
        controllerAuthentication = try SessionHostClientAuthentication()
        self.initialColumns = columns
        self.initialRows = rows
        self.shellName = URL(fileURLWithPath: shell).resolvingSymlinksInPath().lastPathComponent
        try SessionHostSocket.prepareDirectory(URL(fileURLWithPath: path).deletingLastPathComponent())
        ownershipDescriptor = try SessionHostSocket.acquireOwnership(path: path + ".lock")
        // The lifetime lock is acquired before removing a stale endpoint. A host between bind
        // and listen, or with a full socket backlog, can never be replaced by a second shell.
        if unlink(path) != 0, errno != ENOENT { throw SessionHostError.system("remove stale endpoint", errno) }
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw SessionHostError.system("socket", errno) }
        try SessionHostSocket.configure(listener)
        var address = try SessionHostSocket.address(path: path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw SessionHostError.system("bind", errno) }
        guard chmod(path, 0o600) == 0, listen(listener, 4) == 0 else { throw SessionHostError.system("listen", errno) }
        var environment = ProcessInfo.processInfo.environment
        environment["MYTERM_STARTUP_PARENT_PID"] = String(getpid())
        process.startProcess(executable: shell, args: arguments,
                             environment: environment.map { "\($0.key)=\($0.value)" },
                             execName: "-\(URL(fileURLWithPath: shell).lastPathComponent)", currentDirectory: directory)
        guard process.running else { throw SessionHostError.system("shell", errno) }
        // Install after spawning the shell, so interactive programs retain their normal
        // signal dispositions. The helper's SIGTERM deliberately means stop, never detach.
        terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        terminationSource?.setEventHandler { [weak self] in
            // A kqueue signal source cannot report the sender, so the parent is the best lead.
            MainActor.assumeIsolated { self?.stop(reason: "received SIGTERM (parent pid \(getppid()))") }
        }
        terminationSource?.resume()
        signal(SIGTERM, SIG_IGN)
        let flags = fcntl(process.childfd, F_GETFL)
        guard flags >= 0, fcntl(process.childfd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw SessionHostError.system("nonblocking terminal", errno)
        }
        listenerSource = DispatchSource.makeReadSource(fileDescriptor: listener, queue: .main)
        listenerSource?.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.acceptClient() } }
        listenerSource?.resume()
        foregroundTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportForeground() }
        }
    }

    private func acceptClient() {
        let descriptor = accept(listener, nil, nil)
        guard descriptor >= 0 else { return }
        do {
            try SessionHostSocket.configure(descriptor)
            try controllerAuthentication.authenticate(descriptor)
            guard !stopping else {
                try rejectClient(descriptor, message: .init(kind: "error", text: "This terminal is stopping. Try again after it exits."))
                return
            }
            guard client < 0 else {
                try rejectClient(descriptor, message: .init(kind: "busy", text: "This terminal already has an attached controller."))
                return
            }
            try flushPendingGeometry()
            reportForeground()
            client = descriptor
            clientIdentity = UUID()
            let identity = clientIdentity
            decoder = SessionHostDecoder()
            let checkpoint = try emulator.exportBoundedCheckpoint()
            clientHasOmittedHistory = checkpoint.omittedScrollbackLines > 0
            try SessionHostSocket.write(.init(kind: "attached", bytes: checkpoint.bytes, pid: process.shellPid,
                                              columns: emulator.cols, rows: emulator.rows,
                                              generation: generation, sequence: sequence, text: readyToken,
                                              activity: latestActivity,
                                              pendingActivities: pendingActivities.values.flatMap { $0 },
                                              omittedScrollbackLines: checkpoint.omittedScrollbackLines, imageGeometry: imageGeometry), to: descriptor)
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw SessionHostError.system("nonblocking controller", errno)
            }
            clientSource = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
            clientSource?.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    guard self?.client == descriptor, self?.clientIdentity == identity else { return }
                    self?.readClient()
                }
            }
            #if DEBUG
            if controllerAuthentication.usesTestHarnessIdentity, !hasDelayedFixtureRead,
               ProcessInfo.processInfo.environment["MYTERM_TEST_DELAY_FIRST_CLIENT_READ"] == "1",
               let source = clientSource {
                hasDelayedFixtureRead = true
                // Scheduler fault injection for the real helper/PTY regression: let output
                // observe peer closure before the first controller read. Retain and resume
                // even a cancelled source so teardown cannot release a suspended source.
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) { source.resume() }
            } else { clientSource?.resume() }
            #else
            clientSource?.resume()
            #endif
            reportForeground(force: true)
        } catch {
            log(error)
            if client == descriptor { disconnect() } else { close(descriptor) }
        }
    }

    private func readClient() {
        var bytes = [UInt8](repeating: 0, count: 64 * 1_024)
        let count = read(client, &bytes, bytes.count)
        if count < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { return }
        guard count > 0 else { disconnect(); return }
        guard !closingClient, !finishing else { return }
        do {
            for message in try decoder.append(Data(bytes.prefix(count))) {
                switch message.kind {
                case "input":
                    guard let bytes = message.bytes,
                          bytes.count <= SessionHostMessage.maximumInputBytes,
                          message.generation == generation else { throw SessionHostError.invalidFrame }
                    if bytes.isEmpty { continue }
                    try flushPendingGeometry()
                    try writeInput(bytes)
                case "resize":
                    guard let columns = message.columns, let rows = message.rows,
                          (2...1_024).contains(columns), (1...1_024).contains(rows),
                          columns * rows <= SessionHostGeometry.maximumCellsPerBuffer,
                          message.generation == generation else { throw SessionHostError.invalidFrame }
                    if let geometry = message.imageGeometry, !geometry.isValid { throw SessionHostError.invalidFrame }
                    if clientHasOmittedHistory {
                        pendingGeometry = (columns, rows, message.imageGeometry)
                        scheduleGeometryFlush()
                    } else { try applyGeometry(columns: columns, rows: rows, imageGeometry: message.imageGeometry) }
                case "stop":
                    guard message.generation == generation else { throw SessionHostError.invalidFrame }
                    stop(reason: "MyTerm asked this terminal to stop")
                case "configure":
                    guard let lines = message.scrollbackLines, (0...100_000).contains(lines),
                          message.generation == generation else { throw SessionHostError.invalidFrame }
                    if let geometry = message.imageGeometry {
                        guard geometry.isValid else { throw SessionHostError.invalidFrame }
                        if var pending = pendingGeometry {
                            pending.imageGeometry = geometry
                            pendingGeometry = pending
                            self.imageGeometry = geometry
                        } else if imageGeometry != geometry {
                            try applyGeometry(columns: emulator.cols, rows: emulator.rows, imageGeometry: geometry)
                        }
                    }
                    emulator.changeScrollback(lines)
                case "detach": disconnect()
                default: throw SessionHostError.invalidFrame
                }
            }
        } catch {
            log(error)
            sendToClient(.init(kind: "error", text: error.localizedDescription))
            closeAfterFlushingOutput()
        }
    }

    private func scheduleGeometryFlush() {
        guard !geometryFlushScheduled else { return }
        geometryFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.geometryFlushScheduled = false
                do { try self.flushPendingGeometry() }
                catch {
                    self.log(error)
                    self.sendToClient(.init(kind: "error", text: error.localizedDescription))
                    self.closeAfterFlushingOutput()
                }
            }
        }
    }

    private func flushPendingGeometry() throws {
        guard let geometry = pendingGeometry else { return }
        pendingGeometry = nil
        guard !stopping else { return }
        try applyGeometry(columns: geometry.columns, rows: geometry.rows, imageGeometry: geometry.imageGeometry)
    }

    private func applyGeometry(columns: Int, rows: Int, imageGeometry: SessionHostImageGeometry? = nil) throws {
        if let imageGeometry { self.imageGeometry = imageGeometry }
        let changed = emulator.cols != columns || emulator.rows != rows
        emulator.resize(cols: columns, rows: rows)
        var size = getWindowSize()
        guard ioctl(process.childfd, TIOCSWINSZ, &size) == 0 else { throw SessionHostError.system("resize", errno) }
        // Reflow needs any omitted prefix of a wrapped logical line. Only the host has
        // that prefix, so an elided attachment receives an authoritative bounded result.
        let checkpoint = changed && client >= 0 && clientHasOmittedHistory
            ? try emulator.exportBoundedCheckpoint() : nil
        if let checkpoint { clientHasOmittedHistory = checkpoint.omittedScrollbackLines > 0 }
        sequence &+= 1
        sendToClient(.init(kind: "geometry", bytes: checkpoint?.bytes, columns: columns, rows: rows,
                           generation: generation, sequence: sequence,
                           omittedScrollbackLines: checkpoint?.omittedScrollbackLines, imageGeometry: imageGeometry))
    }

    private func writeInput(_ bytes: Data) throws {
        guard !stopping, process.running else {
            sendToClient(.init(kind: "inputError", text: "This terminal process is stopping and did not accept the input."))
            return
        }
        guard pendingInput.count + bytes.count <= SessionHostMessage.maximumInputBytes else {
            sendToClient(.init(kind: "inputError", text: "Terminal input is full because the foreground process is not reading. This input was not queued; try again after it resumes."))
            return
        }
        pendingInput.append(bytes)
        if inputSource == nil {
            inputSource = DispatchSource.makeWriteSource(fileDescriptor: process.childfd, queue: .main)
            inputSource?.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.drainInput() } }
            inputSource?.resume()
        }
    }

    private func drainInput() {
        guard process.running, !stopping else { cancelInput(); return }
        var budget = 64 * 1_024
        while !pendingInput.isEmpty, budget > 0 {
            let count = pendingInput.withUnsafeBytes { bytes in
                Darwin.write(process.childfd, bytes.baseAddress, min(bytes.count, budget))
            }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { return }
            guard count > 0 else {
                let error = SessionHostError.system("input (a prefix may have reached the process)", errno)
                log(error)
                sendToClient(.init(kind: "inputError", text: error.localizedDescription))
                cancelInput()
                return
            }
            pendingInput.removeFirst(count)
            budget -= count
        }
        if pendingInput.isEmpty { cancelInput() }
    }

    private func cancelInput() {
        inputSource?.cancel(); inputSource = nil
        pendingInput.removeAll(keepingCapacity: true)
    }

    private func sendToClient(_ message: SessionHostMessage) {
        guard client >= 0, !closingClient, !finishing || message.kind == "exited" else { return }
        do {
            let frame = try message.encoded()
            guard pendingOutputBytes + frame.count <= maximumPendingOutputBytes else {
                throw SessionHostError.system("controller output queue full; reattach to restore terminal state", ENOBUFS)
            }
            pendingOutput.append(frame)
            pendingOutputBytes += frame.count
            if outputSource == nil {
                let descriptor = client
                let identity = clientIdentity
                outputSource = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: .main)
                outputSource?.setEventHandler { [weak self] in
                    MainActor.assumeIsolated {
                        guard self?.client == descriptor, self?.clientIdentity == identity else { return }
                        self?.drainOutput()
                    }
                }
                outputSource?.resume()
            }
        }
        catch { log(error); disconnect() }
    }

    private func drainOutput() {
        var budget = 64 * 1_024
        var madeProgress = false
        defer {
            if madeProgress, pendingOutputBytes > 0, finishing || closingClient { scheduleOutputIdleDeadline() }
        }
        while client >= 0, pendingOutputBytes > 0, budget > 0 {
            guard let frame = pendingOutput[outputFrameIndex] else { return }
            let count = frame.withUnsafeBytes { bytes in
                Darwin.write(client, bytes.baseAddress?.advanced(by: outputFrameOffset), min(bytes.count - outputFrameOffset, budget))
            }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { return }
            guard count > 0 else {
                log(SessionHostError.system("controller output", errno))
                disconnect()
                return
            }
            outputFrameOffset += count
            madeProgress = true
            pendingOutputBytes -= count
            budget -= count
            if outputFrameOffset == frame.count {
                pendingOutput[outputFrameIndex] = nil
                outputFrameIndex += 1
                outputFrameOffset = 0
                if outputFrameIndex >= 64 {
                    pendingOutput.removeFirst(outputFrameIndex)
                    outputFrameIndex = 0
                }
            }
        }
        if pendingOutputBytes == 0 {
            pendingOutput = []; outputFrameIndex = 0; outputFrameOffset = 0
            outputSource?.cancel(); outputSource = nil
            if finishing { completeFinish() }
            if closingClient { disconnect() }
        }
    }

    private func closeAfterFlushingOutput() {
        closingClient = true
        guard pendingOutputBytes > 0 else { disconnect(); return }
        scheduleOutputIdleDeadline()
    }

    private func scheduleOutputIdleDeadline() {
        if outputIdleTimer == nil {
            let identity = clientIdentity
            outputIdleTimer = DispatchSource.makeTimerSource(queue: .main)
            outputIdleTimer?.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.clientIdentity == identity else { return }
                    if self.finishing { self.completeFinish() }
                    else { self.disconnect() }
                }
            }
            outputIdleTimer?.resume()
        }
        outputIdleTimer?.schedule(deadline: .now() + 3)
    }

    private func reportForeground(force: Bool = false) {
        let foreground = tcgetpgrp(process.childfd)
        let shellGroup = getpgid(process.shellPid)
        var name: String?
        if foreground > 0, foreground != shellGroup {
            name = processName(foreground) ?? "Unknown foreground process"
        } else if foreground > 0, foreground == shellGroup {
            if processName(process.shellPid) == shellName {
                latestActivity = nil
                pendingActivities.removeAll()
            } else {
                // `exec agent` retains the shell's PID and process group. Its validated hook
                // remains authoritative until that process exits, even with no separate group.
                name = processName(process.shellPid)
            }
        }
        guard force || name != lastForegroundName else { return }
        lastForegroundName = name
        sendToClient(.init(kind: "foreground", text: name))
    }

    private func processName(_ pid: pid_t) -> String? {
        var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = bytes.withUnsafeMutableBytes { proc_name(pid, $0.baseAddress, UInt32($0.count)) }
        guard length > 0 else { return nil }
        return String(decoding: bytes.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func recordActivity(_ report: AgentActivityReport) {
        if report.agent == "codex", let tool = report.toolRequestID {
            switch report.activity {
            case .awaitingInput:
                // A malicious terminal stream cannot grow the detached helper without bound.
                guard pendingActivities.values.reduce(0, { $0 + $1.count }) < 4_096 else {
                    logger.error("Too many pending terminal tool requests; retaining the existing waiting state.")
                    return
                }
                pendingActivities[tool, default: []].append(report)
            case .working:
                if pendingActivities[tool]?.isEmpty == false { pendingActivities[tool]?.removeLast() }
                if pendingActivities[tool]?.isEmpty == true { pendingActivities[tool] = nil }
                if let waiting = pendingActivities.values.first?.first { latestActivity = waiting; return }
            case .ready, .finished, .exited: pendingActivities.removeAll()
            }
        } else if report.activity != .awaitingInput {
            pendingActivities.removeAll()
        }
        latestActivity = report.activity == .exited ? nil : report
    }

    private func disconnect() {
        clientSource?.cancel(); clientSource = nil
        outputSource?.cancel(); outputSource = nil
        outputIdleTimer?.cancel(); outputIdleTimer = nil
        pendingOutput.removeAll(keepingCapacity: false)
        pendingOutputBytes = 0; outputFrameIndex = 0; outputFrameOffset = 0
        closingClient = false
        if client >= 0 { close(client) }
        client = -1
        clientIdentity = UUID()
        if finishing { completeFinish() }
    }

    /// Keep the server endpoint alive while the rejected client authenticates its kernel peer.
    /// Darwin drops LOCAL_PEERTOKEN after peer close even while the busy frame is buffered.
    private func rejectClient(_ descriptor: Int32, message: SessionHostMessage) throws {
        guard rejectedClients.count < 8 else { close(descriptor); return }
        try SessionHostSocket.write(message, to: descriptor)
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw SessionHostError.system("rejected client flags", errno)
        }
        let identity = UUID()
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
        rejectedClients[descriptor] = (identity, source)
        source.setCancelHandler { close(descriptor) }
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.rejectedClients[descriptor]?.identity == identity else { return }
                var byte: UInt8 = 0
                let count = Darwin.read(descriptor, &byte, 1)
                // EOF or unsolicited input closes this rejected connection. No command is decoded.
                if count >= 0 || (errno != EAGAIN && errno != EINTR) {
                    self.closeRejectedClient(descriptor, identity: identity)
                }
            }
        }
        source.resume()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            MainActor.assumeIsolated { self?.closeRejectedClient(descriptor, identity: identity) }
        }
    }

    private func closeRejectedClient(_ descriptor: Int32, identity: UUID) {
        guard let rejected = rejectedClients[descriptor], rejected.identity == identity else { return }
        rejectedClients.removeValue(forKey: descriptor)
        rejected.source.cancel() // The cancel handler closes this exact descriptor once.
    }

    private func log(_ error: Error) {
        logger.error("\(error.localizedDescription, privacy: .public)")
    }

    private func stop(reason: String) {
        guard !stopping else { return }
        stopping = true
        stopReason = reason
        cancelInput()
        let foreground = tcgetpgrp(process.childfd)
        let shellGroup = getpgid(process.shellPid)
        logger.notice("Stopping terminal host: \(reason, privacy: .public); hanging up shell \(self.process.shellPid) and foreground \(self.lastForegroundName ?? "shell", privacy: .public)")
        if foreground > 0, foreground != shellGroup { _ = kill(-foreground, SIGHUP) }
        if shellGroup > 0 { _ = kill(-shellGroup, SIGHUP) }
        // LocalProcess.terminate() cancels the child monitor, which would discard the shell's
        // real exit status. Signal directly and leave terminate() to the deadline below.
        if process.shellPid > 0 { _ = kill(process.shellPid, SIGTERM) }
        // A prompt shell exit must not let the host leave before a job that ignored the
        // hang-up is killed, or that job outlives its deleted pane.
        awaitingGroupCleanup = true
        // An unresponsive process must not leave a deleted pane's host running indefinitely.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if foreground > 0 { _ = kill(-foreground, SIGKILL) }
                if shellGroup > 0 { _ = kill(-shellGroup, SIGKILL) }
                self.awaitingGroupCleanup = false
                if self.finishing {
                    if self.completionDeferred || self.pendingOutputBytes == 0 { self.completeFinish() }
                    return
                }
                // A descendant holding the terminal open delays the delegate past this deadline,
                // but the shell's status may already have been observed.
                let status = self.process.observedExitStatus
                self.process.terminate()
                self.finish(exitCode: status)
            }
        }
    }

    private func finish(exitCode: Int32?) {
        guard !finishing else { return }
        finishing = true
        for (descriptor, rejected) in rejectedClients {
            closeRejectedClient(descriptor, identity: rejected.identity)
        }
        cancelInput()
        listenerSource?.cancel()
        close(listener)
        unlink(path)
        let ending = SessionHostEnding.describe(waitStatus: exitCode, stopReason: stopReason)
        logger.notice("Terminal shell ended: \(ending, privacy: .public)")
        // An ordinary exit needs no explanation; a stop, a signal or a forced kill does.
        let signaled = exitCode.map { $0 & 0x7f != 0 } ?? true
        let explanation = stopReason != nil || signaled ? ending : nil
        sendToClient(.init(kind: "exited", exitCode: exitCode, text: explanation))
        if pendingOutputBytes == 0 { completeFinish() }
        // Preserve a progressing reader's final output; bound inactivity by the former
        // socket send timeout while letting the main queue continue draining.
        scheduleOutputIdleDeadline()
    }

    private func completeFinish() {
        guard !awaitingGroupCleanup else { completionDeferred = true; return }
        exit(0)
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) { finish(exitCode: exitCode) }
    func dataReceived(slice: ArraySlice<UInt8>) {
        emulator.feed(buffer: slice)
        sequence &+= 1
        sendToClient(.init(kind: "output", bytes: Data(slice), generation: generation, sequence: sequence,
                           imageGeometry: imageGeometry))
    }
    private func imageRenderer(for source: Terminal) -> TerminalImageRenderer {
        TerminalImageRenderer(terminal: source, geometry: TerminalImageGeometry(
            cellSize: CGSize(width: imageGeometry.cellWidth, height: imageGeometry.cellHeight),
            viewportSize: CGSize(width: imageGeometry.viewportWidth, height: imageGeometry.viewportHeight),
            displayScale: imageGeometry.displayScale))
    }

    func createImage(source: Terminal, data: Data, width: ImageSizeRequest,
                     height: ImageSizeRequest, preserveAspectRatio: Bool) {
        imageRenderer(for: source).createImage(source: source, data: data, width: width,
                                               height: height, preserveAspectRatio: preserveAspectRatio)
    }

    func createImageFromBitmap(source: Terminal, bytes: inout [UInt8], width: Int, height: Int) {
        imageRenderer(for: source).createImageFromBitmap(source: source, bytes: &bytes, width: width, height: height)
    }

    func getWindowSize() -> winsize {
        let pixelWidth = imageGeometry.cellWidth * imageGeometry.displayScale * Double(emulator.cols)
        let pixelHeight = imageGeometry.cellHeight * imageGeometry.displayScale * Double(emulator.rows)
        return winsize(ws_row: UInt16(emulator.rows), ws_col: UInt16(emulator.cols),
                       ws_xpixel: UInt16(min(65_535, max(0, pixelWidth.rounded()))),
                       ws_ypixel: UInt16(min(65_535, max(0, pixelHeight.rounded()))))
    }
    func send(source: Terminal, data: ArraySlice<UInt8>) {
        // While attached the visible emulator answers queries. Detached sessions still need
        // cursor and capability responses so their foreground applications can keep working.
        guard client < 0 else { return }
        do { try writeInput(Data(data)) }
        catch { log(error); stop(reason: "a reply to the detached terminal could not be written") }
    }
}

let args = CommandLine.arguments
guard args.count >= 6, let columns = Int(args[4]), let rows = Int(args[5]),
      (2...1_024).contains(columns), (1...1_024).contains(rows) else { exit(64) }
_ = setsid()
do {
    let geometry = SessionHostGeometry.fit(columns: columns, rows: rows)
    let host = try SessionHost(path: args[1], shell: args[2], arguments: Array(args.dropFirst(6)),
                               directory: args[3], columns: geometry.columns, rows: geometry.rows)
    withExtendedLifetime(host) { RunLoop.main.run() }
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
