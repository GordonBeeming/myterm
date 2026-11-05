import Darwin
import Foundation
import MyTermCore

/// The new app acknowledges its actual window/model startup. LaunchServices accepting `open`
/// is not a commit point. The private nonce also binds a deferred, install-on-quit trial.
public enum UpdateStartupTrial {
    private struct Record: Codable { let manifest: URL; let id: UUID }
    public struct Receipt: Codable, Sendable {
        public enum Phase: String, Codable, Sendable { case starting, loaded, failed }
        public let id: UUID
        public let phase: Phase
        public let pid: Int32
        public let seconds: UInt64
        public let microseconds: UInt64
        public let message: String?
    }

    private static func recordURL(_ directory: URL) -> URL { directory.appendingPathComponent("update-trial.json") }
    public static func receiptURL(_ plan: ApplicationUpdatePlan) -> URL { plan.directory.appendingPathComponent("startup-receipt.json") }

    /// Reset attempt receipts before preserving the final state that the previous app saved.
    @MainActor public static func begin(_ plan: ApplicationUpdatePlan) throws {
        let receipt = receiptURL(plan)
        if FileManager.default.fileExists(atPath: receipt.path) { try FileManager.default.removeItem(at: receipt) }
        try ChannelConfigurationStore(directory: plan.configurationDirectory, preferencesDomain: plan.preferencesDomain)
            .captureUpdateTrial(to: plan.directory.appendingPathComponent("configuration-before-update.json"))
        try JSONEncoder().encode(Record(manifest: plan.manifestURL, id: plan.id))
            .write(to: recordURL(plan.configurationDirectory), options: .atomic)
    }

    /// Pending trials retain their rollback images even when no installer process is alive.
    public static func activeManifest(in directory: URL) -> URL? {
        guard let data = try? Data(contentsOf: recordURL(directory)),
              let record = try? JSONDecoder().decode(Record.self, from: data) else { return nil }
        return record.manifest
    }

