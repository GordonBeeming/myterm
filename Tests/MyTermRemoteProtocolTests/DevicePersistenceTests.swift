import Foundation
import MyTermCore
import XCTest
@testable import MyTermRemoteProtocol

/// What the device keeps in `UserDefaults`, read back after a newer build, an older build, or a
/// crash has been at it. One row that cannot be read must not take the rest with it.
@MainActor
final class DevicePersistenceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "myterm-device-persistence-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private final class MemoryTokens: SavedConnectionTokenStoring, @unchecked Sendable {
        private var tokens: [UUID: String] = [:]
        func saveToken(_ token: String, forConnectionID id: UUID) { tokens[id] = token }
        func readToken(forConnectionID id: UUID) -> String? { tokens[id] }
        func deleteToken(forConnectionID id: UUID) { tokens.removeValue(forKey: id) }
    }

    private func notification(tab: String, at seconds: TimeInterval, isRead: Bool = false) -> RemoteNotification {
        RemoteNotification(tabID: tab, workspaceID: "ws", workspaceTitle: "api", tabTitle: "build",
                           activity: .finished, date: Date(timeIntervalSinceReferenceDate: seconds), isRead: isRead)
    }

    private func objects<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }

    // MARK: - The notification log

    func testALogEntryWithAnActivityThisBuildDoesNotKnowIsSkippedNotFatal() throws {
        var log = RemoteNotificationLog()
        log.merge(RemoteNotifications(entries: [notification(tab: "known", at: 100)]))
        var document = try XCTUnwrap(objects(log) as? [String: Any])
        var entries = try XCTUnwrap(document["entries"] as? [[String: Any]])
        var unknown = entries[0]
        unknown["tabID"] = "newer"
        unknown["activity"] = "pondering"
        entries.append(unknown)
        document["entries"] = entries
        defaults.set(try JSONSerialization.data(withJSONObject: document), forKey: "remote.notificationLog")

        let store = RemoteNotificationLogStore(defaults: defaults)
        XCTAssertEqual(store.log.entries.map(\.tabID), ["known"])
    }

    func testAStoredLogIsReorderedTrimmedAndDeduplicatedOnLoad() throws {
        let entries = (1...(RemoteNotificationLog.capacity + 10)).map {
            RemoteNotificationLogEntry(notification(tab: "t\($0)", at: TimeInterval($0)), isRead: true)
        }
        let unsorted = entries + [entries[0]]
        let document = ["entries": try objects(unsorted)]
        defaults.set(try JSONSerialization.data(withJSONObject: document), forKey: "remote.notificationLog")

        let store = RemoteNotificationLogStore(defaults: defaults)
        XCTAssertEqual(store.log.entries.count, RemoteNotificationLog.capacity)
        XCTAssertEqual(store.log.entries.first?.tabID, "t\(RemoteNotificationLog.capacity + 10)")
        XCTAssertEqual(Set(store.log.entries.map(\.id)).count, store.log.entries.count)
    }

    func testALogWithAnUnknownTopLevelFieldStillLoads() throws {
        var log = RemoteNotificationLog()
        log.merge(RemoteNotifications(entries: [notification(tab: "known", at: 100)]))
        var document = try XCTUnwrap(objects(log) as? [String: Any])
        document["version"] = 9
        defaults.set(try JSONSerialization.data(withJSONObject: document), forKey: "remote.notificationLog")
        XCTAssertEqual(RemoteNotificationLogStore(defaults: defaults).log.entries.count, 1)
    }

    func testACutOrEmptyLogStartsEmpty() throws {
        defaults.set(Data(), forKey: "remote.notificationLog")
        XCTAssertTrue(RemoteNotificationLogStore(defaults: defaults).log.isEmpty)
        defaults.set(Data("{\"entries\":[{\"tabID\":\"t".utf8), forKey: "remote.notificationLog")
        XCTAssertTrue(RemoteNotificationLogStore(defaults: defaults).log.isEmpty)
        defaults.set("not data", forKey: "remote.notificationLog")
        XCTAssertTrue(RemoteNotificationLogStore(defaults: defaults).log.isEmpty)
    }

    // MARK: - Saved connections

    func testOneUnreadableSavedConnectionDoesNotLoseTheOthersOrOrphanTheirTokens() throws {
        let tokens = MemoryTokens()
        let good = SavedConnection(displayName: "Studio", host: "10.0.0.5", port: 4242)
        tokens.saveToken("secret", forConnectionID: good.id)
        var rows = try XCTUnwrap(objects([good]) as? [[String: Any]])
        var broken = rows[0]
        broken["id"] = "not-a-uuid"
        broken["port"] = 70_000
        rows.append(broken)
        defaults.set(try JSONSerialization.data(withJSONObject: rows), forKey: "remote.savedConnections")

        let store = SavedConnectionStore(defaults: defaults, tokenStore: tokens)
        XCTAssertEqual(store.connections.map(\.id), [good.id],
                       "losing every Mac for one bad row also strands every token in the Keychain")
        XCTAssertEqual(store.token(for: good), "secret")
    }

    func testASavedConnectionWithFieldsFromANewerBuildIsRead() throws {
        let good = SavedConnection(displayName: "Studio", host: "10.0.0.5", port: 4242,
                                   relay: RelayEndpoint(url: URL(string: "https://relay.example")!, rendezvousID: "abc"))
        var rows = try XCTUnwrap(objects([good]) as? [[String: Any]])
        rows[0]["colour"] = "blue"
        rows[0]["lastSeenVersion"] = 42
        defaults.set(try JSONSerialization.data(withJSONObject: rows), forKey: "remote.savedConnections")
        let store = SavedConnectionStore(defaults: defaults, tokenStore: MemoryTokens())
        XCTAssertEqual(store.connections, [good])
    }

    func testASavedConnectionWithABrokenRelayIsKeptWithoutItsRelay() throws {
        // The relay is optional: an older build never wrote one. A relay written wrongly is worth
        // no more than none at all, and the Mac's address is still worth keeping.
        let good = SavedConnection(displayName: "Studio", host: "10.0.0.5", port: 4242)
        var rows = try XCTUnwrap(objects([good]) as? [[String: Any]])
        rows[0]["relay"] = ["url": "", "rendezvousID": "abc"]
        defaults.set(try JSONSerialization.data(withJSONObject: rows), forKey: "remote.savedConnections")
        let store = SavedConnectionStore(defaults: defaults, tokenStore: MemoryTokens())
        XCTAssertEqual(store.connections.map(\.id), [good.id])
        XCTAssertNil(store.connections.first?.relay)
    }

    func testAFutureLastConnectedDateStillSortsAndIsKept() throws {
        let tokens = MemoryTokens()
        let store = SavedConnectionStore(defaults: defaults, tokenStore: tokens)
        let ahead = store.upsert(host: "10.0.0.5", port: 4242, token: "a")
        let behind = store.upsert(host: "10.0.0.6", port: 4242, token: "b")
        store.recordConnected(ahead.id, at: Date(timeIntervalSinceNow: 3_600))
        store.recordConnected(behind.id, at: Date())
        XCTAssertEqual(store.connectionsByRecency.map(\.id), [ahead.id, behind.id])
        let reloaded = SavedConnectionStore(defaults: defaults, tokenStore: tokens)
        XCTAssertEqual(reloaded.connectionsByRecency.map(\.id), [ahead.id, behind.id])
    }
}
