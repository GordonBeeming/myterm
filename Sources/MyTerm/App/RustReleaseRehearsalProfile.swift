#if MYTERM_RUST_RELEASE_REHEARSAL
import CryptoKit
import Darwin
import Foundation

enum RustReleaseRehearsalProfile {
    static func configure(fileManager: FileManager = .default) throws {
        let supportKey = "MYTERM_APPLICATION_SUPPORT_DIRECTORY"
        let directory = try validate(
            ProcessInfo.processInfo.environment[supportKey],
            productionSupport: fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask),
            fileManager: fileManager)
        let digest = SHA256.hash(data: Data(directory.path.utf8))
            .prefix(12).map { String(format: "%02x", $0) }.joined()
        let suite = MyTermChannel.active.bundleIdentifier + "." + digest
        guard setenv(supportKey, directory.path, 1) == 0,
              setenv("MYTERM_USER_DEFAULTS_SUITE", suite, 1) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    static func validate(_ path: String?, productionSupport: [URL], fileManager: FileManager) throws -> URL {
        guard let path, path.hasPrefix("/") else {
            throw ProfileError("Set MYTERM_APPLICATION_SUPPORT_DIRECTORY to an absolute directory containing a separate configuration copy.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let workspace = directory.appendingPathComponent("myterm", isDirectory: true)
        let installedLocations = productionSupport.map {
            $0.standardizedFileURL.resolvingSymlinksInPath()
        }
        guard !installedLocations.isEmpty, installedLocations.allSatisfy({
            !directory.pathComponents.starts(with: $0.pathComponents)
                && !$0.pathComponents.starts(with: directory.pathComponents)
        }) else {
            throw ProfileError("Choose a directory outside the installed MyTerm configuration.")
        }
        var info = stat()
        guard lstat(directory.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(),
              info.st_mode & 0o077 == 0 else {
            throw ProfileError("The rehearsal support directory must already exist and be private to this user (chmod 700).")
        }

        // A linked copy can still direct writes into the installed configuration.
        if lstat(workspace.path, &info) != 0 {
            if errno == ENOENT { return directory }
            throw ProfileError("The copied MyTerm configuration could not be inspected.")
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            throw ProfileError("The copied myterm directory must be a real directory.")
        }
        var enumerationError: (any Error)?
        guard let contents = fileManager.enumerator(at: workspace, includingPropertiesForKeys: nil,
            errorHandler: { _, error in enumerationError = error; return false }) else {
            throw ProfileError("The copied MyTerm configuration could not be inspected.")
        }
        for case let item as URL in contents {
            guard lstat(item.path, &info) == 0 else {
                throw ProfileError("An item in the copied MyTerm configuration could not be inspected.")
            }
            let kind = info.st_mode & S_IFMT
            guard kind == S_IFDIR || (kind == S_IFREG && info.st_nlink == 1) else {
                throw ProfileError("Copy the configuration as ordinary files. Linked files and sockets cannot be used in the rehearsal.")
            }
        }
        if let enumerationError { throw enumerationError }
        return directory
    }

    private struct ProfileError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
#endif
