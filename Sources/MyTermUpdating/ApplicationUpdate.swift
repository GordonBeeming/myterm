import CryptoKit
import Darwin
import Foundation
import MyTermCore
import Security

/// A private, durable handoff to a signed helper that only installs after the UI has exited.
public struct ApplicationUpdatePlan: Codable, Sendable {
    public let target: URL
    public let staged: URL
    public let directory: URL
    public let version: String
    public let sourceVersion: String
    public let sourceChannel: UpdateCheck.Channel
    public let channel: UpdateCheck.Channel
    public let configurationDirectory: URL
    public let preferencesDomain: String
    public var stableChoice: ChannelConfigurationStore.StableChoice?
    public var relaunch = true
    public var manifestURL: URL { directory.appendingPathComponent("update.json") }
    public var agentURL: URL { directory.appendingPathComponent("MyTermUpdateAgent") }

    public func save() throws {
        try JSONEncoder().encode(self).write(to: manifestURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
    }
}

public enum ApplicationUpdateError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): message }
    }
}

/// Downloads immutable release bytes, verifies their identity, and stages on the app's filesystem.
public enum ApplicationUpdate {
    public static let bundleIdentifier = "com.gordonbeeming.myterm"
    public static let teamIdentifier = "89DBN36T4T"

    /// Detect an old executable that was already launching while its bundle was replaced.
    public static func runningCodeMatchesFile(_ url: URL) throws -> Bool {
        var dynamic: SecCode?, running: SecStaticCode?, installed: SecStaticCode?
        guard SecCodeCopySelf([], &dynamic) == errSecSuccess, let dynamic,
              SecCodeCopyStaticCode(dynamic, [], &running) == errSecSuccess, let running,
              SecStaticCodeCreateWithPath(url as CFURL, [], &installed) == errSecSuccess, let installed else {
            throw invalid("Could not identify the running and installed application code.")
        }
        func hash(_ code: SecStaticCode) throws -> Data {
            var result: CFDictionary?
            guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &result) == errSecSuccess,
                  let info = result as? [String: Any], let hash = info[kSecCodeInfoUnique as String] as? Data else {
                throw invalid("Could not read the application's signed code identity.")
            }
            return hash
        }
        return try hash(running) == hash(installed)
    }

    /// Share the app's existing lock so a competing launch wins safely or waits until the swap ends.
    public static func acquireInstallationLock(directory: URL) throws -> Int32 {
        let path = directory.appendingPathComponent("instance.lock").path
        let descriptor = open(path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw invalid("Could not open the app's instance lock.") }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(), metadata.st_nlink == 1,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw invalid("Another myterm instance opened before the update could finish. Quit it and retry the prepared update.")
        }
        return descriptor
    }

    /// The process event binds to one process generation rather than polling a potentially reused PID.
    public static func waitForExit(_ pid: pid_t, seconds: Int = 120) throws {
        let descriptor = kqueue()
        guard descriptor >= 0 else { throw invalid("Could not watch the exiting app.") }
        defer { close(descriptor) }
        var change = kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
                            fflags: UInt32(NOTE_EXIT), data: 0, udata: nil)
        guard kevent(descriptor, &change, 1, nil, 0, nil) == 0 else {
            if errno == ESRCH { return }
            throw invalid("Could not watch the exiting app: \(String(cString: strerror(errno)))")
        }
        var result = kevent(), timeout = timespec(tv_sec: seconds, tv_nsec: 0)
        guard kevent(descriptor, nil, 0, &result, 1, &timeout) == 1 else {
            throw invalid("The app did not exit; the prepared update was left untouched.")
        }
        guard result.flags & UInt16(EV_ERROR) == 0, result.fflags & UInt32(NOTE_EXIT) != 0 else {
            throw invalid("The app exit could not be confirmed; the prepared update was left untouched.")
        }
    }

    /// No channel switch may accidentally replay an older build within its own channel.
    public static func validateSource(_ plan: ApplicationUpdatePlan) throws {
        let data = try Data(contentsOf: plan.target.appendingPathComponent("Contents/Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let installed = AppVersion(info["CFBundleShortVersionString"] as? String ?? ""),
              installed == AppVersion(plan.sourceVersion),
              (info["MyTermReleaseChannel"] as? String ?? "stable") == plan.sourceChannel.rawValue,
              let candidate = AppVersion(plan.version), plan.channel != plan.sourceChannel || candidate > installed else {
            throw invalid("The installed app changed or this update would downgrade the same channel. Check for updates again.")
        }
    }

    /// Bundle replacement and preferences are rolled back together if any post-swap step fails.
    @MainActor public static func apply(
        _ plan: ApplicationUpdatePlan,
        validateBundle: (URL, String, UpdateCheck.Channel) throws -> Void = validate,
        exchange: (URL, URL) throws -> Void = exchange,
        launch: (URL) throws -> Void = { try run("/usr/bin/open", ["-n", $0.path]) }
    ) throws {
        try validateSource(plan)
        try validateBundle(plan.staged, plan.version, plan.channel)
        let config = ChannelConfigurationStore(directory: plan.configurationDirectory, preferencesDomain: plan.preferencesDomain)
        if plan.sourceChannel == .stable, plan.channel == .beta { try config.captureStable() }
        let originalPreferences = UserDefaults.standard.persistentDomain(forName: plan.preferencesDomain)
        try exchange(plan.target, plan.staged)
        do {
            try validateBundle(plan.target, plan.version, plan.channel)
            if plan.sourceChannel == .beta, plan.channel == .stable {
                guard let choice = plan.stableChoice else { throw invalid("Choose a configuration before returning to stable.") }
                try config.beginStableReturn(choice)
            } else { try config.cancelStableReturn() }
            var preferences = originalPreferences ?? [:]
            preferences.removeValue(forKey: "updates.stagedManifest")
            preferences["updates.selectedChannel"] = plan.channel.rawValue
            UserDefaults.standard.setPersistentDomain(preferences, forName: plan.preferencesDomain)
            guard UserDefaults.standard.synchronize() else { throw invalid("Could not persist the installed update channel.") }
            if plan.relaunch { try launch(plan.target) }
        } catch {
            let installationError = error
            do {
                try exchange(plan.target, plan.staged)
                if let originalPreferences {
                    UserDefaults.standard.setPersistentDomain(originalPreferences, forName: plan.preferencesDomain)
                } else { UserDefaults.standard.removePersistentDomain(forName: plan.preferencesDomain) }
                guard UserDefaults.standard.synchronize() else { throw invalid("Could not restore the previous preferences.") }
                try config.cancelStableReturn()
            } catch {
                throw invalid("Update rollback could not finish. The previous app is preserved at \(plan.staged.path). \(error.localizedDescription)")
            }
            throw installationError
        }
    }

    public static func exchange(_ a: URL, _ b: URL) throws {
        guard renameatx_np(AT_FDCWD, a.path, AT_FDCWD, b.path, UInt32(RENAME_SWAP)) == 0 else {
            throw invalid("Could not atomically replace the app: \(String(cString: strerror(errno)))")
        }
    }

    /// Prune only this app's private handoffs, after a successful startup and after their helper exits.
    public static func pruneCompletedUpdates(for app: URL) {
        let files = FileManager.default
        let size = proc_listpids(UInt32(PROC_UID_ONLY), UInt32(getuid()), nil, 0)
        guard size > 0 else { return }
        var pids = [pid_t](repeating: 0, count: Int(size) / MemoryLayout<pid_t>.size + 64)
        let count = proc_listpids(UInt32(PROC_UID_ONLY), UInt32(getuid()), &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return }
        var running: [String] = []
        for pid in pids.prefix(Int(count) / MemoryLayout<pid_t>.size) where pid > 0 {
            var path = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else {
                if errno == ESRCH || errno == ENOENT { continue }
                return
            }
            running.append(String(cString: path))
        }
        guard let directories = try? files.contentsOfDirectory(at: app.deletingLastPathComponent(), includingPropertiesForKeys: nil) else { return }
        for directory in directories where directory.lastPathComponent.hasPrefix(".myterm-update-") {
            guard (files.fileExists(atPath: directory.appendingPathComponent("applied").path)
                   || files.fileExists(atPath: directory.appendingPathComponent("superseded").path)),
                  !running.contains(where: { $0.hasPrefix(directory.path + "/") }),
                  let data = try? Data(contentsOf: directory.appendingPathComponent("update.json")),
                  let plan = try? JSONDecoder().decode(ApplicationUpdatePlan.self, from: data),
                  plan.target == app,
                  (try? validatePlan(plan, manifest: directory.appendingPathComponent("update.json"))) != nil else { continue }
            do { try files.removeItem(at: directory) }
            catch { continue } // A failed cleanup must not affect the running app or its configuration.
        }
    }

    /// A superseded helper must never install an earlier prepared build after its parent exits.
    public static func retirePreparedUpdate(_ plan: ApplicationUpdatePlan) throws {
        try validatePlan(plan, manifest: plan.manifestURL)
        try Data("superseded".utf8).write(to: plan.directory.appendingPathComponent("superseded"), options: .atomic)
        let capacity = proc_listpids(UInt32(PROC_UID_ONLY), UInt32(getuid()), nil, 0)
        guard capacity > 0 else { return }
        var pids = [pid_t](repeating: 0, count: Int(capacity) / MemoryLayout<pid_t>.size + 64)
        let count = proc_listpids(UInt32(PROC_UID_ONLY), UInt32(getuid()), &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return }
        for pid in pids.prefix(Int(count) / MemoryLayout<pid_t>.size) where pid > 0 {
            var path = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else {
                if errno == ESRCH || errno == ENOENT { continue }
                return
            }
            if String(cString: path).hasPrefix(plan.directory.path + "/") { return }
        }
        try FileManager.default.removeItem(at: plan.directory)
    }

    public static func prepare(
        release: AppRelease, target: URL, sourceChannel: UpdateCheck.Channel, sourceVersion: String,
        configurationDirectory: URL, preferencesDomain: String,
        progress: @escaping @Sendable (String) async -> Void
    ) async throws -> ApplicationUpdatePlan {
        guard let asset = release.asset else { throw invalid("This release has no verified update download yet.") }
        var arm64: Int32 = 0, arm64Size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.optional.arm64", &arm64, &arm64Size, nil, 0) == 0, arm64 == 1 else {
            throw invalid("Published myterm updates currently require an Apple silicon Mac.")
        }
        guard let source = AppVersion(sourceVersion), release.channel != sourceChannel || release.version > source else {
            throw invalid("An update within the same channel must be newer than the running app.")
        }
        let files = FileManager.default
        guard !target.path.contains("/AppTranslocation/"),
              target.pathExtension == "app", target.standardizedFileURL == target.resolvingSymlinksInPath(),
              files.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            throw invalid("The app folder is not writable. Move myterm to a writable Applications folder before updating.")
        }
        let directory = target.deletingLastPathComponent()
            .appendingPathComponent(".myterm-update-\(UUID().uuidString).noindex", isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var complete = false
        defer { if !complete { try? files.removeItem(at: directory) } }
        try probeAtomicSwap(in: directory)
        await progress("Downloading \(release.channel.title) \(release.version)…")
        let dmg = directory.appendingPathComponent("update.dmg")
        try await ReleaseDownload(url: asset.url, destination: dmg).download()
        try Task.checkCancellation()
        await progress("Verifying download, signatures, and notarization…")
        let plan = try await Task.detached {
            let files = FileManager.default
            guard try digest(dmg) == asset.sha256 else { throw invalid("The update download failed its SHA-256 check.") }
            try run("/usr/bin/codesign", ["--verify", "--strict", dmg.path])
            try run("/usr/bin/xcrun", ["stapler", "validate", dmg.path])
            try run("/usr/sbin/spctl", ["--assess", "--type", "open", "--context", "context:primary-signature", dmg.path])
            let mount = directory.appendingPathComponent("volume", isDirectory: true)
            try files.createDirectory(at: mount, withIntermediateDirectories: false)
            try run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, dmg.path])
            defer { try? run("/usr/bin/hdiutil", ["detach", mount.path]) }
            let staged = directory.appendingPathComponent("myterm.app", isDirectory: true)
            let mountedApp = mount.appendingPathComponent("myterm.app")
            try validate(mountedApp, version: release.version.description, channel: release.channel)
            try run("/usr/bin/ditto", [mountedApp.path, staged.path])
            try validate(staged, version: release.version.description, channel: release.channel)
            let fallbackExists = files.fileExists(atPath: configurationDirectory.appendingPathComponent("last-stable-configuration.json").path)
            let mode = sourceChannel == .beta && release.channel == .stable && fallbackExists ? "stable-fallback" : "current"
            try run(staged.appendingPathComponent("Contents/MacOS/MyTermUpdateAgent").path,
                    ["--verify-configuration", configurationDirectory.path, preferencesDomain, mode])
            let helper = target.appendingPathComponent("Contents/MacOS/MyTermUpdateAgent")
            try verifySignature(helper, identifier: bundleIdentifier + ".update-agent")
            try files.copyItem(at: helper, to: directory.appendingPathComponent("MyTermUpdateAgent"))
            let plan = ApplicationUpdatePlan(target: target, staged: staged, directory: directory,
                version: release.version.description, sourceVersion: sourceVersion, sourceChannel: sourceChannel, channel: release.channel,
                configurationDirectory: configurationDirectory, preferencesDomain: preferencesDomain)
            try plan.save()
            try files.removeItem(at: dmg)
            return plan
        }.value
        try Task.checkCancellation()
        complete = true
        await progress("Update verified and staged. Your app and configuration will change only after you restart.")
        return plan
    }

    /// Validate again immediately before swapping: a stale or modified staged app is never installed.
    public static func validate(_ app: URL, version: String, channel: UpdateCheck.Channel) throws {
        guard app.standardizedFileURL == app.resolvingSymlinksInPath(),
              (try FileManager.default.attributesOfItem(atPath: app.path)[.type]) as? FileAttributeType == .typeDirectory else {
            throw invalid("The update app must be a real directory, not a link.")
        }
        try verifySignature(app, identifier: bundleIdentifier)
        try run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path])
        try run("/usr/bin/xcrun", ["stapler", "validate", app.path])
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard let expected = AppVersion(version),
              let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == bundleIdentifier,
              AppVersion(info["CFBundleShortVersionString"] as? String ?? "") == expected,
              (info["MyTermReleaseChannel"] as? String ?? "stable") == channel.rawValue,
              info["MyTermChannelConfigurationVersion"] as? Int == 1 else {
            throw invalid("The staged app does not match this update or support safe configuration switching.")
        }
        try verifySignature(app.appendingPathComponent("Contents/MacOS/MyTermSessionHost"),
                            identifier: bundleIdentifier + ".session-host")
        try verifySignature(app.appendingPathComponent("Contents/MacOS/MyTermUpdateAgent"),
                            identifier: bundleIdentifier + ".update-agent")
        try run("/usr/bin/lipo", ["-verify_arch", "arm64", app.appendingPathComponent("Contents/MacOS/myterm").path])
    }

    /// Only an owner-private staging folder beside this app may supply an installation handoff.
    public static func validatePlan(_ plan: ApplicationUpdatePlan, manifest: URL) throws {
        let name = plan.directory.lastPathComponent
        let prefix = ".myterm-update-", suffix = ".noindex"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix),
              UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(suffix.count))) != nil,
              manifest.standardizedFileURL == plan.manifestURL,
              plan.directory.deletingLastPathComponent() == plan.target.deletingLastPathComponent(),
              plan.target.pathExtension == "app", plan.staged.path == plan.directory.appendingPathComponent("myterm.app").path,
              plan.target.standardizedFileURL == plan.target.resolvingSymlinksInPath(),
              plan.directory.standardizedFileURL == plan.directory.resolvingSymlinksInPath(),
              plan.staged.standardizedFileURL == plan.staged.resolvingSymlinksInPath(),
              plan.preferencesDomain == bundleIdentifier, AppVersion(plan.version) != nil,
              AppVersion(plan.sourceVersion) != nil else {
            throw invalid("Invalid update handoff paths or identity.")
        }
        for url in [plan.directory, manifest] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(),
                  let permissions = attributes[.posixPermissions] as? NSNumber,
                  permissions.intValue & 0o077 == 0 else {
                throw invalid("The prepared update is not private to your account.")
            }
        }
    }

    /// The fixed Developer ID requirement prevents a valid signature from another publisher passing.
    public static func verifySignature(_ url: URL, identifier: String) throws {
        let requirement = requirement(identifier: identifier)
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R", requirement, url.path])
    }

    /// Old shells can write completion caches inside their original bundle. The destination's
    /// executable/Info.plist identity is checked independently; all incoming payload resources
    /// and the copied updater executable still require full strict validation.
    public static func verifyInstalledIdentity(_ app: URL) throws {
        try run("/usr/bin/codesign", ["--verify", "--strict", "--ignore-resources", "-R",
                                     requirement(identifier: bundleIdentifier), app.path])
    }

    private static func requirement(identifier: String) -> String {
        "=anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"\(teamIdentifier)\" and identifier \"\(identifier)\""
    }

    /// Probe the actual app volume before asking the user to quit; unsupported volumes stay intact.
    public static func probeAtomicSwap(in directory: URL) throws {
        let a = directory.appendingPathComponent("swap-probe-a"), b = directory.appendingPathComponent("swap-probe-b")
        let files = FileManager.default
        try files.createDirectory(at: a, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: a) }
        try files.createDirectory(at: b, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: b) }
        guard renameatx_np(AT_FDCWD, a.path, AT_FDCWD, b.path, UInt32(RENAME_SWAP)) == 0 else {
            throw invalid("This app volume does not support safe atomic updates: \(String(cString: strerror(errno)))")
        }
    }

    public static func digest(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Positional process arguments keep paths and remote release metadata out of shell source.
    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 120) throws {
        let files = FileManager.default
        let logURL = files.temporaryDirectory.appendingPathComponent("myterm-update-log-\(UUID().uuidString)")
        guard files.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw invalid("Could not create a private update verification log.")
        }
        defer { try? files.removeItem(at: logURL) }
        let output = try FileHandle(forWritingTo: logURL)
        defer { try? output.close() }
        let process = Process()
        let exited = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 5) == .timedOut {
                _ = kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 5)
            }
            throw invalid("\(URL(fileURLWithPath: executable).lastPathComponent) timed out. The update was not applied.")
        }
        guard process.terminationStatus == 0 else {
            let input = try FileHandle(forReadingFrom: logURL)
            defer { try? input.close() }
            let size = try input.seekToEnd()
            try input.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
            let log = try input.read(upToCount: 65_536) ?? Data()
            throw invalid("\(URL(fileURLWithPath: executable).lastPathComponent) failed: \(String(decoding: log, as: UTF8.self))")
        }
    }

    private static func invalid(_ message: String) -> ApplicationUpdateError { .invalid(message) }
}
