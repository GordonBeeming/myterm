import Foundation
import MyTermCore
import MyTermRemoteProtocol
import XCTest

@testable import MyTerm

/// What the Mac keeps in `UserDefaults` for reach from anywhere: the pairing token, the relay
/// address, the rendezvous a device finds it by, and the key that proves it owns that rendezvous.
@MainActor
final class RemoteHostPersistenceTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "myterm-remote-persist-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "myterm-remote-persist-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeModel(defaults: UserDefaults? = nil) throws -> AppModel {
        try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: nil,
            startsTerminalProcesses: false,
            makeAgentNotificationPoster: { RecordingNotificationPoster() },
            isApplicationActive: { false },
            remoteHostDefaultsOverride: defaults ?? self.defaults
        )
    }

    func testTheTokenRelayAndRendezvousSurviveARelaunch() throws {
        let first = try makeModel()
        first.setRelay(urlText: "https://relay.example.com", enabled: true)
        let token = first.remoteHost.token
        let rendezvous = try XCTUnwrap(first.relayEndpoint?.rendezvousID)

        let second = try makeModel()
        XCTAssertEqual(second.remoteHost.token, token)
        XCTAssertEqual(second.relayURLText, "https://relay.example.com")
        XCTAssertTrue(second.isRelayEnabled)
        XCTAssertEqual(second.relayEndpoint?.rendezvousID, rendezvous, "the code on a paired device still finds this Mac")
    }

    func testAStoredRendezvousOrHostKeyThatIsNotValidIsReplacedRatherThanUsed() throws {
        defaults.set("not a rendezvous; rm -rf /", forKey: "remote.relayIdentifier")
        defaults.set("", forKey: "remote.relayHostKey")
        let model = try makeModel()
        model.setRelay(urlText: "https://relay.example.com", enabled: true)
        let rendezvous = try XCTUnwrap(model.relayEndpoint?.rendezvousID)
        XCTAssertTrue(RelayRendezvous.isValidIdentifier(rendezvous))
        XCTAssertEqual(defaults.string(forKey: "remote.relayIdentifier"), rendezvous, "the replacement is written back")
    }

    func testAnEmptyStoredTokenIsReplacedRatherThanUsed() throws {
        defaults.set("", forKey: "remote.token")
        let model = try makeModel()
        XCTAssertFalse(model.remoteHost.token.isEmpty)
        XCTAssertEqual(defaults.string(forKey: "remote.token"), model.remoteHost.token)
    }

    func testRegeneratingTheTokenForgetsTheRendezvousAndTheHostKeyOnDisk() throws {
        let model = try makeModel()
        model.setRelay(urlText: "https://relay.example.com", enabled: true)
        _ = model.relayEndpoint
        XCTAssertNotNil(defaults.string(forKey: "remote.relayIdentifier"))
        let token = defaults.string(forKey: "remote.token")

        let rendezvous = defaults.string(forKey: "remote.relayIdentifier")

        model.regenerateRemoteHostToken()
        XCTAssertNotEqual(defaults.string(forKey: "remote.token"), token)
        let relaunched = try makeModel()
        XCTAssertEqual(relaunched.remoteHost.token, model.remoteHost.token)
        XCTAssertNotEqual(relaunched.relayEndpoint?.rendezvousID, rendezvous, "an old code must not find this Mac after a relaunch either")
        XCTAssertNil(defaults.string(forKey: "remote.relayHostKey"), "the host key is minted again only when the link comes up")
    }

    func testTheDefaultsSuiteFromTheEnvironmentIsHonoured() throws {
        let envSuite = "myterm-env-suite-\(UUID().uuidString)"
        let envDefaults = try XCTUnwrap(UserDefaults(suiteName: envSuite))
        addTeardownBlock { envDefaults.removePersistentDomain(forName: envSuite) }
        setenv("MYTERM_USER_DEFAULTS_SUITE", envSuite, 1)
        defer { unsetenv("MYTERM_USER_DEFAULTS_SUITE") }

        // Nothing injected: the environment decides where the token goes.
        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: nil,
            startsTerminalProcesses: false,
            makeAgentNotificationPoster: { RecordingNotificationPoster() },
            isApplicationActive: { false }
        )
        XCTAssertEqual(envDefaults.string(forKey: "remote.token"), model.remoteHost.token)
        XCTAssertNil(UserDefaults(suiteName: MyTermChannel.development.bundleIdentifier)?.string(forKey: "remote.token")
                        .flatMap { $0 == model.remoteHost.token ? $0 : nil },
                     "the dev channel's own defaults are untouched")
    }
}
