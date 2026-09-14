import Foundation
import MyTermCore
import XCTest
@testable import MyTermRemoteProtocol

/// The device's own record of what happened, and how the Mac's backlog folds into it.
final class RemoteNotificationLogTests: XCTestCase {
    private func notification(
        tab: String,
        at seconds: TimeInterval,
        activity: AgentActivity = .finished,
        tabTitle: String = "build",
        isRead: Bool = false
    ) -> RemoteNotification {
        RemoteNotification(
            tabID: tab,
            workspaceID: "ws-1",
            workspaceTitle: "api",
            tabTitle: tabTitle,
            activity: activity,
            date: Date(timeIntervalSinceReferenceDate: seconds),
            isRead: isRead
        )
    }

    private func id(_ tab: String, at seconds: TimeInterval) -> RemoteNotificationLogEntry.ID {
        RemoteNotificationLogEntry.ID(tabID: tab, date: Date(timeIntervalSinceReferenceDate: seconds))
    }

    func testAFreshSnapshotBecomesUnreadEntriesNewestFirst() {
        var log = RemoteNotificationLog()

        log.merge(RemoteNotifications(entries: [
            notification(tab: "tab-2", at: 200, activity: .awaitingInput),
            notification(tab: "tab-1", at: 100),
        ]))

        XCTAssertEqual(log.entries.map(\.tabID), ["tab-2", "tab-1"])
        XCTAssertEqual(log.entries.map(\.isRead), [false, false])
        XCTAssertEqual(log.unreadCount, 2)
    }

    func testTheLogSortsForItselfRatherThanTrustingTheSnapshotsOrder() {
        var log = RemoteNotificationLog()

        log.merge(RemoteNotifications(entries: [
            notification(tab: "tab-1", at: 100),
            notification(tab: "tab-2", at: 200),
        ]))

        XCTAssertEqual(log.entries.map(\.tabID), ["tab-2", "tab-1"])
    }

    func testAnEntryTheMacStillListsKeepsItsReadMark() {
        var log = RemoteNotificationLog()
        log.merge(RemoteNotifications(entries: [notification(tab: "tab-1", at: 100)]))
        log.markRead(id("tab-1", at: 100))

        // The Mac sends the whole backlog again, as it does on every change and on reconnect.
        log.merge(RemoteNotifications(entries: [notification(tab: "tab-1", at: 100)]))

        XCTAssertEqual(log.entries.map(\.isRead), [true], "a resend must not make a read entry new again")
        XCTAssertEqual(log.unreadCount, 0)
    }

    func testAnEntryTheMacDroppedStaysInTheLogAsRead() {
        var log = RemoteNotificationLog()
        log.merge(RemoteNotifications(entries: [
            notification(tab: "tab-2", at: 200),
            notification(tab: "tab-1", at: 100),
        ]))

        // The user reached tab-1 on the Mac, so the Mac no longer lists it.
        log.merge(RemoteNotifications(entries: [notification(tab: "tab-2", at: 200)]))

        XCTAssertEqual(log.entries.map(\.tabID), ["tab-2", "tab-1"], "history is the point of the log")
        XCTAssertEqual(log.entries.map(\.isRead), [false, true])
    }

    func testATabThatNeedsTheUserAgainIsANewUnreadEntry() {
        var log = RemoteNotificationLog()
        log.merge(RemoteNotifications(entries: [notification(tab: "tab-1", at: 100)]))
        log.markRead(id("tab-1", at: 100))

        // The same tab finished another turn. The Mac keeps one entry per tab, so it replaces the
        // old one with a new date, and that is what makes it a new thing to read here.
        log.merge(RemoteNotifications(entries: [notification(tab: "tab-1", at: 300, activity: .awaitingInput)]))

        XCTAssertEqual(log.entries.map { $0.id }, [id("tab-1", at: 300), id("tab-1", at: 100)])
        XCTAssertEqual(log.entries.map(\.isRead), [false, true])
        XCTAssertEqual(log.unreadCount, 1)
    }

    func testAnEntryTheUserReachedOnTheMacBeforeTheDeviceConnectedArrivesAsHistory() {
        var log = RemoteNotificationLog()

        log.merge(RemoteNotifications(entries: [
            notification(tab: "tab-2", at: 200),
            notification(tab: "tab-1", at: 100, isRead: true),
        ]))

        XCTAssertEqual(log.entries.map(\.tabID), ["tab-2", "tab-1"])
        XCTAssertEqual(log.entries.map(\.isRead), [false, true])
        XCTAssertEqual(log.unreadCount, 1)
    }

