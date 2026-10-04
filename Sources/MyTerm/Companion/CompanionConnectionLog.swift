import Foundation
import OSLog

/// One recorded moment in the Mac's own relay connection.
struct CompanionConnectionEntry: Sendable, Equatable {
    let sequence: Int
    let recordedAt: Date
    let category: String
    let message: String
    let detail: String?
    /// Set only for an entry read back from a previous run, where the stored text is already a
    /// finished line. Re-formatting it would stamp it with the time the app reopened and claim an
    /// old connection event happened just now.
    let verbatimLine: String?

    var line: String {
        if let verbatimLine { return verbatimLine }
        let suffix = detail.map { " \($0)" } ?? ""
        return "\(CompanionConnectionEntry.timestamp(recordedAt)) [\(category)] \(message)\(suffix)"
    }

    /// Built per call rather than shared, because `ISO8601DateFormatter` is not `Sendable`. The
    /// companion's own log does the same; a line is cheap next to what produced it.
    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

/// What the Mac's end of a companion connection has been doing.
///
/// The companion has had this since the diagnostics work; the Mac never did, so when the relay
/// started closing the Mac's socket there was nothing on this side to read and the cause had to be
/// inferred from the relay's logs. Deliberately the same shape as the companion's `DiagnosticsLog`:
/// an actor over a bounded ring, mirrored to a capped file, off until asked for.
actor CompanionConnectionLog {
    static let shared = CompanionConnectionLog()

    /// Entries held in memory, and the byte ceiling for the file behind them.
    private static let capacity = 2_000
    private static let maximumFileBytes = 512 * 1_024
    private static let logger = Logger(subsystem: "com.gordonbeeming.myterm",
                                       category: "companion-connection-log")

    private var entries: [CompanionConnectionEntry] = []
    private var nextSequence = 0
    private var isEnabled = false
    private var fileURL: URL?

    /// Shortens an identifier for a log line. Full UUIDs made every line unreadable and none of
    /// this is for correlating across machines.
    static func short(_ id: UUID) -> String { String(id.uuidString.prefix(8)).lowercased() }
    static func short(_ id: some CustomStringConvertible) -> String {
        String(id.description.prefix(8)).lowercased()
    }

    func configure(fileURL: URL?) { self.fileURL = fileURL }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            readBack()
            record(category: "diagnostics", "collection started")
        } else {
            entries.removeAll()
        }
    }

    /// Never given terminal bytes, typed input, or a token: this records what the connection did,
    /// not what travelled over it.
    func record(category: String, _ message: String, detail: String? = nil) {
        guard isEnabled else { return }
        let entry = CompanionConnectionEntry(sequence: nextSequence, recordedAt: .now,
                                             category: category, message: message, detail: detail,
                                             verbatimLine: nil)
        nextSequence += 1
        entries.append(entry)
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
        append(entry)
    }

    func recent(limit: Int = 200) -> [CompanionConnectionEntry] {
        Array(entries.suffix(limit))
    }

    func exportText() -> String {
        entries.map(\.line).joined(separator: "\n")
    }

    func clear() {
        entries.removeAll()
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Picks up what a previous run wrote, so a connection that died before the app was next
    /// opened is still readable.
    private func readBack() {
        guard entries.isEmpty, let fileURL,
              let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).suffix(Self.capacity)
        entries = lines.enumerated().map { index, line in
            CompanionConnectionEntry(sequence: index, recordedAt: .now, category: "earlier run",
                                     message: String(line), detail: nil,
                                     verbatimLine: String(line))
        }
        nextSequence = entries.count
    }

    private func append(_ entry: CompanionConnectionEntry) {
        guard let fileURL else { return }
        let line = Data((entry.line + "\n").utf8)
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: fileURL, options: .atomic)
            }
            trimFileIfNeeded()
        } catch {
            // A log that cannot write is not worth failing a connection over, and saying so once
            // per line would be its own flood.
            Self.logger.error("Could not append to the connection log: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Trimmed by bytes rather than lines, because one line's length is not bounded.
    private func trimFileIfNeeded() {
        guard let fileURL,
              let size = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int,
              size > Self.maximumFileBytes else { return }
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        var kept = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        // A single line can be longer than the whole budget, because a detail carries an error
        // description of no fixed length. Keeping the last line unconditionally would leave the
        // file over its stated cap, so an oversized one goes too and the file empties instead.
        while !kept.isEmpty, kept.joined(separator: "\n").utf8.count > Self.maximumFileBytes {
            kept.removeFirst()
        }
        let body = kept.isEmpty ? "" : kept.joined(separator: "\n") + "\n"
        try? Data(body.utf8).write(to: fileURL, options: .atomic)
    }
}
