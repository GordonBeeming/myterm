import Foundation
import OSLog

/// One recorded moment in the connection's life.
struct DiagnosticsEntry: Codable, Equatable, Identifiable, Sendable {
    /// Monotonic within a run, so ordering survives entries sharing a timestamp.
    let sequence: UInt64
    let at: Date
    let category: String
    let message: String
    /// Short, already-redacted context. Never tokens, terminal output, or pasted content.
    let detail: String?

    var id: UInt64 { sequence }

    var line: String {
        let stamp = DiagnosticsLog.timestamp(at)
        let suffix = detail.map { " \($0)" } ?? ""
        return "\(stamp) [\(category)] \(message)\(suffix)"
    }
}

/// Records what the connection did, so a report can arrive with evidence instead of a description.
///
/// Off unless the user turns it on. Nothing here leaves the device on its own: the entries sit in a
/// bounded ring in memory, mirrored to one capped file, and go anywhere else only when the user
/// shares them.
///
/// Identifiers are logged as short prefixes and values that could carry secrets or terminal
/// contents are never passed in. The redaction is at the call site by construction: this type takes
/// a category, a fixed message, and an optional already-safe detail.
actor DiagnosticsLog {
    static let shared = DiagnosticsLog()

    /// Kept small enough to share by email and to hold a session's worth of connection events.
    static let maximumEntries = 2_000
    static let maximumFileBytes = 512 * 1_024

    /// Built per call rather than shared: `ISO8601DateFormatter` is not `Sendable`, and a log
    /// line is written far too rarely for the allocation to matter.
    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static let logger = Logger(subsystem: AppConfiguration.bundleIdentifier,
                                       category: "Diagnostics")

    private var entries: [DiagnosticsEntry] = []
    private var nextSequence: UInt64 = 0
    private let fileURL: URL?
    private var isEnabled: Bool

    init(fileURL: URL? = DiagnosticsLog.defaultFileURL, enabled: Bool = false) {
        self.fileURL = fileURL
        self.isEnabled = enabled
    }

    static var defaultFileURL: URL? {
        guard let directory = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                           in: .userDomainMask,
                                                           appropriateFor: nil, create: true) else {
            return nil
        }
        return directory.appending(path: "companion-diagnostics.log", directoryHint: .notDirectory)
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        record(category: "diagnostics", enabled ? "collection started" : "collection stopped")
    }

    var enabled: Bool { isEnabled }

    /// Records one event. `detail` must already be safe to write down.
    func record(category: String, _ message: String, detail: String? = nil) {
        guard isEnabled else { return }
        let entry = DiagnosticsEntry(sequence: nextSequence, at: .now,
                                     category: category, message: message, detail: detail)
        nextSequence &+= 1
        entries.append(entry)
        if entries.count > Self.maximumEntries {
            entries.removeFirst(entries.count - Self.maximumEntries)
        }
        Self.logger.debug("\(entry.line, privacy: .public)")
        append(entry)
    }

    func recent(limit: Int = maximumEntries) -> [DiagnosticsEntry] {
        Array(entries.suffix(limit))
    }

    /// The whole log as text, for sharing.
    func exportText() -> String {
        entries.map(\.line).joined(separator: "\n")
    }

    func clear() {
        entries.removeAll()
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Mirrors to disk so a log survives the app being killed, which is when it is most wanted.
    private func append(_ entry: DiagnosticsEntry) {
        guard let fileURL else { return }
        guard let data = (entry.line + "\n").data(using: .utf8) else { return }
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                if try handle.offset() > Self.maximumFileBytes { try trim(fileURL) }
            } else {
                try data.write(to: fileURL, options: .atomic)
            }
        } catch {
            // Losing a line of diagnostics is not worth surfacing over whatever is being diagnosed.
            Self.logger.error("Could not append diagnostics: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Keeps the newest half when the file reaches its cap, so it stays bounded without losing the
    /// part nearest whatever just went wrong.
    private func trim(_ fileURL: URL) throws {
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
        let kept = lines.suffix(max(1, lines.count / 2)).joined(separator: "\n")
        try (kept + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
    }
}

extension DiagnosticsLog {
    /// A short, non-identifying prefix. Enough to tell two connections apart in a log without
    /// writing down which device or session it was.
    static func short(_ id: UUID?) -> String {
        guard let id else { return "none" }
        return String(id.uuidString.prefix(8)).lowercased()
    }
}
