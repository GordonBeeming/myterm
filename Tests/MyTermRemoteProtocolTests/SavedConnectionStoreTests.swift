import Foundation
import XCTest
@testable import MyTermRemoteProtocol

/// Holds tokens in memory rather than the Keychain, so these tests never touch the real login
/// keychain and never depend on Keychain access being available in the test process at all.
private final class InMemoryTokenStore: SavedConnectionTokenStoring, @unchecked Sendable {
    private(set) var tokens: [UUID: String] = [:]
    private(set) var deletedIDs: [UUID] = []

    func saveToken(_ token: String, forConnectionID id: UUID) {
        tokens[id] = token
    }

    func readToken(forConnectionID id: UUID) -> String? {
        tokens[id]
    }

    func deleteToken(forConnectionID id: UUID) {
        tokens.removeValue(forKey: id)
        deletedIDs.append(id)
    }
}

// MARK: - PairingLinkParser

final class PairingLinkParserTests: XCTestCase {
    func testParsesAWellFormedPairingLink() throws {
        let url = try XCTUnwrap(URL(string: "myterm-remote://connect?host=192.168.1.5&port=4242&token=abc123"))

        let link = PairingLinkParser.parse(url)

        XCTAssertEqual(link, PairingLink(host: "192.168.1.5", port: 4242, token: "abc123"))
    }

    func testRejectsTheWrongScheme() {
        let url = URL(string: "https://connect?host=h&port=1&token=t")!
        XCTAssertNil(PairingLinkParser.parse(url))
    }

    func testRejectsTheWrongHostComponent() {
        let url = URL(string: "myterm-remote://pair?host=h&port=1&token=t")!
        XCTAssertNil(PairingLinkParser.parse(url))
    }

    func testRejectsAMissingField() {
        let url = URL(string: "myterm-remote://connect?host=h&port=1")!
        XCTAssertNil(PairingLinkParser.parse(url))
    }

    func testRejectsANonNumericPort() {
        let url = URL(string: "myterm-remote://connect?host=h&port=notaport&token=t")!
        XCTAssertNil(PairingLinkParser.parse(url))
    }
}

// MARK: - SavedConnectionList

final class SavedConnectionListTests: XCTestCase {
    func testUpsertingANewHostAndPortAppendsAConnection() {
        let (connections, connection) = SavedConnectionList.upserting(
            host: "10.0.0.5",
            port: 4242,
            displayName: nil,
            into: []
        )

        XCTAssertEqual(connections, [connection])
        XCTAssertEqual(connection.host, "10.0.0.5")
        XCTAssertEqual(connection.port, 4242)
        XCTAssertEqual(connection.displayName, "10.0.0.5", "falls back to the host when no name is given")
    }

    func testUpsertingAnExistingHostAndPortUpdatesRatherThanDuplicates() {
        let first = SavedConnectionList.upserting(host: "10.0.0.5", port: 4242, displayName: "Gordon's Mac", into: [])

        let second = SavedConnectionList.upserting(
            host: "10.0.0.5",
            port: 4242,
            displayName: nil,
            into: first.connections
        )

        XCTAssertEqual(second.connections.count, 1, "re-adding the same Mac must not create a second entry")
        XCTAssertEqual(second.connection.id, first.connection.id, "the existing entry's identity is preserved")
        XCTAssertEqual(second.connection.displayName, "Gordon's Mac", "no new name was given, so the old one survives")
    }

    func testUpsertingAnExistingHostAndPortWithANewNameRenamesIt() {
        let first = SavedConnectionList.upserting(host: "10.0.0.5", port: 4242, displayName: "Old Name", into: [])

        let second = SavedConnectionList.upserting(
            host: "10.0.0.5",
            port: 4242,
            displayName: "New Name",
            into: first.connections
        )

        XCTAssertEqual(second.connection.displayName, "New Name")
    }

    func testUpsertingADifferentPortOnTheSameHostIsTreatedAsADifferentMac() {
        let first = SavedConnectionList.upserting(host: "10.0.0.5", port: 4242, displayName: nil, into: [])
        let second = SavedConnectionList.upserting(host: "10.0.0.5", port: 5555, displayName: nil, into: first.connections)

        XCTAssertEqual(second.connections.count, 2)
    }

    func testSortedByRecencyOrdersTheMostRecentFirst() {
        let older = SavedConnection(displayName: "Older", host: "a", port: 1, lastConnectedAt: Date(timeIntervalSince1970: 100))
        let newer = SavedConnection(displayName: "Newer", host: "b", port: 2, lastConnectedAt: Date(timeIntervalSince1970: 200))

        let sorted = SavedConnectionList.sortedByRecency([older, newer])

        XCTAssertEqual(sorted.map(\.displayName), ["Newer", "Older"])
    }

