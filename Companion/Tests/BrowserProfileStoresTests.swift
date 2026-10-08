import XCTest

@testable import MyTermCompanion

final class BrowserProfileStoresTests: XCTestCase {
    private let hostA = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let hostB = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let profile = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private let workspace = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!

    func testIdentifierIsStableSoAJarIsReopenedRatherThanRecreated() {
        let first = BrowserProfileStores.identifier(
            hostID: hostA, profileStoreID: profile, workspaceID: workspace)
        let second = BrowserProfileStores.identifier(
            hostID: hostA, profileStoreID: profile, workspaceID: workspace)

        XCTAssertEqual(first, second, "An unstable identifier is the dropped-cookie bug all over again")
    }

    func testIdentifierIgnoresTheWorkspaceWhenTheMacNamedAProfile() {
        // Two workspaces sharing one Mac profile — a folder-wide or app-wide "Browser data" scope —
        // have to land on the same jar, or the companion draws a narrower boundary than the Mac.
        let other = UUID()
        XCTAssertEqual(
            BrowserProfileStores.identifier(
                hostID: hostA, profileStoreID: profile, workspaceID: workspace),
            BrowserProfileStores.identifier(
                hostID: hostA, profileStoreID: profile, workspaceID: other)
        )
    }

    func testTwoMacsStayIsolatedEvenOnTheSameProfileIdentifier() {
        // A workspace import can leave two Macs sharing a profile UUID; their cookies must not merge.
        XCTAssertNotEqual(
            BrowserProfileStores.identifier(
                hostID: hostA, profileStoreID: profile, workspaceID: workspace),
            BrowserProfileStores.identifier(
                hostID: hostB, profileStoreID: profile, workspaceID: workspace)
        )
    }

    func testFallbackIsPerWorkspaceAndDistinctFromAProfileIdentifier() {
        let fallback = BrowserProfileStores.identifier(
            hostID: hostA, profileStoreID: nil, workspaceID: workspace)
        let otherWorkspace = BrowserProfileStores.identifier(
            hostID: hostA, profileStoreID: nil, workspaceID: UUID())

        XCTAssertNotEqual(fallback, otherWorkspace, "An older Mac still gets per-workspace isolation")
        XCTAssertNotEqual(
            fallback,
            BrowserProfileStores.identifier(
                hostID: hostA, profileStoreID: profile, workspaceID: workspace),
            "The fallback must not collide with a real profile's jar"
        )
    }

    @MainActor
    func testTheCacheIsProcessWideSoTwoScenesCannotBothHoldAProfile() {
        // Two iPad windows get two SceneModels. A per-scene cache let both acquire the same store and
        // retarget its proxy without either knowing.
        XCTAssertIdentical(BrowserProfileStores.shared, BrowserProfileStores.shared)
    }

    @MainActor
    func testTakingTheStoreStandsThePreviousHolderDownAndIsAwaited() async {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let stores = BrowserProfileStores(defaults: defaults)
        let identifier = Self.testIdentifier()
        let first = UUID()
        let second = UUID()
        var flushed = false

        _ = await stores.acquire(identifier: identifier, owner: first, hostID: hostA) {
            // Marked inside the callback so the assertion proves acquire awaited it rather than
            // firing it off and returning.
            flushed = true
        }
        _ = await stores.acquire(identifier: identifier, owner: second, hostID: hostA) {}

        XCTAssertTrue(flushed, "The displaced holder has to flush before the new one pulls over it")

        // The displaced holder's own teardown must not disturb the new holder's proxy.
        stores.release(identifier: identifier, owner: first)
        XCTAssertNotNil(stores.store(identifier: identifier))

        stores.release(identifier: identifier, owner: second)
    }

    @MainActor
    func testReacquiringWithTheSameOwnerDoesNotStandItselfDown() async {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let stores = BrowserProfileStores(defaults: defaults)
        let identifier = Self.testIdentifier()
        let owner = UUID()
        var standDowns = 0

        _ = await stores.acquire(identifier: identifier, owner: owner, hostID: hostA) { standDowns += 1 }
        _ = await stores.acquire(identifier: identifier, owner: owner, hostID: hostA) { standDowns += 1 }

        XCTAssertEqual(standDowns, 0, "A retry by the same view is not a hand-over")
        stores.release(identifier: identifier, owner: owner)
    }

    @MainActor
    func testBaselineSurvivesPerProfileAndClearsWhenEmptied() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let stores = BrowserProfileStores(defaults: defaults)
        let first = Self.testIdentifier()
        let second = Self.testIdentifier()

        XCTAssertTrue(stores.baseline(identifier: first).isEmpty)

        stores.setBaseline(["a\u{1F}/\u{1F}one"], identifier: first)
        stores.setBaseline(["b\u{1F}/\u{1F}two"], identifier: second)

        XCTAssertEqual(stores.baseline(identifier: first), ["a\u{1F}/\u{1F}one"])
        XCTAssertEqual(stores.baseline(identifier: second), ["b\u{1F}/\u{1F}two"])
        // A fresh instance reads the same rows, which is what makes a deletion survive a relaunch.
        XCTAssertEqual(
            BrowserProfileStores(defaults: defaults).baseline(identifier: first),
            ["a\u{1F}/\u{1F}one"])

        stores.setBaseline([], identifier: first)
        XCTAssertTrue(stores.baseline(identifier: first).isEmpty)
        XCTAssertEqual(stores.baseline(identifier: second), ["b\u{1F}/\u{1F}two"])
    }

    private static func testIdentifier() -> UUID {
        BrowserProfileStores.identifier(
            hostID: UUID(), profileStoreID: UUID(), workspaceID: UUID())
    }

    private func makeDefaults() -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "MyTermCompanionTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Could not create an isolated defaults suite")
        }
        return (defaults, suiteName)
    }

    func testIdentifierIsAVersionFiveUUIDLikeTheMacsOwn() {
        let identifier = BrowserProfileStores.identifier(
            hostID: hostA, profileStoreID: profile, workspaceID: workspace)
        let bytes = withUnsafeBytes(of: identifier.uuid) { Array($0) }

        XCTAssertEqual(bytes[6] & 0xF0, 0x50, "Version nibble")
        XCTAssertEqual(bytes[8] & 0xC0, 0x80, "Variant bits")
    }
}