    /// Only the expected installed binary and profile can acknowledge this trial.
    public static func pending(in directory: URL, app: URL, version: String, channel: UpdateCheck.Channel) throws -> ApplicationUpdatePlan? {
        let marker = recordURL(directory)
        guard FileManager.default.fileExists(atPath: marker.path) else { return nil }
        let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: marker))
        let plan = try JSONDecoder().decode(ApplicationUpdatePlan.self, from: Data(contentsOf: record.manifest))
        try ApplicationUpdate.validatePlan(plan, manifest: record.manifest)
        guard plan.id == record.id, plan.target == app, plan.configurationDirectory == directory,
              AppVersion(plan.version) == AppVersion(version), plan.channel == channel else { return nil }
        return plan
    }

    /// A process-generation stamp prevents rollback from terminating a reused PID.
    public static func report(_ phase: Receipt.Phase, plan: ApplicationUpdatePlan, message: String? = nil) throws {
        var info = proc_bsdinfo()
        guard proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size else {
            throw ApplicationUpdateError.invalid("Could not identify the update startup process.")
        }
        let receipt = Receipt(id: plan.id, phase: phase, pid: getpid(), seconds: info.pbi_start_tvsec,
                              microseconds: info.pbi_start_tvusec, message: message)
        try JSONEncoder().encode(receipt).write(to: receiptURL(plan), options: .atomic)
    }

    /// A receipt from a different update is never accepted as this update's readiness proof.
    public static func readReceipt(_ plan: ApplicationUpdatePlan) -> Receipt? {
        guard let data = try? Data(contentsOf: receiptURL(plan)),
              let receipt = try? JSONDecoder().decode(Receipt.self, from: data), receipt.id == plan.id else { return nil }
        return receipt
    }

    /// A monitor is unique even when several app launch requests race with the installer.
    public static func monitorLock(_ plan: ApplicationUpdatePlan) throws -> Int32? {
        let path = plan.directory.appendingPathComponent("startup-monitor.lock").path
        let descriptor = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ApplicationUpdateError.invalid("Could not create the update startup monitor.") }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1 else {
            close(descriptor)
            throw ApplicationUpdateError.invalid("Unsafe update startup monitor path.")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK { return nil }
            throw ApplicationUpdateError.invalid("Could not lock the update startup monitor.")
        }
        return descriptor
    }

    /// An acknowledged PID must still be this user's expected executable, not a reused process ID.
    public static func matches(_ receipt: Receipt, plan: ApplicationUpdatePlan) -> Bool {
        var info = proc_bsdinfo()
        guard receipt.pid > 0,
              proc_pidinfo(receipt.pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
              info.pbi_uid == geteuid(), info.pbi_start_tvsec == receipt.seconds,
              info.pbi_start_tvusec == receipt.microseconds else { return false }
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(receipt.pid, &path, UInt32(path.count)) > 0 else { return false }
        return String(cString: path) == plan.target.appendingPathComponent("Contents/MacOS/myterm").path
    }

    /// Readiness is a window/model acknowledgement, not LaunchServices' successful exit status.
    public static func waitForStartup(_ plan: ApplicationUpdatePlan, seconds: TimeInterval = 120) throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            if let receipt = readReceipt(plan) {
                if receipt.phase == .loaded { return }
                if receipt.phase == .failed {
                    throw ApplicationUpdateError.startupFailed(receipt.message ?? "The new app could not finish startup.")
                }
                if !matches(receipt, plan: plan) {
                    throw ApplicationUpdateError.startupFailed("The new app exited before confirming startup.")
                }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw ApplicationUpdateError.startupFailed("The new app did not confirm a usable startup in time.")
    }

    /// Stop only the bound unconfirmed UI; persistent terminal helpers are never signalled.
    public static func stopUnconfirmedApp(_ plan: ApplicationUpdatePlan) throws {
        guard let receipt = readReceipt(plan), receipt.phase != .loaded, matches(receipt, plan: plan) else { return }
        _ = kill(receipt.pid, SIGTERM)
        do { try ApplicationUpdate.waitForExit(receipt.pid, seconds: 5) }
        catch {
            guard matches(receipt, plan: plan) else { return }
            _ = kill(receipt.pid, SIGKILL)
            try ApplicationUpdate.waitForExit(receipt.pid, seconds: 5)
        }
    }

    /// A completing older helper cannot consume a newer trial's marker.
    public static func clear(_ plan: ApplicationUpdatePlan) throws {
        let marker = recordURL(plan.configurationDirectory)
        if let data = try? Data(contentsOf: marker),
           let record = try? JSONDecoder().decode(Record.self, from: data), record.id == plan.id {
            try FileManager.default.removeItem(at: marker)
        }
    }

    /// Rollback files become pruneable only after the new app has confirmed startup.
    public static func commit(_ plan: ApplicationUpdatePlan) throws {
        try Data("applied".utf8).write(to: plan.directory.appendingPathComponent("applied"), options: .atomic)
        try clear(plan)
    }

    /// Used by the detached monitor when a quiet install's first later launch fails.
    @MainActor public static func rollback(_ plan: ApplicationUpdatePlan) throws {
        try ApplicationUpdate.verifyInstalledIdentity(plan.staged)
        let config = ChannelConfigurationStore(directory: plan.configurationDirectory, preferencesDomain: plan.preferencesDomain)
        try config.captureUpdateTrial(to: plan.directory.appendingPathComponent("failed-configuration.json"))
        try ApplicationUpdate.exchange(plan.target, plan.staged)
        try config.restoreUpdateTrial(from: plan.directory.appendingPathComponent("configuration-before-update.json"), selectedChannel: plan.sourceChannel)
        try clear(plan)
        try Data("rolled back".utf8).write(to: plan.directory.appendingPathComponent("superseded"), options: .atomic)
    }
}