    func testSortedByRecencyPutsNeverConnectedEntriesLastInTheirOriginalOrder() {
        let connected = SavedConnection(displayName: "Connected", host: "a", port: 1, lastConnectedAt: Date())
        let neverA = SavedConnection(displayName: "Never A", host: "b", port: 2)
        let neverB = SavedConnection(displayName: "Never B", host: "c", port: 3)

        let sorted = SavedConnectionList.sortedByRecency([neverA, connected, neverB])

        XCTAssertEqual(sorted.map(\.displayName), ["Connected", "Never A", "Never B"])
    }
}

// MARK: - SavedConnectionStore

@MainActor
final class SavedConnectionStoreTests: XCTestCase {
    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "myterm-saved-connections-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return (defaults, suiteName)
    }

    func testUpsertingAPairingLinkSavesTheConnectionAndItsToken() throws {
        let (defaults, _) = try makeDefaults()
        let tokenStore = InMemoryTokenStore()
        let store = SavedConnectionStore(defaults: defaults, tokenStore: tokenStore)

        let connection = store.upsert(pairingLink: PairingLink(host: "10.0.0.5", port: 4242, token: "secret-token"))

        XCTAssertEqual(store.connections, [connection])
        XCTAssertEqual(store.token(for: connection), "secret-token")
    }

    func testReconnectingTheSameMacUpdatesTheTokenRatherThanAddingAConnection() throws {
        let (defaults, _) = try makeDefaults()
        let tokenStore = InMemoryTokenStore()
        let store = SavedConnectionStore(defaults: defaults, tokenStore: tokenStore)

        let first = store.upsert(host: "10.0.0.5", port: 4242, token: "old-token", displayName: "Gordon's Mac")
        let second = store.upsert(host: "10.0.0.5", port: 4242, token: "new-token")

        XCTAssertEqual(store.connections.count, 1)
        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(store.token(for: second), "new-token", "a rotated or re-shown token must replace the old one")
    }

    func testRemovingAConnectionDeletesItsTokenToo() throws {
        let (defaults, _) = try makeDefaults()
        let tokenStore = InMemoryTokenStore()
        let store = SavedConnectionStore(defaults: defaults, tokenStore: tokenStore)
        let connection = store.upsert(host: "10.0.0.5", port: 4242, token: "secret-token")

        store.remove(connection.id)

        XCTAssertTrue(store.connections.isEmpty)
        XCTAssertNil(store.token(for: connection))
        XCTAssertEqual(tokenStore.deletedIDs, [connection.id], "no orphaned Keychain entry may be left behind")
    }

    func testRecordConnectedUpdatesRecencyOrdering() throws {
        let (defaults, _) = try makeDefaults()
        let store = SavedConnectionStore(defaults: defaults, tokenStore: InMemoryTokenStore())
        let first = store.upsert(host: "a", port: 1, token: "t1")
        let second = store.upsert(host: "b", port: 2, token: "t2")

        store.recordConnected(second.id, at: Date(timeIntervalSince1970: 1000))
        store.recordConnected(first.id, at: Date(timeIntervalSince1970: 2000))

        XCTAssertEqual(store.connectionsByRecency.map(\.id), [first.id, second.id])
    }

    func testMoveReordersTheStoredList() throws {
        let (defaults, _) = try makeDefaults()
        let store = SavedConnectionStore(defaults: defaults, tokenStore: InMemoryTokenStore())
        let first = store.upsert(host: "a", port: 1, token: "t1")
        let second = store.upsert(host: "b", port: 2, token: "t2")

        store.move(fromOffsets: [1], toOffset: 0)

        XCTAssertEqual(store.connections.map(\.id), [second.id, first.id])
    }

    func testConnectionsSurviveBeingReloadedFromTheSameDefaults() throws {
        let (defaults, _) = try makeDefaults()
        let store = SavedConnectionStore(defaults: defaults, tokenStore: InMemoryTokenStore())
        let connection = store.upsert(host: "10.0.0.5", port: 4242, token: "secret-token", displayName: "Gordon's Mac")

        // A fresh store instance, same `UserDefaults` suite, stands in for the app relaunching.
        let reloaded = SavedConnectionStore(defaults: defaults, tokenStore: InMemoryTokenStore())

        XCTAssertEqual(reloaded.connections, [connection])
    }

    /// The whole reason the token lives in the Keychain rather than alongside the rest of the
    /// connection: `UserDefaults` is a plist on disk, readable by anything with the app's
    /// container, and this is a live credential.
    func testTheTokenNeverReachesUserDefaults() throws {
        let (defaults, key) = try makeDefaults()
        let store = SavedConnectionStore(defaults: defaults, defaultsKey: key, tokenStore: InMemoryTokenStore())
        store.upsert(host: "10.0.0.5", port: 4242, token: "super-secret-token")

        let data = try XCTUnwrap(defaults.data(forKey: key))
        let json = String(decoding: data, as: UTF8.self)

        XCTAssertFalse(json.contains("super-secret-token"))
    }
}
