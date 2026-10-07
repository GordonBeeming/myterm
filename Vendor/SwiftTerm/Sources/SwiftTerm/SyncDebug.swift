import Foundation

/// Opt-in trace for synchronized-output (DEC 2026) flow and display scheduling.
///
/// A windowed app's stderr goes nowhere a user can read, so the trace is written
/// to a file instead. It is switched on at runtime rather than compile time, so a
/// stall that only shows up after hours of real use can be captured on a shipped
/// build:
///
///     defaults write com.gordonbeeming.myterm SwiftTermSyncDebug -bool true
///
/// or `SWIFTTERM_SYNC_DEBUG=1` in the environment. The setting is read once per
/// process, so the app has to be restarted after changing it.
enum SyncDebug {
    /// `~/Library/Logs/MyTerm/terminal-render.log`.
    static let logURL: URL? = {
        guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            return nil
        }
        return library.appendingPathComponent("Logs/MyTerm/terminal-render.log")
    }()

    static let enabled: Bool = {
        if ProcessInfo.processInfo.environment["SWIFTTERM_SYNC_DEBUG"] == "1" {
            return true
        }
        return UserDefaults.standard.bool(forKey: "SwiftTermSyncDebug")
    }()

    /// A trace left on by accident must not fill the disk. Past this the log
    /// stops growing and the app has to be restarted to begin a new one. It
    /// deliberately stops rather than truncating: truncation is the one
    /// operation here that can destroy data that is not ours, which matters
    /// because the path is only as trustworthy as the directory it sits in.
    private static let maximumBytes: UInt64 = 8 * 1024 * 1024

    private static let start = DispatchTime.now().uptimeNanoseconds
    private static let queue = DispatchQueue(label: "swiftterm.syncdebug")
    private nonisolated(unsafe) static var handle: FileHandle?
    private nonisolated(unsafe) static var written: UInt64 = 0

    @inline(__always)
    static func log(_ event: @autoclosure () -> String) {
        guard enabled else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let ms = Double(now &- start) / 1_000_000
        let line = String(format: "[sync %9.2fms] %@\n", ms, event())
        let data = Data(line.utf8)
        queue.async {
            write(data)
        }
    }

    /// Caller holds `queue`.
    private static func write(_ data: Data) {
        guard let url = logURL else { return }
        if handle == nil, !openLog(at: url) {
            return
        }
        guard let handle, written < maximumBytes else { return }
        do {
            try handle.write(contentsOf: data)
            written &+= UInt64(data.count)
            if written >= maximumBytes {
                let notice = "[sync] trace capped at \(maximumBytes) bytes; restart to start a new log\n"
                try handle.write(contentsOf: Data(notice.utf8))
            }
        } catch {
            try? handle.close()
            self.handle = nil
        }
    }

    /// Caller holds `queue`. `handle` is only left set once the log is open and
    /// its length is known, so a failure part-way through cannot leave later
    /// lines writing to a file this never finished validating.
    private static func openLog(at url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            // Tracing must never take the terminal down with it. A log that
            // cannot be opened drops every line the same way.
            return false
        }
        // O_NOFOLLOW: a symlink left at the log path is never followed, so a
        // trace switched on by the user can never write through one.
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
        }
        guard descriptor >= 0 else { return false }
        let opened = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            written = try opened.seekToEnd()
        } catch {
            try? opened.close()
            return false
        }
        handle = opened
        return true
    }
}
