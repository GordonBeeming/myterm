import Darwin
import Foundation
import MyTermContinuity
import OSLog
import Security

/// Runs persistent helpers from a private copy of each signed build. macOS validates a running
/// helper against the file at its launch path, so a helper started from inside the app bundle
/// fails authentication as soon as an update replaces that bundle, and every live terminal
/// becomes unattachable. A copy that no update touches keeps those helpers verifiable.
enum SessionHostInstallation {
    static let directoryName = "session-hosts"
    static let executableName = "MyTermSessionHost"

    nonisolated static func bundledHelper() -> URL? {
        Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(executableName)
    }

    /// The launch path for `bundled`'s exact build, keyed by its code directory hash. The copy is
    /// verified against the same requirement as the bundled helper before it is ever returned.
    nonisolated static func stableHelper(for bundled: URL, namespace: URL,
                                         verifier: SessionHostServerAuthentication) throws -> URL {
        try verifier.validateExecutable(bundled)
        // An ad-hoc development helper has no team identity, so it pins its controller by finding
        // the app bundle around it. Moving it would lose that app. Ad-hoc builds already pin one
        // exact executable, so they are documented as closing their panes before a rebuild.
        if try teamIdentifier(of: bundled) == nil,
           bundled.pathComponents.contains(where: { $0.hasSuffix(".app") }) { return bundled }
        let identity = try codeDirectoryHash(of: bundled)
        let root = namespace.appendingPathComponent(directoryName, isDirectory: true)
        let directory = root.appendingPathComponent(identity, isDirectory: true)
        let target = directory.appendingPathComponent(executableName)
        if (try? verifyCopy(target, identity: identity, verifier: verifier)) != nil { return target }
        try SessionHostSocket.prepareDirectory(root)
        try SessionHostSocket.prepareDirectory(directory)
        let staged = directory.appendingPathComponent(".\(executableName)-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staged) }
        try FileManager.default.copyItem(at: bundled, to: staged)
        try verifyCopy(staged, identity: identity, verifier: verifier)
        // Renaming over the target is atomic, so a launcher never sees a partial copy. Replacing a
        // concurrent launcher's copy is harmless: both have the same verified code directory.
        guard rename(staged.path, target.path) == 0 else {
            throw SessionHostError.system("install terminal helper", errno)
        }
        return target
    }

    /// Removes copies of other builds that no running process was launched from. A helper's
    /// launch path stays inside its copy's directory for its whole life, however old it is.
    @discardableResult
    nonisolated static func pruneUnusedCopies(namespace: URL, keeping bundled: URL?) -> [URL] {
        let logger = Logger(subsystem: "com.gordonbeeming.myterm", category: "terminal-continuity")
        // Without the current build's identity, any copy might be the one about to be launched.
        guard let bundled, let current = try? codeDirectoryHash(of: bundled) else { return [] }
        let root = namespace.appendingPathComponent(directoryName, isDirectory: true)
            .resolvingSymlinksInPath()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        let launchPaths: [String]
        do { launchPaths = try runningExecutablePaths() } catch {
            logger.error("Kept terminal helper copies: running processes could not be listed: \(error.localizedDescription, privacy: .public)")
            return []
        }
        var removed: [URL] = []
        for entry in entries where entry.lastPathComponent != current {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let prefix = entry.resolvingSymlinksInPath().path + "/"
            guard !launchPaths.contains(where: { $0.hasPrefix(prefix) }) else { continue }
            do {
                try FileManager.default.removeItem(at: entry)
                removed.append(entry)
            } catch {
                logger.error("Could not remove unused terminal helper copy \(entry.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return removed
    }

    nonisolated static func codeDirectoryHash(of url: URL) throws -> String {
        var code: SecStaticCode?
        var rawInfo: CFDictionary?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, [], &rawInfo) == errSecSuccess,
              let info = rawInfo as? [String: Any],
              let unique = info[kSecCodeInfoUnique as String] as? Data, !unique.isEmpty else {
            throw SessionHostError.untrustedHost
        }
        return unique.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func teamIdentifier(of url: URL) throws -> String? {
        var code: SecStaticCode?
        var rawInfo: CFDictionary?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &rawInfo) == errSecSuccess,
              let info = rawInfo as? [String: Any] else { throw SessionHostError.untrustedHost }
        guard let team = info[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty else { return nil }
        return team
    }

    private nonisolated static func verifyCopy(_ url: URL, identity: String,
                                               verifier: SessionHostServerAuthentication) throws {
        try verifier.validateExecutable(url)
        guard try codeDirectoryHash(of: url) == identity else { throw SessionHostError.untrustedHost }
    }

    private nonisolated static func runningExecutablePaths() throws -> [String] {
        let capacity = proc_listpids(UInt32(PROC_UID_ONLY), UInt32(getuid()), nil, 0)
        guard capacity > 0 else { throw SessionHostError.system("list processes", errno) }
        // Leave room for processes started between the size query and the listing.
        var pids = [pid_t](repeating: 0, count: Int(capacity) / MemoryLayout<pid_t>.size + 64)
        let bytes = proc_listpids(UInt32(PROC_UID_ONLY), UInt32(getuid()), &pids,
                                  Int32(pids.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { throw SessionHostError.system("list processes", errno) }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        return pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size).compactMap { pid in
            guard pid > 0 else { return nil }
            let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            guard length > 0 else { return nil }
            let path = String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        }
    }
}
