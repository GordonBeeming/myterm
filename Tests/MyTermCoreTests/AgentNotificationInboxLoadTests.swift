import Foundation
import XCTest
@testable import MyTermCore

/// The history file as something other than what this version wrote: longer than the cap, or
/// out of the order the cap relies on.
final class AgentNotificationInboxLoadTests: XCTestCase {
    private let workspaceID = WorkspaceID()
    private let tabGroupID = TabGroupID()

    private func inbox(entries: Int) throws -> Data {
        var inbox = AgentNotificationInbox()
        for index in 0..<min(entries, AgentNotificationInbox.capacity) {
            inbox.record(
                .finished, workspaceID: workspaceID, tabGroupID: tabGroupID, tabID: TabID(),
                isTabVisible: index.isMultiple(of: 2), date: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        let data = try JSONEncoder().encode(inbox)
        guard entries > AgentNotificationInbox.capacity else { return data }
        // Past the cap, the file is written by hand: the encoder has never seen one this long.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var list = try XCTUnwrap(object["entries"] as? [[String: Any]])
        let template = try XCTUnwrap(list.last)
        for index in list.count..<entries {
            var entry = template
            entry["tabID"] = UUID().uuidString
            entry["date"] = try XCTUnwrap(template["date"] as? Double) - Double(index)
            list.append(entry)
        }
        object["entries"] = list
        return try JSONSerialization.data(withJSONObject: object)
    }

    func testAHistoryLongerThanTheCapIsCutToTheCapOnLoadKeepingTheNewest() throws {
        // A device keeps 200 too, so anything past it is dropped on arrival anyway; sending it
        // costs the wire and reading it costs every launch until the next entry trims it.
        let data = try inbox(entries: 500)
        let loaded = try JSONDecoder().decode(AgentNotificationInbox.self, from: data)

        XCTAssertEqual(loaded.history.count, AgentNotificationInbox.capacity)
        let dates = loaded.history.map(\.date)
        XCTAssertEqual(dates, dates.sorted(by: >), "newest first, as the bell lists them")
        XCTAssertEqual(dates.first, Date(timeIntervalSince1970: 199))
    }

    func testAHistoryAtTheCapLoadsWhole() throws {
        let data = try inbox(entries: AgentNotificationInbox.capacity)
        let loaded = try JSONDecoder().decode(AgentNotificationInbox.self, from: data)
        XCTAssertEqual(loaded.history.count, AgentNotificationInbox.capacity)
        XCTAssertEqual(loaded.count, AgentNotificationInbox.capacity / 2, "read marks survive the round trip")
    }

    func testAHistoryFileInTheWrongOrderIsPutInOrderOnLoad() throws {
        // `insert` finds the place for a new entry by scanning for the first older one, which
        // only works while the list is newest first. A file edited by hand, or written by another
        // version, must not leave a new entry filed in the middle of history.
        let data = try inbox(entries: 3)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["entries"] = Array(try XCTUnwrap(object["entries"] as? [[String: Any]]).reversed())
        var loaded = try JSONDecoder().decode(AgentNotificationInbox.self, from: JSONSerialization.data(withJSONObject: object))

        loaded.record(
            .awaitingInput, workspaceID: workspaceID, tabGroupID: tabGroupID, tabID: TabID(),
            isTabVisible: false, date: Date(timeIntervalSince1970: 1.5)
        )

        let dates = loaded.history.map(\.date.timeIntervalSince1970)
        XCTAssertEqual(dates, [2, 1.5, 1, 0])
    }
}
