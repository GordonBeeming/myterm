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

    /// The configuration of the outermost `claude` below `shellProcessID`. A Claude started from
    /// inside another one belongs to that conversation, not to the pane, which the hook also
    /// ignores. Nil when no `claude` runs there or its environment cannot be read.
    static func configuration(belowShell shellProcessID: pid_t) -> ClaudeConfiguration? {
        guard shellProcessID > 1, let claude = outermostClaude(below: shellProcessID),
              let environment = environment(of: claude) else { return nil }
        return ClaudeConfiguration(environmentValue: environment["CLAUDE_CONFIG_DIR"])
    }

    private static func outermostClaude(below root: pid_t) -> pid_t? {
        var level = [root]
        var inspected = 0
        for _ in 0..<maximumDepth {
            var next: [pid_t] = []
            for parent in level {
                for child in children(of: parent) {
                    inspected += 1
                    guard inspected <= maximumProcesses else { return nil }
                    if name(of: child) == "claude" { return child }
                    next.append(child)
                }
            }
            guard !next.isEmpty else { return nil }
            level = next
        }
        return nil
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

    private static func name(of processID: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) * 2 + 1)
        let length = buffer.withUnsafeMutableBytes { proc_name(processID, $0.baseAddress, UInt32($0.count)) }
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func environment(of processID: pid_t) -> [String: String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, processID]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &bytes, &size, nil, 0) == 0 else { return nil }
        return environment(fromProcArgs: Data(bytes.prefix(size)))
    }

    /// Parses a `KERN_PROCARGS2` buffer: a native `Int32` argument count, the executable path, NUL
    /// padding, that many NUL-terminated arguments, then NUL-terminated `NAME=value` entries up to an
    /// empty one or the end. Nil when the buffer is too short to hold what it claims.
    static func environment(fromProcArgs data: Data) -> [String: String]? {
        let bytes = [UInt8](data)
        let countSize = MemoryLayout<Int32>.size
        guard bytes.count >= countSize else { return nil }
        let argumentCount = bytes.prefix(countSize).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argumentCount >= 0 else { return nil }

        var index = countSize
        // The executable path.
        guard let pathEnd = bytes[index...].firstIndex(of: 0) else { return nil }
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
        return environment
    }
}
