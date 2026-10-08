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

    func testIdentifierIsAVersionFiveUUIDLikeTheMacsOwn() {
        let identifier = BrowserProfileStores.identifier(
            hostID: hostA, profileStoreID: profile, workspaceID: workspace)
        let bytes = withUnsafeBytes(of: identifier.uuid) { Array($0) }

        XCTAssertEqual(bytes[6] & 0xF0, 0x50, "Version nibble")
        XCTAssertEqual(bytes[8] & 0xC0, 0x80, "Variant bits")
    }
}
