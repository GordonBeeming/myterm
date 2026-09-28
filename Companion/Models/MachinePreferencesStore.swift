import Foundation
import OSLog

/// What this device remembers about one paired Mac, beyond what the pairing itself carries.
struct MachinePreference: Codable, Equatable, Sendable {
    /// A name the user typed. `nil` means the name the Mac gave at pairing time still stands.
    var alias: String?
    var isStarred: Bool
    var lastWorkspaceID: UUID?

    init(alias: String? = nil, isStarred: Bool = false, lastWorkspaceID: UUID? = nil) {
        self.alias = alias
        self.isStarred = isStarred
        self.lastWorkspaceID = lastWorkspaceID
    }

    var isEmpty: Bool { alias == nil && !isStarred && lastWorkspaceID == nil }
}

/// Aliases, stars, and the workspace each Mac was last left on, per device.
///
/// None of this belongs on `SavedHostDescriptor`: that record is pinned key material in the
/// keychain, every property is a `let`, and its initialiser enforces invariants an alias has no
/// business touching. Keying on `SavedConnectionID` also means one machine reached through two
/// relays gets two entries, which is the case that made aliases worth having.
struct MachinePreferencesStore {
    /// The longest alias accepted, in UTF-8 bytes. Well under the 256 the pairing record allows
    /// for a name, because an alias has to stay readable in a list row.
    static let aliasByteLimit = 128

    private static let storageKey = "companionMachinePreferences"
    private static let logger = Logger(subsystem: AppConfiguration.bundleIdentifier,
                                       category: "MachinePreferences")

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func preference(for connectionID: SavedConnectionID) -> MachinePreference {
        entries()[connectionID.storageKey] ?? MachinePreference()
    }

    /// Everything stored, keyed by `SavedConnectionID.storageKey`. `CompanionServices` keeps one of
    /// these as observable state so a star or a rename redraws the list; nothing about
    /// `UserDefaults` publishes a change on its own.
    func all() -> [String: MachinePreference] { entries() }

    /// Stores a typed alias, or clears it when the text is empty once trimmed.
    ///
    /// Returns `false` without writing when the alias is too long, so the caller can say so rather
    /// than silently keeping a truncated name the user did not choose.
    @discardableResult
    func setAlias(_ alias: String?, for connectionID: SavedConnectionID) -> Bool {
        let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = (trimmed?.isEmpty ?? true) ? nil : trimmed
        if let resolved, resolved.utf8.count > Self.aliasByteLimit { return false }
        update(connectionID) { $0.alias = resolved }
        return true
    }

    func setStarred(_ isStarred: Bool, for connectionID: SavedConnectionID) {
        update(connectionID) { $0.isStarred = isStarred }
    }

    func setLastWorkspaceID(_ workspaceID: UUID?, for connectionID: SavedConnectionID) {
        update(connectionID) { $0.lastWorkspaceID = workspaceID }
    }

    /// Drops everything remembered about a pairing. Called when the pairing is removed, and only
    /// then: a keychain read that fails once must never be able to erase what the user typed.
    func forget(_ connectionID: SavedConnectionID) {
        var stored = entries()
        guard stored.removeValue(forKey: connectionID.storageKey) != nil else { return }
        write(stored)
    }

    private func update(_ connectionID: SavedConnectionID,
                        _ change: (inout MachinePreference) -> Void) {
        var stored = entries()
        let key = connectionID.storageKey
        var preference = stored[key] ?? MachinePreference()
        change(&preference)
        if preference.isEmpty {
            guard stored.removeValue(forKey: key) != nil else { return }
        } else {
            guard stored[key] != preference else { return }
            stored[key] = preference
        }
        write(stored)
    }

    private func entries() -> [String: MachinePreference] {
        guard let data = defaults.data(forKey: Self.storageKey) else { return [:] }
        do {
            return try JSONDecoder().decode([String: MachinePreference].self, from: data)
        } catch {
            // Losing these costs the user their aliases, so it is worth a log line, but there is
            // nothing they can do about it and the next edit overwrites the damaged payload.
            Self.logger.error("Discarding unreadable machine preferences: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }

    private func write(_ entries: [String: MachinePreference]) {
        do {
            defaults.set(try JSONEncoder().encode(entries), forKey: Self.storageKey)
        } catch {
            Self.logger.error("Could not store the machine preference: \(error.localizedDescription, privacy: .public)")
        }
    }
}
