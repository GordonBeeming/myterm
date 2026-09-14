import Foundation

/// Opt-in trace for synchronized-output (DEC 2026) flow and display scheduling.
/// This internal compile-time switch can be enabled in SwiftTerm source to log events to stderr.
enum SyncDebug {
    public static let enabled = false
    private static let start = DispatchTime.now().uptimeNanoseconds

    @inline(__always)
    @inlinable
    static func log(_ event: @autoclosure () -> String) {
        guard enabled else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let ms = Double(now &- start) / 1_000_000
        let line = String(format: "[sync %9.2fms] %@\n", ms, event())
        FileHandle.standardError.write(Data(line.utf8))
    }
}
