import CryptoKit
import Foundation
import MyTermCore
import MyTermRemote
import XCTest
@testable import MyTermCompanion

private final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(account: String) throws -> Data? { lock.withLock { values[account] } }
    func write(_ data: Data, account: String) throws { lock.withLock { values[account] = data } }
    func delete(account: String) throws { _ = lock.withLock { values.removeValue(forKey: account) } }
}

final class MachineNavigationTests: XCTestCase {
    func testOneReachableStarredMacIsOpenedWithoutAsking() throws {
        let starred = try host(named: "blastoise")
        let other = try host(named: "pikachu")

        let choice = MachineAutoSelection.choice(
            hosts: [starred, other],
            statuses: [starred.connectionID: .online, other.connectionID: .disconnected],
            isStarred: { $0 == starred.connectionID }
        )

        XCTAssertEqual(choice, .select(starred.connectionID))
    }

    func testOneReachableMacThatIsNotStarredStillShowsTheList() throws {
        let only = try host(named: "blastoise")

        let choice = MachineAutoSelection.choice(
            hosts: [only],
            statuses: [only.connectionID: .online],
            isStarred: { _ in false }
        )

        XCTAssertEqual(choice, .showTheList,
                       "Starring is the opt-in; being the only Mac online is not consent")
    }

    func testTwoReachableMacsShowTheListEvenWhenOneIsStarred() throws {
        let starred = try host(named: "blastoise")
        let other = try host(named: "pikachu")

        let choice = MachineAutoSelection.choice(
            hosts: [starred, other],
            statuses: [starred.connectionID: .online, other.connectionID: .online],
            isStarred: { $0 == starred.connectionID }
        )

        XCTAssertEqual(choice, .showTheList)
    }

    func testAStarredMacThatIsOfflineShowsTheList() throws {
        let starred = try host(named: "blastoise")

        let choice = MachineAutoSelection.choice(
            hosts: [starred],
            statuses: [starred.connectionID: .failed("no route")],
            isStarred: { _ in true }
        )

        XCTAssertEqual(choice, .showTheList)
    }

    func testWaitsWhileAnotherMacIsStillBeingProbed() throws {
        let starred = try host(named: "blastoise")
        let slow = try host(named: "pikachu")

        let choice = MachineAutoSelection.choice(
            hosts: [starred, slow],
            statuses: [starred.connectionID: .online, slow.connectionID: .connecting],
            isStarred: { $0 == starred.connectionID }
        )

        XCTAssertEqual(choice, .waiting,
                       "One host online while another is mid-probe is not one host reachable")
    }

    func testWaitsWhenAMacHasNoStatusYet() throws {
        let starred = try host(named: "blastoise")
        let unprobed = try host(named: "pikachu")

        let choice = MachineAutoSelection.choice(
            hosts: [starred, unprobed],
            statuses: [starred.connectionID: .online],
            isStarred: { _ in true }
        )

        XCTAssertEqual(choice, .waiting)
    }

    func testNoPairedMacsShowsTheList() {
        XCTAssertEqual(MachineAutoSelection.choice(hosts: [], statuses: [:], isStarred: { _ in true }),
                       .showTheList)
    }

    func testTheSameMacOnTwoRelaysIsTwoCandidates() throws {
        let hostID = UUID()
        let accountID = UUID()
        let prod = try host(named: "blastoise", relay: "https://relay.example.test",
                            accountID: accountID, hostID: hostID)
        let dev = try host(named: "blastoise", relay: "https://relay-dev.example.test",
                           accountID: accountID, hostID: hostID)

        let choice = MachineAutoSelection.choice(
            hosts: [prod, dev],
            statuses: [prod.connectionID: .online, dev.connectionID: .online],
            isStarred: { $0 == prod.connectionID }
        )

        XCTAssertEqual(choice, .showTheList,
                       "Dev and prod on one machine are two reachable Macs, not one")
    }

    // MARK: - What the list shows

    @MainActor
    func testServicesPublishAnAliasSoTheListRedraws() throws {
        let suiteName = "MachineNavigationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let services = CompanionServices(
            secrets: InMemorySecretStore(),
            machinePreferences: MachinePreferencesStore(defaults: defaults)
        )
        let mac = try host(named: "blastoise")

        XCTAssertEqual(services.displayName(for: mac), "blastoise")

