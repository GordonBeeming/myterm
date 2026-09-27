import Foundation
import MyTermCore
import OSLog

/// Files the diagnostics a paired companion sends, so a report arrives somewhere a person can open.
///
/// Bounded on purpose: a phone can upload, so it must not be able to fill the Mac's disk. Uploads
/// are rate limited per device, each one is capped by the protocol, and the folder is pruned to a
/// fixed budget with the newest kept.
actor CompanionDiagnosticsStore {
    static let maximumBytesPerDevice = 8 * 1_024 * 1_024
    static let maximumFilesPerDevice = 20
    static let minimumInterval: TimeInterval = 30

    private static let logger = Logger(subsystem: "com.gordonbeeming.myterm",
                                       category: "companion-diagnostics")

    private let directory: URL
    private var lastAccepted: [UUID: Date] = [:]

    init(directory: URL) {
        self.directory = directory
    }

    /// Where a channel keeps what companions have sent it.
    static func directory(applicationSupportDirectory: URL, channelName: String) -> URL {
        applicationSupportDirectory
            .appending(path: channelName, directoryHint: .isDirectory)
            .appending(path: "companion-diagnostics", directoryHint: .isDirectory)
    }

    /// Accepts one upload, returning the file it was written to.
    ///
    /// `deviceID` identifies an already-paired peer; the payload's own name is only a label and is
    /// never trusted as a path component.
    @discardableResult
    func accept(_ payload: RemoteDiagnosticsPayload, deviceID: UUID,
                now: Date = .now) throws -> URL {
        if let last = lastAccepted[deviceID], now.timeIntervalSince(last) < Self.minimumInterval {
            throw CompanionDiagnosticsError.tooFrequent
        }
        let text = try Self.decompress(payload.compressed)
        let folder = directory.appending(path: Self.folderName(deviceID: deviceID,
                                                               label: payload.deviceName),
                                         directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let stamp = Self.fileStamp(payload.capturedAt)
        let file = folder.appending(path: "\(stamp).log", directoryHint: .notDirectory)
        try text.write(to: file, atomically: true, encoding: .utf8)
        lastAccepted[deviceID] = now
        prune(folder)
        Self.logger.info("stored companion diagnostics: \(file.lastPathComponent, privacy: .public)")
        return file
    }

    /// Keeps the newest uploads within both budgets.
    private func prune(_ folder: URL) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys
        ) else { return }
        let newestFirst = entries.sorted { left, right in
            let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return leftDate > rightDate
        }
        var kept = 0
        var bytes = 0
        for entry in newestFirst {
            let size = (try? entry.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            kept += 1
            bytes += size
            if kept > Self.maximumFilesPerDevice || bytes > Self.maximumBytesPerDevice {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }

    /// A folder name derived from the paired device, with the peer's own label reduced to safe
    /// characters. The device identifier is what makes it unique; the label is only for reading.
    static func folderName(deviceID: UUID, label: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let cleaned = label.unicodeScalars.filter { allowed.contains($0) }
            .map(String.init).joined().trimmingCharacters(in: .whitespaces)
        let shortID = String(deviceID.uuidString.prefix(8)).lowercased()
        return cleaned.isEmpty ? shortID : "\(cleaned) (\(shortID))"
    }

    static func fileStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    static func decompress(_ data: Data) throws -> String {
        let expanded = try (data as NSData).decompressed(using: .zlib) as Data
        guard let text = String(data: expanded, encoding: .utf8) else {
            throw CompanionDiagnosticsError.unreadable
        }
        return text
    }
}

enum CompanionDiagnosticsError: Error, Equatable {
    case tooFrequent
    case unreadable
}
