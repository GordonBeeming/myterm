import Darwin
import Foundation
import MyTermCore

/// Which Claude sign-in a running Claude Code process uses, read from the process itself.
///
/// The hook names the account on every report, but a report replayed by a session host built
/// before hooks carried the account names none. The process's own environment still says which
/// `CLAUDE_CONFIG_DIR` it was started with, and that never changes for the life of the process.
enum ClaudeProcessConfiguration {
    /// How far below the shell to look. The hook walks the same number of ancestors.
    static let maximumDepth = 16
    /// A bound on the processes inspected, so a pane running a large build stays cheap to ask.
    static let maximumProcesses = 512

    /// The configuration of the outermost `claude` below `shellProcessID` that is in the terminal's
    /// foreground process group. A Claude started from inside another one belongs to that
    /// conversation, not to the pane, which the hook also ignores; a background Claude may run under
    /// another sign-in, so it never answers for the pane. Nil when no such `claude` runs there or its
    /// arguments cannot be read.
    static func configuration(belowShell shellProcessID: pid_t) -> ClaudeConfiguration? {
        guard shellProcessID > 1, let foregroundGroup = terminalForegroundGroup(of: shellProcessID),
              let claude = outermostClaude(below: shellProcessID, inGroup: foregroundGroup) else { return nil }
        return ClaudeConfiguration(environmentValue: claude.arguments.environment["CLAUDE_CONFIG_DIR"])
    }

    /// Recover a missed hook from the running foreground Claude process's PID-indexed record.
    static func conversation(belowShell shellProcessID: pid_t) -> AgentSessionHandle? {
        guard shellProcessID > 1, let group = terminalForegroundGroup(of: shellProcessID),
              let claude = outermostClaude(below: shellProcessID, inGroup: group),
              let process = bsdInfo(of: claude.pid),
              let configuration = ClaudeConfiguration(environmentValue: claude.arguments.environment["CLAUDE_CONFIG_DIR"])
        else { return nil }
        let root: URL
        switch configuration {
        case .standard: root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        case .directory(let directory): root = directory
        }
        let record = root.appendingPathComponent("sessions/\(claude.pid).json")
        let started = Date(timeIntervalSince1970: Double(process.pbi_start_tvsec) + Double(process.pbi_start_tvusec) / 1_000_000)
        guard let properties = try? record.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]),
              properties.isRegularFile == true, properties.isSymbolicLink != true,
              let modified = properties.contentModificationDate, modified >= started else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: record) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1_024 + 1),
              let current = bsdInfo(of: claude.pid), current.pbi_start_tvsec == process.pbi_start_tvsec,
              current.pbi_start_tvusec == process.pbi_start_tvusec else { return nil }
        return conversation(from: data, pid: claude.pid, configuration: configuration)
    }

    static func conversation(from data: Data, pid: pid_t, configuration: ClaudeConfiguration) -> AgentSessionHandle? {
        struct Record: Decodable {
            let pid: pid_t
            let sessionId: String
            let cwd: String
        }
        guard data.count <= 64 * 1_024, let record = try? JSONDecoder().decode(Record.self, from: data),
              record.pid == pid, UUID(uuidString: record.sessionId) != nil, record.cwd.hasPrefix("/") else { return nil }
        return AgentSessionHandle(agent: "claude", sessionID: record.sessionId,
                                  workingDirectory: URL(fileURLWithPath: record.cwd, isDirectory: true),
                                  claudeConfiguration: configuration)
    }

    private static func outermostClaude(below root: pid_t, inGroup group: pid_t) -> (pid: pid_t, arguments: ProcessArguments)? {
        var level = [root]
        var inspected = 0
        for _ in 0..<maximumDepth {
            var next: [pid_t] = []
            for parent in level {
                for child in children(of: parent) {
                    inspected += 1
                    guard inspected <= maximumProcesses else { return nil }
                    if processGroup(of: child) == group, let arguments = arguments(of: child),
                       arguments.isClaude {
                        return (child, arguments)
                    }
                    next.append(child)
                }
            }
            guard !next.isEmpty else { return nil }
            level = next
        }
        return nil
    }

    /// The process group in front of the shell's terminal. Nil when the shell has no terminal.
    private static func terminalForegroundGroup(of processID: pid_t) -> pid_t? {
        guard let info = bsdInfo(of: processID), info.e_tpgid > 0 else { return nil }
        return pid_t(info.e_tpgid)
    }

    private static func processGroup(of processID: pid_t) -> pid_t? {
        bsdInfo(of: processID).map { pid_t($0.pbi_pgid) }
    }

    private static func bsdInfo(of processID: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    private static func children(of parent: pid_t) -> [pid_t] {
        var capacity = 32
        while capacity <= 4_096 {
            var pids = [pid_t](repeating: 0, count: capacity)
            let count = pids.withUnsafeMutableBytes { buffer in
                proc_listchildpids(parent, buffer.baseAddress, Int32(buffer.count))
            }
            guard count >= 0 else { return [] }
            // A full buffer may have cut the list short, so ask again with room to spare.
            if count < capacity { return Array(pids.prefix(Int(count)).filter { $0 > 0 }) }
            capacity *= 2
        }
        return []
    }

    private static func arguments(of processID: pid_t) -> ProcessArguments? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, processID]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &bytes, &size, nil, 0) == 0 else { return nil }
        return arguments(fromProcArgs: Data(bytes.prefix(size)))
    }

    /// What `KERN_PROCARGS2` says about a process.
    struct ProcessArguments: Equatable {
        /// The path the process was started from, as given to exec. For Claude Code that is the
        /// `claude` link, while the kernel's process name is the versioned file it points at.
        let executablePath: String
        let environment: [String: String]

        /// Matches the name the hook looks for, the last part of the path the process was started as.
        var isClaude: Bool { (executablePath as NSString).lastPathComponent == "claude" }
    }

    /// Parses a `KERN_PROCARGS2` buffer: a native `Int32` argument count, the executable path, NUL
    /// padding, that many NUL-terminated arguments, then NUL-terminated `NAME=value` entries up to an
    /// empty one or the end. Nil when the buffer is too short to hold what it claims.
    static func arguments(fromProcArgs data: Data) -> ProcessArguments? {
        let bytes = [UInt8](data)
        let countSize = MemoryLayout<Int32>.size
        guard bytes.count >= countSize else { return nil }
        let argumentCount = bytes.prefix(countSize).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argumentCount >= 0 else { return nil }

        var index = countSize
        guard let pathEnd = bytes[index...].firstIndex(of: 0), pathEnd > index else { return nil }
        let executablePath = String(decoding: bytes[index..<pathEnd], as: UTF8.self)
        index = pathEnd
        // Padding after the path.
        while index < bytes.count, bytes[index] == 0 { index += 1 }

        for _ in 0..<argumentCount {
            guard index < bytes.count, let end = bytes[index...].firstIndex(of: 0) else { return nil }
            index = end + 1
        }

        var environment: [String: String] = [:]
        while index < bytes.count {
            let end = bytes[index...].firstIndex(of: 0) ?? bytes.count
            guard end > index else { break }
            let entry = String(decoding: bytes[index..<end], as: UTF8.self)
            if let separator = entry.firstIndex(of: "="), separator != entry.startIndex {
                let name = String(entry[..<separator])
                // The first definition is the one getenv returns.
                if environment[name] == nil {
                    environment[name] = String(entry[entry.index(after: separator)...])
                }
            }
            index = end + 1
        }
        return ProcessArguments(executablePath: executablePath, environment: environment)
    }
}
