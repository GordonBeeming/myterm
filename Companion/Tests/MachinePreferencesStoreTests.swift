import Foundation
import XCTest
@testable import MyTermCompanion

final class MachinePreferencesStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults = UserDefaults.standard

    override func setUpWithError() throws {
        suiteName = "MachinePreferencesStoreTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testRemembersAnAliasAndAStar() {
        let store = MachinePreferencesStore(defaults: defaults)
        let machine = connectionID()

        XCTAssertTrue(store.setAlias("blastoise · prod", for: machine))
        store.setStarred(true, for: machine)

        let reopened = MachinePreferencesStore(defaults: defaults)
        XCTAssertEqual(reopened.preference(for: machine).alias, "blastoise · prod")
        XCTAssertTrue(reopened.preference(for: machine).isStarred)
    }

    func testUnknownMachineHasNoPreferences() {
        let store = MachinePreferencesStore(defaults: defaults)

        let preference = store.preference(for: connectionID())

        XCTAssertNil(preference.alias)
        XCTAssertFalse(preference.isStarred)
        XCTAssertNil(preference.lastWorkspaceID)
    }

    func testBlankAliasClearsItRatherThanStoringEmptyText() {
        let store = MachinePreferencesStore(defaults: defaults)
        let machine = connectionID()
        store.setAlias("temporary", for: machine)

        XCTAssertTrue(store.setAlias("   \n ", for: machine))

        XCTAssertNil(store.preference(for: machine).alias,
                     "Whitespace is not a name; clearing restores the name the Mac gave")
    }

    func testAliasIsTrimmedBeforeItIsStored() {
        let store = MachinePreferencesStore(defaults: defaults)
        let machine = connectionID()

        store.setAlias("  pikachu  ", for: machine)

        XCTAssertEqual(store.preference(for: machine).alias, "pikachu")
    }

    func testTooLongAnAliasIsRejectedAndChangesNothing() {
        let store = MachinePreferencesStore(defaults: defaults)
        let machine = connectionID()
        store.setAlias("keep me", for: machine)

        let overLong = String(repeating: "a", count: MachinePreferencesStore.aliasByteLimit + 1)
        XCTAssertFalse(store.setAlias(overLong, for: machine))

        XCTAssertEqual(store.preference(for: machine).alias, "keep me",
                       "A rejected alias must not overwrite the one already stored")
    }

    func testAliasIsMeasuredInBytesNotCharacters() {
        let store = MachinePreferencesStore(defaults: defaults)
        let machine = connectionID()

        // Each of these is one character and four UTF-8 bytes.
        let emoji = String(repeating: "🖥", count: MachinePreferencesStore.aliasByteLimit / 4 + 1)
        XCTAssertFalse(store.setAlias(emoji, for: machine))
    }

    func testTheSameMacOnTwoRelaysKeepsTwoIdentities() {
        let store = MachinePreferencesStore(defaults: defaults)
        let hostID = UUID()
        let accountID = UUID()
        let prod = SavedConnectionID(relayOrigin: "https://relay.example.test",
                                     accountID: accountID, hostID: hostID)
        let dev = SavedConnectionID(relayOrigin: "https://relay-dev.example.test",
                                    accountID: accountID, hostID: hostID)

        store.setAlias("blastoise · prod", for: prod)
        store.setStarred(true, for: prod)
        store.setAlias("blastoise · dev", for: dev)

        XCTAssertEqual(store.preference(for: prod).alias, "blastoise · prod")
        XCTAssertEqual(store.preference(for: dev).alias, "blastoise · dev")
        XCTAssertTrue(store.preference(for: prod).isStarred)
        XCTAssertFalse(store.preference(for: dev).isStarred,
                       "Starring one relay's pairing must not star the other")
    }

    func testForgettingOneMachineLeavesTheOthers() {
        let store = MachinePreferencesStore(defaults: defaults)
        let kept = connectionID()
        let dropped = connectionID()
        store.setAlias("kept", for: kept)
        store.setAlias("dropped", for: dropped)

        store.forget(dropped)

        XCTAssertEqual(store.preference(for: kept).alias, "kept")
        XCTAssertNil(store.preference(for: dropped).alias)
    }

    func testClearingEveryFieldRemovesTheEntry() {
        let store = MachinePreferencesStore(defaults: defaults)
        let machine = connectionID()
        store.setAlias("gone", for: machine)
        store.setStarred(true, for: machine)

        store.setAlias(nil, for: machine)
        store.setStarred(false, for: machine)

        XCTAssertTrue(store.all().isEmpty, "An entry holding nothing should not be kept")
    }

    func testRemembersTheWorkspaceEachMacWasLeftOn() {
        let store = MachinePreferencesStore(defaults: defaults)
        let machine = connectionID()
        let workspaceID = UUID()

        store.setLastWorkspaceID(workspaceID, for: machine)

        XCTAssertEqual(MachinePreferencesStore(defaults: defaults)
            .preference(for: machine).lastWorkspaceID, workspaceID)
    }

    func testUnreadableStorageReadsAsEmptyRatherThanCrashing() {
        defaults.set(Data("not json".utf8), forKey: "companionMachinePreferences")
        let store = MachinePreferencesStore(defaults: defaults)

        XCTAssertTrue(store.all().isEmpty)

        let machine = connectionID()
        store.setAlias("recovered", for: machine)
        XCTAssertEqual(store.preference(for: machine).alias, "recovered",
                       "The next edit replaces the damaged payload")
    }

    private func connectionID() -> SavedConnectionID {
        SavedConnectionID(relayOrigin: "https://relay.example.test",
                          accountID: UUID(), hostID: UUID())
    }
}
