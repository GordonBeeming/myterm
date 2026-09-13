import Foundation
import XCTest
@testable import MyTermRemoteProtocol

/// Two Macs with one name, and one Mac scanned twice.
final class SavedConnectionSameNameTests: XCTestCase {
    /// Two Macs on two networks can both be called "Mac Studio". Scanning the second one's code
    /// must not find the first by that name and overwrite its address and token.
    func testTwoDifferentMacsWithTheSameNameStayTwoEntries() {
        let (afterFirst, home) = SavedConnectionList.upserting(
            host: "10.0.0.5", port: 8765, displayName: nil, serviceName: "Mac Studio", into: []
        )
        XCTAssertEqual(home.displayName, "Mac Studio")

        let (afterSecond, office) = SavedConnectionList.upserting(
            host: "192.168.4.20", port: 8765, displayName: nil, serviceName: "Mac Studio", into: afterFirst
        )

        XCTAssertEqual(afterSecond.count, 2, "a Mac at a different address with the same name is another Mac")
        XCTAssertNotEqual(office.id, home.id)
        XCTAssertEqual(afterSecond.first?.host, "10.0.0.5", "the first Mac keeps its address")
    }

    /// The same Mac, its code shown again with a fresh token, updates the row it already has.
    @MainActor
    func testTheSameMacAtTheSameAddressWithANewTokenUpdatesInPlace() throws {
        let suite = "SavedConnectionSameNameTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SavedConnectionStore(defaults: defaults, tokenStore: InMemoryTokens())
        let first = store.upsert(host: "10.0.0.5", port: 8765, token: "old", serviceName: "Mac Studio")

        let second = store.upsert(host: "10.0.0.5", port: 8765, token: "new", serviceName: "Mac Studio")

        XCTAssertEqual(store.connections.count, 1)
        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(store.token(for: second), "new")
    }

    /// A Mac added by name alone has no address to disagree with, so its first code fills it in.
    func testAMacSavedByNameAloneTakesTheAddressItsCodeCarries() {
        let (byName, picked) = SavedConnectionList.upserting(
            host: "", port: 0, displayName: nil, serviceName: "Mac Studio", into: []
        )

        let (updated, scanned) = SavedConnectionList.upserting(
            host: "10.0.0.5", port: 8765, displayName: nil, serviceName: "Mac Studio", into: byName
        )

        XCTAssertEqual(updated.count, 1)
        XCTAssertEqual(scanned.id, picked.id)
        XCTAssertEqual(scanned.host, "10.0.0.5")
    }
}

private final class InMemoryTokens: SavedConnectionTokenStoring, @unchecked Sendable {
    private var tokens: [UUID: String] = [:]
    func saveToken(_ token: String, forConnectionID id: UUID) { tokens[id] = token }
    func readToken(forConnectionID id: UUID) -> String? { tokens[id] }
    func deleteToken(forConnectionID id: UUID) { tokens.removeValue(forKey: id) }
}
