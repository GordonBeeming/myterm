import Foundation
import MyTermCore

/// One thing that happened, as a device remembers it.
///
/// The Mac keeps its own history and says which of it the user has reached. A device keeps every
/// entry it has seen as well, so the person can scroll back through what happened even after the
/// Mac has forgotten it, and it keeps its own read mark, because reading on the phone is not
/// reaching the tab on the Mac.
public struct RemoteNotificationLogEntry: Codable, Equatable, Sendable, Identifiable {
    /// The tab and the moment together. A tab that needs the user again is a new entry, so a read
    /// one can never swallow the next thing the same tab has to say.
    public struct ID: Hashable, Codable, Sendable {
        public var tabID: String
        public var date: Date

        public init(tabID: String, date: Date) {
            self.tabID = tabID
            self.date = date
        }
    }

    public var tabID: String
    public var workspaceID: String
    public var workspaceTitle: String
    public var tabTitle: String
    public var activity: AgentActivity
    public var date: Date
    public var isRead: Bool
    /// True once the person has marked the entry unread by hand. The Mac's next snapshot would
    /// otherwise read it again the moment the Mac reached the tab or forgot the entry, and a
    /// reminder the person set on purpose would vanish on its own.
    public var isHeldUnread: Bool

    public var id: ID { ID(tabID: tabID, date: date) }

    public init(_ notification: RemoteNotification, isRead: Bool = false, isHeldUnread: Bool = false) {
        tabID = notification.tabID
        workspaceID = notification.workspaceID
        workspaceTitle = notification.workspaceTitle
        tabTitle = notification.tabTitle
        activity = notification.activity
        date = notification.date
        self.isRead = isRead
        self.isHeldUnread = isHeldUnread
    }

    private enum CodingKeys: String, CodingKey {
        case tabID, workspaceID, workspaceTitle, tabTitle, activity, date, isRead, isHeldUnread
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tabID = try container.decode(String.self, forKey: .tabID)
        workspaceID = try container.decode(String.self, forKey: .workspaceID)
        workspaceTitle = try container.decode(String.self, forKey: .workspaceTitle)
        tabTitle = try container.decode(String.self, forKey: .tabTitle)
        activity = try container.decode(AgentActivity.self, forKey: .activity)
        date = try container.decode(Date.self, forKey: .date)
        isRead = try container.decode(Bool.self, forKey: .isRead)
        // A log written before the hold existed has no entries held.
        isHeldUnread = try container.decodeIfPresent(Bool.self, forKey: .isHeldUnread) ?? false
    }
}

/// What has happened, newest first, and which of it the person has looked at.
///
/// Pure: every rule about what a host snapshot does to the list lives here, where it is tested
/// without a socket or a screen. `RemoteNotificationLogStore` is the shell that persists it.
public struct RemoteNotificationLog: Codable, Equatable, Sendable {
    /// Enough to scroll back through a busy day, small enough that the list stays a list.
    public static let capacity = 200

    /// Newest first, which is the order the person reads through.
    public private(set) var entries: [RemoteNotificationLogEntry]

    public init(entries: [RemoteNotificationLogEntry] = []) {
        self.entries = Self.trimmed(entries)
    }

    private enum CodingKeys: String, CodingKey {
        case entries
    }

    /// A saved log is read one entry at a time, so a row a newer build wrote with an activity this
    /// build has no name for costs that row rather than the whole log. A row listed twice is one
    /// row, and what comes back is ordered and trimmed as the log keeps itself.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var list = try container.nestedUnkeyedContainer(forKey: .entries)
        var read: [RemoteNotificationLogEntry] = []
        var seen: Set<RemoteNotificationLogEntry.ID> = []
        while !list.isAtEnd {
            guard let entry = try? list.decode(RemoteNotificationLogEntry.self) else {
                _ = try? list.superDecoder()
                continue
            }
            if seen.insert(entry.id).inserted {
                read.append(entry)
            }
        }
        entries = Self.trimmed(read)
    }

    public var unreadCount: Int { entries.filter { !$0.isRead }.count }
    public var isEmpty: Bool { entries.isEmpty }

    /// Folds the Mac's current history into what the device already knows.
    ///
    /// An entry the Mac lists and the device has not seen is new, and as read as the Mac says: one
    /// the user reached on the Mac before the device connected arrives as history. One the device
    /// already has takes the Mac's current names, so a renamed tab renames the row, and is read if
    /// either side has read it: reading on the device is not undone by a Mac that does not know.
    /// One the device has that the Mac no longer lists was forgotten there, or the agent moved on,
    /// so it is read: either way the person has nothing left to do about it. An entry the person
    /// marked unread by hand is the one exception: only they can read it again.
    public mutating func merge(_ snapshot: RemoteNotifications) {
        let listed = Set(snapshot.entries.map { RemoteNotificationLogEntry.ID(tabID: $0.tabID, date: $0.date) })
        var merged = entries
        for index in merged.indices where !listed.contains(merged[index].id) && !merged[index].isHeldUnread {
            merged[index].isRead = true
        }
        for notification in snapshot.entries {
            let id = RemoteNotificationLogEntry.ID(tabID: notification.tabID, date: notification.date)
            if let index = merged.firstIndex(where: { $0.id == id }) {
                let isHeldUnread = merged[index].isHeldUnread
                let isRead = !isHeldUnread && (merged[index].isRead || notification.isRead)
                merged[index] = RemoteNotificationLogEntry(notification, isRead: isRead, isHeldUnread: isHeldUnread)
            } else {
                merged.append(RemoteNotificationLogEntry(notification, isRead: notification.isRead))
            }
        }
        entries = Self.trimmed(merged)
    }

    public mutating func markRead(_ id: RemoteNotificationLogEntry.ID, isRead: Bool = true) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].isRead = isRead
        entries[index].isHeldUnread = !isRead
    }

    public mutating func markAllRead() {
        for index in entries.indices {
            entries[index].isRead = true
            entries[index].isHeldUnread = false
        }
    }

    /// Newest first, and no more than the log keeps. Two entries in the same instant keep the
    /// order they arrived in, which is the order the Mac listed them.
    private static func trimmed(_ entries: [RemoteNotificationLogEntry]) -> [RemoteNotificationLogEntry] {
        let sorted = entries.enumerated().sorted { lhs, rhs in
            if lhs.element.date != rhs.element.date {
                return lhs.element.date > rhs.element.date
            }
            return lhs.offset < rhs.offset
        }
        return Array(sorted.map(\.element).prefix(capacity))
    }
}

/// Keeps the log between launches, and publishes it for SwiftUI.
@MainActor
@Observable
public final class RemoteNotificationLogStore {
    public private(set) var log: RemoteNotificationLog

    private let defaults: UserDefaults
    private let defaultsKey: String

    public init(defaults: UserDefaults = .standard, defaultsKey: String = "remote.notificationLog") {
        self.defaults = defaults
        self.defaultsKey = defaultsKey
        log = Self.load(from: defaults, key: defaultsKey)
    }

    public func merge(_ snapshot: RemoteNotifications) {
        log.merge(snapshot)
        persist()
    }

    public func markRead(_ id: RemoteNotificationLogEntry.ID, isRead: Bool = true) {
        log.markRead(id, isRead: isRead)
        persist()
    }

    public func markAllRead() {
        log.markAllRead()
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(log) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    private static func load(from defaults: UserDefaults, key: String) -> RemoteNotificationLog {
        guard let data = defaults.data(forKey: key),
              let log = try? JSONDecoder().decode(RemoteNotificationLog.self, from: data)
        else {
            return RemoteNotificationLog()
        }
        return log
    }
}
