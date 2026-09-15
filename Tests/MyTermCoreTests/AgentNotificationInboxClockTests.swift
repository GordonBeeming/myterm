import Foundation
import XCTest
@testable import MyTermCore

/// The inbox orders by wall-clock date, and the wall clock is not monotonic: NTP steps it, and a
/// Mac asleep for a night wakes with a date eight hours on. These pin down what each does.
final class AgentNotificationInboxClockTests: XCTestCase {
    private let workspaceID = WorkspaceID()
    private let tabGroupID = TabGroupID()

    private func record(
        _ inbox: inout AgentNotificationInbox,
        _ activity: AgentActivity = .finished,
        tabID: TabID,
        isRead: Bool = false,
        at seconds: TimeInterval
    ) {
        inbox.record(activity, workspaceID: workspaceID, tabGroupID: tabGroupID, tabID: tabID,
                     isTabVisible: isRead, date: Date(timeIntervalSince1970: seconds))
    }

    func testAClockThatStepsBackAnHourFilesTheNewerEventBelowTheOlderOne() {
        // Ordering is by the date on the entry, not by arrival. After a step back the most recent
        // arrival sits second. Documented rather than defended: nothing is lost or duplicated.
        var inbox = AgentNotificationInbox()
        let before = TabID(), after = TabID()
        record(&inbox, tabID: before, at: 10_000)
        record(&inbox, tabID: after, at: 10_000 - 3_600)
        XCTAssertEqual(inbox.items.map(\.tabID), [before, after])
        XCTAssertEqual(inbox.count, 2)
    }

    func testAClockStepDoesNotStopTheLatestReportFromSupersedingTheUnreadOne() {
        // Superseding is by tab, not by date, so the entry filed with the older date still replaces
        // the unread one, and the tab is listed once.
        var inbox = AgentNotificationInbox()
        let tab = TabID()
        record(&inbox, tabID: tab, at: 10_000)
        record(&inbox, .awaitingInput, tabID: tab, at: 10_000 - 3_600)
        XCTAssertEqual(inbox.count, 1)
        XCTAssertEqual(inbox.activity(forTab: tab), .awaitingInput)
        XCTAssertEqual(inbox.history.map(\.date), [Date(timeIntervalSince1970: 10_000 - 3_600)])
    }

    func testEvictionAfterAClockStepDropsTheOldestReadEntryByPosition() {
        // The inbox evicts from the bottom of the list, which is the oldest by date. After a step
        // back the bottom is the most recent arrival: that is what goes when the cap is hit.
        var inbox = AgentNotificationInbox()
        for second in 1...AgentNotificationInbox.capacity {
            record(&inbox, tabID: TabID(), isRead: true, at: TimeInterval(second) + 100_000)
        }
        let lateArrival = TabID()
        record(&inbox, tabID: lateArrival, isRead: true, at: 100_000 - 3_600)
        XCTAssertEqual(inbox.history.count, AgentNotificationInbox.capacity)
        XCTAssertFalse(inbox.history.contains { $0.tabID == lateArrival },
                       "the entry whose clock ran behind is the one evicted, though it arrived last")
    }

    func testAnUnreadEntryIsNeverEvictedForAReadOneWhateverTheClockSays() {
        var inbox = AgentNotificationInbox()
        let question = TabID()
        record(&inbox, .awaitingInput, tabID: question, at: 1)
        for second in 2...(AgentNotificationInbox.capacity + 20) {
            record(&inbox, tabID: TabID(), isRead: true, at: TimeInterval(second))
        }
        XCTAssertEqual(inbox.history.count, AgentNotificationInbox.capacity)
        XCTAssertEqual(inbox.history.last?.tabID, question)
    }

    func testTwoEntriesInTheSameInstantAreOrderedByArrivalAndSurviveARoundTrip() throws {
        var inbox = AgentNotificationInbox()
        let first = TabID(), second = TabID()
        record(&inbox, tabID: first, at: 500)
        record(&inbox, tabID: second, at: 500)
        XCTAssertEqual(inbox.items.map(\.tabID), [second, first], "the later arrival goes above the earlier")

        let data = try JSONEncoder().encode(inbox)
        let reloaded = try JSONDecoder().decode(AgentNotificationInbox.self, from: data)
        XCTAssertEqual(reloaded.history.map(\.tabID), [second, first], "and the file keeps that order")
        XCTAssertEqual(reloaded, inbox)
    }

    func testDatesAreStoredWithSubMillisecondPrecision() throws {
        // A step back followed by a step forward can put two events a few microseconds apart.
        // The encoder must not round them into the same identifier.
        var inbox = AgentNotificationInbox()
        let tab = TabID()
        record(&inbox, tabID: tab, isRead: true, at: 1_700_000_000.000001)
        record(&inbox, tabID: tab, isRead: true, at: 1_700_000_000.000002)
        let reloaded = try JSONDecoder().decode(AgentNotificationInbox.self, from: JSONEncoder().encode(inbox))
        XCTAssertEqual(reloaded.history.count, 2)
        XCTAssertEqual(Set(reloaded.history.map(\.id)).count, 2)
    }

    func testAnEightHourGapIsJustAnOlderEntry() {
        // A Mac asleep overnight wakes and the next report carries a date eight hours on. Nothing
        // is keyed on elapsed time, so the gap changes nothing but the sort.
        var inbox = AgentNotificationInbox()
        let beforeSleep = TabID(), afterWake = TabID()
        record(&inbox, tabID: beforeSleep, at: 0)
        record(&inbox, tabID: afterWake, at: 8 * 3_600)
        XCTAssertEqual(inbox.items.map(\.tabID), [afterWake, beforeSleep])
        XCTAssertEqual(inbox.count, 2)
    }
}