    func testReachingTheTabOnTheMacReadsTheEntryHere() {
        var log = RemoteNotificationLog()
        log.merge(RemoteNotifications(entries: [notification(tab: "tab-1", at: 100)]))
        XCTAssertEqual(log.unreadCount, 1)

        log.merge(RemoteNotifications(entries: [notification(tab: "tab-1", at: 100, isRead: true)]))

        XCTAssertEqual(log.entries.map(\.isRead), [true])
        XCTAssertEqual(log.unreadCount, 0)
    }

    func testReadingHereIsNotUndoneByAMacThatStillListsTheEntryUnread() {
        var log = RemoteNotificationLog()
        log.merge(RemoteNotifications(entries: [notification(tab: "tab-1", at: 100)]))
        log.markRead(id("tab-1", at: 100))

        log.merge(RemoteNotifications(entries: [notification(tab: "tab-1", at: 100)]))

        XCTAssertEqual(log.entries.map(\.isRead), [true], "the Mac is not told about reads here, so it cannot overrule them")
    }

    func testAResendTakesTheMacsCurrentNamesForAnEntryItStillLists() {
        var log = RemoteNotificationLog()
        log.merge(RemoteNotifications(entries: [notification(tab: "tab-1", at: 100, tabTitle: "Terminal")]))

        log.merge(RemoteNotifications(entries: [notification(tab: "tab-1", at: 100, tabTitle: "deploy")]))

        XCTAssertEqual(log.entries.map(\.tabTitle), ["deploy"])
    }

    func testMarkingReadAndUnreadAndAllRead() {
        var log = RemoteNotificationLog()
        log.merge(RemoteNotifications(entries: [
            notification(tab: "tab-2", at: 200),
            notification(tab: "tab-1", at: 100),
        ]))

        log.markRead(id("tab-2", at: 200))
        XCTAssertEqual(log.entries.map(\.isRead), [true, false])

        log.markRead(id("tab-2", at: 200), isRead: false)
        XCTAssertEqual(log.entries.map(\.isRead), [false, false])

        log.markAllRead()
        XCTAssertEqual(log.entries.map(\.isRead), [true, true])
        XCTAssertEqual(log.unreadCount, 0)
    }

    func testMarkingAnEntryThatIsNotThereChangesNothing() {
        var log = RemoteNotificationLog()
        log.merge(RemoteNotifications(entries: [notification(tab: "tab-1", at: 100)]))
        let before = log

        log.markRead(id("tab-9", at: 100))

        XCTAssertEqual(log, before)
    }

    func testTheLogKeepsTheNewestEntriesUpToItsCapacity() {
        var log = RemoteNotificationLog()
        let overflow = 5
        let entries = (0..<(RemoteNotificationLog.capacity + overflow)).map {
            notification(tab: "tab-\($0)", at: TimeInterval($0))
        }

        log.merge(RemoteNotifications(entries: entries))

        XCTAssertEqual(log.entries.count, RemoteNotificationLog.capacity)
        XCTAssertEqual(log.entries.first?.tabID, "tab-\(RemoteNotificationLog.capacity + overflow - 1)")
        XCTAssertEqual(log.entries.last?.tabID, "tab-\(overflow)", "the oldest are what go")
    }

    func testTheLogSurvivesEncoding() throws {
        var log = RemoteNotificationLog()
        log.merge(RemoteNotifications(entries: [
            notification(tab: "tab-2", at: 200, activity: .awaitingInput),
            notification(tab: "tab-1", at: 100),
        ]))
        log.markRead(id("tab-1", at: 100))

        let decoded = try JSONDecoder().decode(RemoteNotificationLog.self, from: JSONEncoder().encode(log))

        XCTAssertEqual(decoded, log)
    }

    // MARK: - The store

    @MainActor
    func testTheStoreKeepsTheLogBetweenLaunches() {
        let suite = "RemoteNotificationLogTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = RemoteNotificationLogStore(defaults: defaults)
        first.merge(RemoteNotifications(entries: [
            notification(tab: "tab-2", at: 200),
            notification(tab: "tab-1", at: 100),
        ]))
        first.markRead(id("tab-1", at: 100))

        let second = RemoteNotificationLogStore(defaults: defaults)

        XCTAssertEqual(second.log, first.log)
        XCTAssertEqual(second.log.entries.map(\.isRead), [false, true], "read marks are what must survive")
    }
}
