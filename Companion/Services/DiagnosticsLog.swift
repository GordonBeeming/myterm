import Foundation
import MyTermCore
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
    static let maximumDetailCharacters = 200

    /// Built per call rather than shared: `ISO8601DateFormatter` is not `Sendable`, and a log
    /// line is written far too rarely for the allocation to matter.
    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// Errors about the log itself only. Entries are never written here: the unified log is
    /// collectable off-device, and this data is meant to leave only when the user shares it.
    private static let logger = Logger(subsystem: AppConfiguration.bundleIdentifier,
                                       category: "Diagnostics")

    private var entries: [DiagnosticsEntry] = []
    private var nextSequence: UInt64 = 0
    private let fileURL: URL?
    private var isEnabled: Bool

    init(fileURL: URL? = DiagnosticsLog.defaultFileURL, enabled: Bool = false) {
        self.fileURL = fileURL
        self.isEnabled = enabled
        // Read back what an earlier run left behind, so a log survives the app being killed, which
        // is when it is most wanted. The file holds rendered lines rather than the original fields,
        // so they are carried as the message: the point is being able to read and share them.
        if let fileURL, let contents = try? String(contentsOf: fileURL, encoding: .utf8) {
            for line in contents.split(separator: "\n").suffix(Self.maximumEntries) {
                entries.append(DiagnosticsEntry(sequence: nextSequence, at: .now,
                                                category: "earlier run", message: String(line),
                                                detail: nil))
                nextSequence &+= 1
            }
        }
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
        let entry = DiagnosticsEntry(sequence: nextSequence, at: .now, category: category,
                                     message: message,
                                     detail: detail.map { String($0.prefix(Self.maximumDetailCharacters)) })
        nextSequence &+= 1
        entries.append(entry)
        if entries.count > Self.maximumEntries {
            entries.removeFirst(entries.count - Self.maximumEntries)
        }
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
                var size: UInt64 = 0
                do {
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                    size = try handle.offset()
                }
                if size > Self.maximumFileBytes { try trim(fileURL) }
            } else {
                try data.write(to: fileURL, options: .atomic)
                if data.count > Self.maximumFileBytes { try trim(fileURL) }
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
        var kept: [Substring] = []
        var bytes = 0
        let budget = Self.maximumFileBytes / 2
        // Newest first until the budget is spent, so what is kept is nearest whatever went wrong.
        for line in contents.split(separator: "\n", omittingEmptySubsequences: false).reversed() {
            let cost = line.utf8.count + 1
            if bytes + cost > budget, !kept.isEmpty { break }
            kept.append(line)
            bytes += cost
        }
        let text = kept.reversed().joined(separator: "\n")
        try (text + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
    }
}

extension DiagnosticsLog {
    /// The newest entries, compressed, small enough for one upload. Returns nil when there is
    /// nothing to send or the text will not fit however much is dropped.
    func compressedForUpload(limit: Int = RemoteDiagnosticsPayload.maximumCompressedBytes) async -> Data? {
        var lines = await recent().map(\.line)
        while !lines.isEmpty {
            let text = lines.joined(separator: "\n")
            guard let raw = text.data(using: .utf8),
                  let deflated = try? (raw as NSData).compressed(using: .zlib) as Data else { return nil }
            if deflated.count <= limit { return deflated }
            // Drop the oldest tenth and try again, so a long session still sends its recent history.
            lines.removeFirst(max(1, lines.count / 10))
        }
        return nil
    }

    /// A short, non-identifying prefix. Enough to tell two connections apart in a log without
    /// writing down which device or session it was.
    static func short(_ id: UUID?) -> String {
        guard let id else { return "none" }
        return String(id.uuidString.prefix(8)).lowercased()
    }
}
