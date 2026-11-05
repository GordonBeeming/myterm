import Foundation

/// Keeps stable rollback state outside the shared configuration that beta is allowed to change.
@MainActor
public final class ChannelConfigurationStore {
    public enum StableChoice: String, Codable, CaseIterable, Sendable {
        case restoreStable
        case tryBeta
    }

    private struct Snapshot: Codable {
        var workspace: Data?
        var preferences: Data
        var notifications: Data?
    }
    private struct Pending: Codable {
        var choice: StableChoice
        var restored = false
        var notice: String?
    }
    public let directory: URL
    public let preferencesDomain: String
    private let files: FileManager
    private var stableURL: URL { directory.appendingPathComponent("last-stable-configuration.json") }
    private var pendingURL: URL { directory.appendingPathComponent("pending-stable-configuration.json") }
    public var hasStableSnapshot: Bool { files.fileExists(atPath: stableURL.path) }

    public init(directory: URL, preferencesDomain: String, files: FileManager = .default) {
        self.directory = directory
        self.preferencesDomain = preferencesDomain
        self.files = files
    }

    /// Called after the stable app has exited and flushed its final workspace state.
    public func captureStable() throws {
        let snapshot = try stableCapture()
        try JSONEncoder().encode(snapshot).write(to: stableURL, options: .atomic)
        try protect(stableURL)
    }

    /// Preflight while the UI is still alive; capture is repeated after its final save on quit.
    public func checkStableCapture() throws { _ = try stableCapture() }

