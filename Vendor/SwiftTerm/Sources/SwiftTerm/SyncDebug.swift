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

    /// A trace left on by accident must not fill the disk. Past this the log is
    /// started again from empty, which keeps the most recent run, and a stall is
    /// always diagnosed from the tail.
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
        if handle == nil {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                let opened = try FileHandle(forWritingTo: url)
                try opened.seekToEnd()
                handle = opened
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                written = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            } catch {
                // Tracing must never take the terminal down with it. One failure
                // to open the log leaves `handle` nil and every later line is
                // dropped the same way.
                return
            }
        }
        guard let handle else { return }
        if written > maximumBytes {
            try? handle.truncate(atOffset: 0)
            written = 0
        }
        do {
            try handle.write(contentsOf: data)
            written &+= UInt64(data.count)
        } catch {
            try? handle.close()
            self.handle = nil
        }
    }
}
