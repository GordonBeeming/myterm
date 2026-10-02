import Foundation
import MyTermCore
import OSLog

/// The pane, and the terminal inside it, that this device last looked at in a workspace.
struct PaneSelection: Codable, Equatable, Sendable {
    var groupID: TabGroupID
    var tabID: TabID?
}

/// How this device last viewed each workspace: which pane the compact layout was left on, and
/// which pane the wide layout was left maximised to.
///
/// Both answer "what was I looking at here", and both are this device's business rather than the
/// Mac's, so they share one record per workspace and one eviction order.
///
/// The compact layout shows one pane at a time, so it needs its own answer to "which pane".
/// The Mac's focused pane is deliberately not that answer: following it made every visit land
/// wherever the desktop happened to be. Without a remembered choice the first pane in layout
/// order wins, which is stable across visits and matches the pane numbering in the picker.
struct PaneSelectionStore {
    private static let storageKey = "companionPaneSelections"
    private static let capacity = 50
    private static let logger = Logger(subsystem: AppConfiguration.bundleIdentifier,
                                       category: "PaneSelection")

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// What was remembered for one workspace, paired with the counter that orders evictions once
    /// the store is full.
    ///
    /// Both remembered values are optional because they are set independently: a wide layout
    /// maximises a pane without ever choosing a compact one, and a compact layout the other way
    /// round. An entry holding neither is removed rather than left taking one of the slots.
    private struct Entry: Codable, Equatable {
        var selection: PaneSelection?
        var sequence: Int
        var maximizedGroupID: TabGroupID?

        var isEmpty: Bool { selection == nil && maximizedGroupID == nil }
    }

    func selection(for workspaceID: WorkspaceID) -> PaneSelection? {
        entries()[workspaceID.description]?.selection
    }

    /// The pane the wide layout was left maximised to, if any.
    func maximizedGroupID(for workspaceID: WorkspaceID) -> TabGroupID? {
        entries()[workspaceID.description]?.maximizedGroupID
    }

    func select(_ selection: PaneSelection, for workspaceID: WorkspaceID) {
        // Rewritten even when the choice is unchanged: picking a workspace again is what makes it
        // recent, and the cap evicts in that order.
        update(workspaceID, bumpingRecency: true) { $0.selection = selection }
    }

    /// Stores the maximised pane, or clears it when `groupID` is nil.
    func setMaximizedGroupID(_ groupID: TabGroupID?, for workspaceID: WorkspaceID) {
        update(workspaceID, bumpingRecency: groupID != nil) { $0.maximizedGroupID = groupID }
    }

    /// Forgets the pane this workspace was left on, keeping anything else remembered about it.
    func clearSelection(for workspaceID: WorkspaceID) {
        update(workspaceID, bumpingRecency: false) { $0.selection = nil }
    }

    func clear(for workspaceID: WorkspaceID) {
        var stored = entries()
        guard stored.removeValue(forKey: workspaceID.description) != nil else { return }
        write(stored)
    }

    /// Resolves the pane and terminal to show, repairing a remembered choice the Mac has since closed.
    func resolve(in workspace: RemoteWorkspaceItem,
                 preferring override: PaneSelection? = nil) -> (RemoteTabGroupProjection, RemoteTabProjection)? {
        let remembered = override ?? selection(for: workspace.id)
        let group = workspace.groups.first { $0.id == remembered?.groupID } ?? workspace.groups.first
        guard let group else { return nil }
        let tab = group.tabs.first { $0.id == remembered?.tabID }
            ?? group.tabs.first { $0.id == group.selectedTabID }
            ?? group.tabs.first
        guard let tab else { return nil }
        return (group, tab)
    }

    private func update(_ workspaceID: WorkspaceID, bumpingRecency: Bool,
                        _ change: (inout Entry) -> Void) {
        var stored = entries()
        let key = workspaceID.description
        let existing = stored[key]
        var entry = existing ?? Entry(selection: nil, sequence: 0, maximizedGroupID: nil)
        change(&entry)
        if bumpingRecency {
            entry.sequence = (stored.values.map(\.sequence).max() ?? 0) + 1
        }
        if entry.isEmpty {
            guard stored.removeValue(forKey: key) != nil else { return }
        } else {
            guard entry != existing else { return }
            stored[key] = entry
        }
        if stored.count > Self.capacity {
            let evicted = stored.sorted { $0.value.sequence < $1.value.sequence }
                .prefix(stored.count - Self.capacity)
            for entry in evicted { stored.removeValue(forKey: entry.key) }
        }
        write(stored)
    }

    private func entries() -> [String: Entry] {
        guard let data = defaults.data(forKey: Self.storageKey) else { return [:] }
        do {
            return try JSONDecoder().decode([String: Entry].self, from: data)
        } catch {
            // Unreadable memory is not worth surfacing to the user; the next visit starts at the
            // first pane and the next selection overwrites the damaged payload.
            Self.logger.error("Discarding unreadable pane selections: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }

    private func write(_ entries: [String: Entry]) {
        do {
            defaults.set(try JSONEncoder().encode(entries), forKey: Self.storageKey)
        } catch {
            Self.logger.error("Could not store the pane selection: \(error.localizedDescription, privacy: .public)")
        }
    }
}
