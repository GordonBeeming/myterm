import Foundation
import XCTest
@testable import MyTermRemoteProtocol

/// A device whose list of Macs is gone: a reinstall, or a first launch.
final class SavedConnectionReinstallTests: XCTestCase {
    /// Removing the app takes its defaults and leaves the Keychain. What comes back has no Macs
    /// and must not keep the old ones' tokens either.
    @MainActor
    func testAStoreWithNoSavedListWipesTheTokensLeftBehind() throws {
        let suite = "SavedConnectionReinstallTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tokens = CountingTokenStore()
        tokens.saveToken("left-behind", forConnectionID: UUID())

        let store = SavedConnectionStore(defaults: defaults, tokenStore: tokens)

        XCTAssertTrue(store.connections.isEmpty)
        XCTAssertEqual(tokens.wipes, 1)
        XCTAssertTrue(tokens.tokens.isEmpty, "a token with no row to own it is a credential nobody can revoke")
    }

    @MainActor
    func testAStoreWithASavedListLeavesItsTokensAlone() throws {
        let suite = "SavedConnectionReinstallTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tokens = CountingTokenStore()
        let first = SavedConnectionStore(defaults: defaults, tokenStore: tokens)
        let saved = first.upsert(host: "10.0.0.5", port: 4242, token: "kept")

        let second = SavedConnectionStore(defaults: defaults, tokenStore: tokens)

        XCTAssertEqual(second.connections, [saved])
        XCTAssertEqual(second.token(for: saved), "kept")
        XCTAssertEqual(tokens.wipes, 1, "only the very first launch, before anything was saved, wipes")
    }

    /// Removing every Mac by hand is not a reinstall: the list is there, empty, and each removal
    /// already took its own token.
    @MainActor
    func testAnEmptiedListIsNotMistakenForAFreshInstall() throws {
        let suite = "SavedConnectionReinstallTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tokens = CountingTokenStore()
        let first = SavedConnectionStore(defaults: defaults, tokenStore: tokens)
        let saved = first.upsert(host: "10.0.0.5", port: 4242, token: "t")
        first.remove(saved.id)

        _ = SavedConnectionStore(defaults: defaults, tokenStore: tokens)

        XCTAssertEqual(tokens.wipes, 1)
    }
}

private final class CountingTokenStore: SavedConnectionTokenStoring, @unchecked Sendable {
    private(set) var tokens: [UUID: String] = [:]
    private(set) var wipes = 0

    func saveToken(_ token: String, forConnectionID id: UUID) { tokens[id] = token }
    func readToken(forConnectionID id: UUID) -> String? { tokens[id] }
    func deleteToken(forConnectionID id: UUID) { tokens.removeValue(forKey: id) }
    func deleteAllTokens() {
        wipes += 1
        tokens.removeAll()
    }
}
