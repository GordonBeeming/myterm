import Foundation
import MyTermCore
import OSLog

/// The pane, and the terminal inside it, that this device last looked at in a workspace.
struct PaneSelection: Codable, Equatable, Sendable {
    var groupID: TabGroupID
    var tabID: TabID?
}

/// Remembers which pane each workspace was left on, per device.
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

    /// A stored selection paired with the counter that orders evictions once the store is full.
    private struct Entry: Codable, Equatable {
        var selection: PaneSelection
        var sequence: Int
    }

    func selection(for workspaceID: WorkspaceID) -> PaneSelection? {
        entries()[workspaceID.description]?.selection
    }

    func select(_ selection: PaneSelection, for workspaceID: WorkspaceID) {
        var stored = entries()
        let key = workspaceID.description
        guard stored[key]?.selection != selection else { return }
        let next = (stored.values.map(\.sequence).max() ?? 0) + 1
        stored[key] = Entry(selection: selection, sequence: next)
        if stored.count > Self.capacity {
            let evicted = stored.sorted { $0.value.sequence < $1.value.sequence }
                .prefix(stored.count - Self.capacity)
            for entry in evicted { stored.removeValue(forKey: entry.key) }
        }
        write(stored)
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