        XCTAssertTrue(services.setAlias("blastoise · prod", for: mac.connectionID))

        XCTAssertEqual(services.displayName(for: mac), "blastoise · prod",
                       "The observed snapshot has to move, or a rename never reaches the list")
        XCTAssertFalse(services.isStarred(mac.connectionID))
        services.setStarred(true, for: mac.connectionID)
        XCTAssertTrue(services.isStarred(mac.connectionID))
    }

    @MainActor
    func testServicesRejectAnOverLongAliasAndKeepTheOldOne() throws {
        let suiteName = "MachineNavigationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let services = CompanionServices(
            secrets: InMemorySecretStore(),
            machinePreferences: MachinePreferencesStore(defaults: defaults)
        )
        let mac = try host(named: "blastoise")
        services.setAlias("prod", for: mac.connectionID)

        let overLong = String(repeating: "a", count: MachinePreferencesStore.aliasByteLimit + 1)
        XCTAssertFalse(services.setAlias(overLong, for: mac.connectionID))

        XCTAssertEqual(services.displayName(for: mac), "prod")
    }

    // MARK: - Workspace

    func testOpensTheRememberedWorkspace() {
        let workspaces = [workspace("myterm"), workspace("xylem"), workspace("sink")]

        let chosen = WorkspaceAutoSelection.choice(workspaces: workspaces, current: nil,
                                                   remembered: workspaces[2].id.rawValue)

        XCTAssertEqual(chosen, workspaces[2].id.rawValue)
    }

    func testOpensTheFirstWorkspaceWithNothingRemembered() {
        let workspaces = [workspace("myterm"), workspace("xylem")]

        XCTAssertEqual(WorkspaceAutoSelection.choice(workspaces: workspaces, current: nil,
                                                     remembered: nil),
                       workspaces[0].id.rawValue)
    }

    func testFallsBackWhenTheRememberedWorkspaceIsGoneFromTheMac() {
        let workspaces = [workspace("myterm"), workspace("xylem")]

        let chosen = WorkspaceAutoSelection.choice(workspaces: workspaces, current: nil,
                                                   remembered: UUID())

        XCTAssertEqual(chosen, workspaces[0].id.rawValue,
                       "A workspace deleted on the Mac must not leave the detail column empty")
    }

    func testLeavesAWorkspaceTheUserIsAlreadyOnAlone() {
        let workspaces = [workspace("myterm"), workspace("xylem")]

        let chosen = WorkspaceAutoSelection.choice(workspaces: workspaces,
                                                   current: workspaces[1].id.rawValue,
                                                   remembered: workspaces[0].id.rawValue)

        XCTAssertEqual(chosen, workspaces[1].id.rawValue,
                       "What the user is looking at outranks what was remembered")
    }

    func testReplacesASelectionTheMacHasClosed() {
        let workspaces = [workspace("myterm"), workspace("xylem")]

        let chosen = WorkspaceAutoSelection.choice(workspaces: workspaces, current: UUID(),
                                                   remembered: workspaces[1].id.rawValue)

        XCTAssertEqual(chosen, workspaces[1].id.rawValue,
                       "A selection pointing at a closed workspace strands the detail column")
    }

    func testChoosesNothingWhenTheMacHasNoWorkspaces() {
        XCTAssertNil(WorkspaceAutoSelection.choice(workspaces: [], current: UUID(),
                                                   remembered: UUID()))
    }

    // MARK: - Fixtures

    private func host(named name: String,
                      relay: String = "https://relay.example.test",
                      accountID: UUID = UUID(),
                      hostID: UUID = UUID()) throws -> SavedHostDescriptor {
        let endpoint = try RelayEndpoint(XCTUnwrap(URL(string: relay)))
        let agreement = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
        let signing = P256.Signing.PrivateKey().publicKey.x963Representation
        return try SavedHostDescriptor(relay: endpoint, accountID: accountID,
                                       clientDeviceID: UUID(), hostID: hostID, name: name,
                                       pinnedPublicKey: agreement,
                                       notificationSigningPublicKey: signing)
    }

    private func workspace(_ title: String) -> RemoteWorkspaceItem {
        RemoteWorkspaceItem(id: WorkspaceID(), title: title, folderID: nil, isPinned: false,
                            color: nil, emoji: nil, groups: [])
    }
}