    /// The incoming app's decoder must understand the fallback before a channel switch can commit.
    public func checkStableSnapshot() throws {
        try validate(JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: stableURL)))
    }

    /// A trial of beta settings needs a fallback only when the incoming decoder rejects current data.
    public func checkIncomingConfiguration(mode: String) throws {
        switch mode {
        case "stable": try checkStableSnapshot()
        case "current": try validate(capture())
        case "try-beta":
            do { try validate(capture()) }
            catch { try checkStableSnapshot() }
        default: throw failure("Unknown configuration check mode.")
        }
    }

    /// The installer preserves the final saved state before every binary update, including beta-to-beta.
    public func captureUpdateTrial(to url: URL) throws {
        try JSONEncoder().encode(capture()).write(to: url, options: .atomic)
        try protect(url)
    }

    /// Undo a failed update using the exact bytes belonging to its previous executable.
    public func restoreUpdateTrial(from url: URL, selectedChannel: UpdateCheck.Channel) throws {
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url))
        try restoreSnapshot(snapshot, selectedChannel: selectedChannel, allowMissingWorkspace: true)
        try cancelStableReturn()
    }

    /// Validate the final stable state, using a fresh in-memory workspace for a new installation.
    private func stableCapture() throws -> Snapshot {
        var snapshot = try capture()
        if snapshot.workspace == nil {
            snapshot.workspace = try JSONEncoder().encode(WorkspaceStoreSnapshot.initial())
        }
        try validate(snapshot)
        return snapshot
    }

    /// A durable marker lets the target stable version validate using its own schema decoder.
    public func scheduleStableReturn(_ choice: StableChoice) throws {
        guard choice == .tryBeta || hasStableSnapshot else { throw failure("There is no stable configuration snapshot to fall back to.") }
        try JSONEncoder().encode(Pending(choice: choice)).write(to: pendingURL, options: .atomic)
        try protect(pendingURL)
    }

    /// Runs under the app's single-instance lease before any model can repair or save the store.
    public func prepareStableLaunch() throws -> String? {
        guard files.fileExists(atPath: pendingURL.path) else { return nil }
        let current = try capture()
        let preserved = directory.appendingPathComponent("beta-configuration-before-stable.json")
        if !files.fileExists(atPath: preserved.path) {
            try JSONEncoder().encode(current).write(to: preserved, options: .atomic)
            try protect(preserved)
        }
        var writesStarted = false
        do {
            var pending = try JSONDecoder().decode(Pending.self, from: Data(contentsOf: pendingURL))
            if pending.restored { try validate(current); return pending.notice }
            var notice: String?
            var restore = pending.choice == .restoreStable
            if !restore {
                do { try validate(current) }
                catch {
                    restore = true
                    notice = "The beta configuration could not be loaded by stable. Switched to your last stable configuration. \(error.localizedDescription)"
                }
            }
            if restore {
                let stable = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: stableURL))
                try validate(stable)
                writesStarted = true
                try restoreSnapshot(stable)
                notice = notice ?? "Restored your last stable configuration. Your beta configuration was preserved as a backup."
            }
            pending.restored = restore
            pending.notice = notice
            try JSONEncoder().encode(pending).write(to: pendingURL, options: .atomic)
            try protect(pendingURL)
            return notice
        } catch {
            let restoreError = error
            if writesStarted {
                do { try restoreSnapshot(current) }
                catch { throw failure("Stable restore and rollback failed. Your beta configuration is preserved at \(preserved.path). Use Restore Configuration Backup to recover. \(error.localizedDescription)") }
            }
            // Only continue with existing data if this stable decoder can load it without loss.
            // Otherwise startup exposes manual backup recovery instead of overwriting anything.
            do { try validate(current) }
            catch { throw failure("Neither the current configuration nor the stable backup could be loaded. Your beta configuration is preserved at \(preserved.path). Use Restore Configuration Backup. \(restoreError.localizedDescription)") }
            let quarantined = directory.appendingPathComponent("failed-stable-switch-\(UUID().uuidString).json")
            try files.moveItem(at: pendingURL, to: quarantined)
            return "The stable configuration snapshot could not be restored. Kept your compatible current configuration. \(restoreError.localizedDescription)"
        }
    }

    /// Keep the switch armed until the actual stable app model has loaded, not merely its JSON.
    public func loadStable<Value>(_ load: () throws -> Value) throws -> (Value, String?) {
        var notice = try prepareStableLaunch()
        let value: Value
        do { value = try load() }
        catch {
            guard files.fileExists(atPath: pendingURL.path) else { throw error }
            var pending = try JSONDecoder().decode(Pending.self, from: Data(contentsOf: pendingURL))
            guard pending.choice == .tryBeta, !pending.restored else { throw error }
            let failedLoad = error
            guard hasStableSnapshot else {
                throw failure("Stable could not load the beta configuration and this installation has no previous stable snapshot. Your beta bytes were preserved. Use Restore Configuration Backup to recover.")
            }
            let stable = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: stableURL))
            try validate(stable)
            let preservedURL = directory.appendingPathComponent("beta-configuration-before-stable.json")
            let preserved = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: preservedURL))
            do {
                try restoreSnapshot(stable)
                pending.restored = true
                pending.notice = "The beta configuration failed during stable startup. Switched to your last stable configuration. \(failedLoad.localizedDescription)"
                try JSONEncoder().encode(pending).write(to: pendingURL, options: .atomic)
                try protect(pendingURL)
            } catch {
                do { try restoreSnapshot(preserved) }
                catch { throw failure("Could not finish configuration rollback. Your beta bytes are preserved at \(preservedURL.path). Use Restore Configuration Backup.") }
                throw error
            }
            notice = pending.notice
            value = try load()
        }
        try completeStableLaunch()
        return (value, notice)
    }

    /// A failed load leaves the marker intact so recovery can be retried without losing its backup.
    public func completeStableLaunch() throws {
        if files.fileExists(atPath: pendingURL.path) { try files.removeItem(at: pendingURL) }
    }

    /// An explicit recovery file is validated before replacing any current configuration.
    public func restoreBackup(from url: URL, selectedChannel: UpdateCheck.Channel = .stable) throws {
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        var restored: Snapshot
        if object?["preferences"] != nil, object?["workspace"] != nil {
            restored = try JSONDecoder().decode(Snapshot.self, from: data)
        } else {
            restored = try capture()
            restored.workspace = data
        }
        try validate(restored)
        let preserved = directory.appendingPathComponent("configuration-before-manual-recovery-\(UUID().uuidString).json")
        try JSONEncoder().encode(capture()).write(to: preserved, options: .atomic)
        try protect(preserved)
        let original = try capture()
        do {
            try restoreSnapshot(restored, selectedChannel: selectedChannel)
            if files.fileExists(atPath: pendingURL.path) { try files.removeItem(at: pendingURL) }
        } catch {
            let restoreError = error
            do { try restoreSnapshot(original, selectedChannel: selectedChannel, allowMissingWorkspace: true) }
            catch { throw failure("Manual restore and rollback could not finish. The original bytes remain at \(preserved.path). \(error.localizedDescription)") }
            throw restoreError
        }
    }

    /// A failed application swap must not leave a configuration switch armed for a later launch.
    public func cancelStableReturn() throws {
        if files.fileExists(atPath: pendingURL.path) { try files.removeItem(at: pendingURL) }
    }

    /// Remove an obsolete beta preservation only when starting a new, explicit channel switch.
    public func beginStableReturn(_ choice: StableChoice) throws {
        let preserved = directory.appendingPathComponent("beta-configuration-before-stable.json")
        if files.fileExists(atPath: preserved.path) {
            let archived = directory.appendingPathComponent("beta-configuration-\(UUID().uuidString).json")
            try files.moveItem(at: preserved, to: archived)
        }
        try scheduleStableReturn(choice)
    }

    /// Preserve exact workspace and inbox bytes together with the current preferences domain.
    private func capture() throws -> Snapshot {
        let domain = UserDefaults.standard.persistentDomain(forName: preferencesDomain) ?? [:]
        let preferences = try PropertyListSerialization.data(fromPropertyList: domain, format: .binary, options: 0)
        let notifications = directory.appendingPathComponent("agent-notifications.json")
        let workspaceURL = directory.appendingPathComponent("workspace-state.json")
        return try Snapshot(
            workspace: files.fileExists(atPath: workspaceURL.path) ? Data(contentsOf: workspaceURL) : nil,
            preferences: preferences,
            notifications: files.fileExists(atPath: notifications.path) ? Data(contentsOf: notifications) : nil
        )
    }

    /// Use a scratch store to reject repairs, unknown beta fields and unreadable preferences without changing live data.
    private func validate(_ snapshot: Snapshot) throws {
        guard let workspace = snapshot.workspace else { throw failure("The workspace configuration file is missing.") }
        let scratch = directory.appendingPathComponent(".configuration-validation-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: scratch) }
        let url = scratch.appendingPathComponent("workspace-state.json")
        try workspace.write(to: url)
        let report = try WorkspaceStore(persistenceURL: url).loadReport
        guard try WorkspaceStore.unrecognizedKeyCount(in: workspace) == 0 else {
            throw failure("This configuration contains beta fields that this app cannot preserve.")
        }
        guard report.droppedElementCount == 0, report.identifierRepairCount == 0, report.structuralRepairCount == 0 else {
            throw failure("This configuration requires repairs that could discard beta settings or workspaces.")
        }
        if let notifications = snapshot.notifications {
            _ = try JSONDecoder().decode(AgentNotificationInbox.self, from: notifications)
        }
        guard try PropertyListSerialization.propertyList(from: snapshot.preferences, format: nil) is [String: Any] else {
            throw failure("The saved application preferences are invalid.")
        }
    }

    /// Restore a checkpoint and its selected channel; callers retain the original checkpoint if any write fails.
    private func restoreSnapshot(_ snapshot: Snapshot, selectedChannel: UpdateCheck.Channel = .stable, allowMissingWorkspace: Bool = false) throws {
        guard snapshot.workspace != nil || allowMissingWorkspace else { throw failure("The stable workspace snapshot is missing.") }
        guard var preferences = try PropertyListSerialization.propertyList(from: snapshot.preferences, format: nil) as? [String: Any] else {
            throw failure("The saved application preferences are invalid.")
        }
        preferences["updates.selectedChannel"] = selectedChannel.rawValue
        preferences.removeValue(forKey: "updates.stagedManifest")
        UserDefaults.standard.setPersistentDomain(preferences, forName: preferencesDomain)
        guard UserDefaults.standard.synchronize() else { throw failure("Could not save the restored stable preferences.") }
        let notifications = directory.appendingPathComponent("agent-notifications.json")
        if let data = snapshot.notifications { try data.write(to: notifications, options: .atomic) }
        else if files.fileExists(atPath: notifications.path) { try files.removeItem(at: notifications) }
        let workspace = directory.appendingPathComponent("workspace-state.json")
        if let data = snapshot.workspace { try data.write(to: workspace, options: .atomic) }
        else if files.fileExists(atPath: workspace.path) { try files.removeItem(at: workspace) }
    }

    private func protect(_ url: URL) throws { try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
    private func failure(_ message: String) -> NSError {
        NSError(domain: "MyTermChannelConfiguration", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
