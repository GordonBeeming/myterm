import Foundation
import MyTermCore
import XCTest
@testable import MyTermRemoteProtocol

/// A reminder the person set by hand on the Latest tab, and what the Mac may do to it.
final class RemoteNotificationLogHoldTests: XCTestCase {
    private func notification(tab: String, at seconds: TimeInterval, isRead: Bool = false) -> RemoteNotification {
        RemoteNotification(
            tabID: tab,
            workspaceID: "ws-1",
            workspaceTitle: "api",
            tabTitle: "build",
            activity: .finished,
            date: Date(timeIntervalSinceReferenceDate: seconds),
            isRead: isRead
        )
    }

    private func id(_ tab: String, at seconds: TimeInterval) -> RemoteNotificationLogEntry.ID {
        RemoteNotificationLogEntry.ID(tabID: tab, date: Date(timeIntervalSinceReferenceDate: seconds))
    }

    func testMarkingUnreadSurvivesTheMacSayingItWasRead() {
        var log = RemoteNotificationLog()
        log.merge(RemoteNotifications(entries: [notification(tab: "tab-1", at: 100)]))
        log.markRead(id("tab-1", at: 100))
        log.markRead(id("tab-1", at: 100), isRead: false)

        // The Mac reached the tab, and sends its history again saying so.
        log.merge(RemoteNotifications(entries: [notification(tab: "tab-1", at: 100, isRead: true)]))

        XCTAssertEqual(log.entries.map(\.isRead), [false], "a reminder the person set is theirs to clear")
        XCTAssertEqual(log.unreadCount, 1)
    }

    func testMarkingUnreadSurvivesTheMacForgettingTheEntry() {
        var log = RemoteNotificationLog()
        log.merge(RemoteNotifications(entries: [
            notification(tab: "tab-2", at: 200),
            notification(tab: "tab-1", at: 100),
        ]))
        log.markAllRead()
        log.markRead(id("tab-1", at: 100), isRead: false)

        // Another tab finishing makes the Mac send a snapshot that no longer lists tab-1.
        log.merge(RemoteNotifications(entries: [notification(tab: "tab-2", at: 200)]))

        XCTAssertEqual(log.entries.map(\.tabID), ["tab-2", "tab-1"])
        XCTAssertEqual(log.entries.map(\.isRead), [true, false])
    }

    func testReadingAgainReleasesTheHold() {
        var log = RemoteNotificationLog()
        log.merge(RemoteNotifications(entries: [notification(tab: "tab-1", at: 100)]))
        log.markRead(id("tab-1", at: 100), isRead: false)
        log.markRead(id("tab-1", at: 100))

        log.merge(RemoteNotifications(entries: []))

        XCTAssertEqual(log.entries.map(\.isRead), [true])
        XCTAssertFalse(log.entries[0].isHeldUnread)
    }

    func testMarkAllReadReleasesEveryHold() {
        var log = RemoteNotificationLog()
        log.merge(RemoteNotifications(entries: [notification(tab: "tab-1", at: 100)]))
        log.markRead(id("tab-1", at: 100), isRead: false)

        log.markAllRead()
        log.merge(RemoteNotifications(entries: [notification(tab: "tab-1", at: 100, isRead: true)]))

        XCTAssertEqual(log.entries.map(\.isRead), [true])
    }

    /// A log the previous build wrote has no hold on any entry, and must still load.
    func testALogWrittenBeforeTheHoldExistedStillDecodes() throws {
        let json = """
        {"entries":[{"tabID":"tab-1","workspaceID":"ws","workspaceTitle":"api","tabTitle":"build",
        "activity":"finished","date":100,"isRead":true}]}
        """
        let log = try JSONDecoder().decode(RemoteNotificationLog.self, from: Data(json.utf8))
        XCTAssertEqual(log.entries.count, 1)
        XCTAssertFalse(log.entries[0].isHeldUnread)
    }

    /// The cap drops the oldest, whatever its read state: an old unread entry goes before a new
    /// read one, so the list is the newest two hundred things rather than the oldest reminders.
    func testTheCapDropsTheOldestEvenWhenItIsUnread() {
        var log = RemoteNotificationLog()
        let entries = (1...RemoteNotificationLog.capacity).map {
            notification(tab: "tab-\($0)", at: TimeInterval($0), isRead: true)
        }
        log.merge(RemoteNotifications(entries: [notification(tab: "tab-0", at: 0)] + entries))
        XCTAssertEqual(log.entries.count, RemoteNotificationLog.capacity)
        XCTAssertEqual(log.entries.last?.tabID, "tab-1", "tab-0 was the oldest and the only unread one")
        XCTAssertEqual(log.unreadCount, 0)
    }

}
