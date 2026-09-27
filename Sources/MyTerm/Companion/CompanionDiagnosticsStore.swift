import Compression
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
        let folder = directory.appending(path: Self.folderName(deviceID: deviceID),
                                         directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The peer's own name is written beside its uploads rather than used as the folder, so a
        // device that renames itself keeps one history instead of starting a new one.
        try? Data(payload.deviceName.utf8).write(
            to: folder.appending(path: "device-name.txt", directoryHint: .notDirectory)
        )

        // Two uploads can share a second, and the same snapshot can be sent twice; a suffix keeps
        // the later one from overwriting a report that was already accepted.
        let stamp = Self.fileStamp(payload.capturedAt)
        let unique = String(UUID().uuidString.prefix(8)).lowercased()
        let file = folder.appending(path: "\(stamp)-\(unique).log", directoryHint: .notDirectory)
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

    /// One folder per paired device, named by the whole identifier so two devices can never
    /// share one and a device that renames itself keeps the history it already had.
    static func folderName(deviceID: UUID) -> String {
        deviceID.uuidString.lowercased()
    }

    static func fileStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    /// Inflates with a hard ceiling on the output.
    ///
    /// A stream well inside the compressed limit can expand to hundreds of megabytes, so this
    /// decompresses in chunks and gives up the moment the total passes the cap, rather than
    /// materialising whatever the peer sent and checking afterwards.
    static func decompress(_ data: Data,
                           limit: Int = RemoteDiagnosticsPayload.maximumExpandedBytes) throws -> String {
        var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!,
                                        dst_size: 0,
                                        src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!,
                                        src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE,
                                      COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw CompanionDiagnosticsError.unreadable
        }
        defer { compression_stream_destroy(&stream) }

        let bufferSize = 64 * 1_024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        var expanded = Data()

        let status: compression_status = try data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                throw CompanionDiagnosticsError.unreadable
            }
            stream.src_ptr = base
            stream.src_size = raw.count
            while true {
                stream.dst_ptr = buffer
                stream.dst_size = bufferSize
                let step = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                guard step != COMPRESSION_STATUS_ERROR else {
                    throw CompanionDiagnosticsError.unreadable
                }
                expanded.append(buffer, count: bufferSize - stream.dst_size)
                guard expanded.count <= limit else { throw CompanionDiagnosticsError.tooLarge }
                if step == COMPRESSION_STATUS_END { return step }
            }
        }
        guard status == COMPRESSION_STATUS_END, let text = String(data: expanded, encoding: .utf8) else {
            throw CompanionDiagnosticsError.unreadable
        }
        return text
    }
}

enum CompanionDiagnosticsError: Error, Equatable {
    case tooFrequent
    case unreadable
    case tooLarge
}
