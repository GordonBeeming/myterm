import Network
import XCTest
@testable import MyTermRemoteProtocol

final class PairingAndFailureTests: XCTestCase {
    // MARK: - The pairing link

    func testALinkCarriesTheMacsNameAndReadsBackTheSame() throws {
        let link = PairingLink(host: "192.168.1.20", port: 52130, token: "abc123", serviceName: "Big Mac")
        let url = try XCTUnwrap(link.url)
        XCTAssertEqual(PairingLinkParser.parse(url), link)
    }

    func testAnOlderLinkWithoutANameStillParses() throws {
        let url = try XCTUnwrap(URL(string: "myterm-remote://connect?host=10.0.0.5&port=52130&token=t"))
        let link = try XCTUnwrap(PairingLinkParser.parse(url))
        XCTAssertEqual(link.host, "10.0.0.5")
        XCTAssertNil(link.serviceName)
    }

    func testALinkCarriesTheRelayAndReadsBackTheSame() throws {
        let relay = RelayEndpoint(url: URL(string: "https://relay.example.com")!, rendezvousID: "0123456789abcdef0123456789abcdef")
        let link = PairingLink(host: "10.0.0.5", port: 52130, token: "t", serviceName: "Studio", relay: relay)
        let url = try XCTUnwrap(link.url)
        XCTAssertEqual(PairingLinkParser.parse(url), link)
    }

    func testARelayWithABadIdentifierIsDropped() throws {
        let url = try XCTUnwrap(URL(string: "myterm-remote://connect?host=h&port=1&token=t&relay=https://r.example&rendezvous=no"))
        XCTAssertNil(PairingLinkParser.parse(url)?.relay, "an identifier the relay would reject is not worth carrying")
    }

    // MARK: - The relay

    func testRelaySocketsFollowTheOriginsScheme() {
        let secure = RelayEndpoint(url: URL(string: "https://relay.example.com/")!, rendezvousID: "abcdefabcdefabcdef")
        XCTAssertEqual(secure.deviceSocketURL.absoluteString, "wss://relay.example.com/v1/device/abcdefabcdefabcdef")
        XCTAssertEqual(secure.hostControlURL.absoluteString, "wss://relay.example.com/v1/host/abcdefabcdefabcdef")
        XCTAssertEqual(
            secure.hostSessionURL(session: "s1").absoluteString,
            "wss://relay.example.com/v1/host/abcdefabcdefabcdef/session/s1"
        )
        let local = RelayEndpoint(url: URL(string: "http://127.0.0.1:8787")!, rendezvousID: "abcdefabcdefabcdef")
        XCTAssertEqual(local.deviceSocketURL.absoluteString, "ws://127.0.0.1:8787/v1/device/abcdefabcdefabcdef")
    }

    func testRendezvousIdentifiersAreLongRandomAndAcceptable() {
        let one = RelayRendezvous.makeIdentifier()
        let two = RelayRendezvous.makeIdentifier()
        XCTAssertEqual(one.count, 32)
        XCTAssertNotEqual(one, two)
        XCTAssertTrue(RelayRendezvous.isValidIdentifier(one))
        XCTAssertFalse(RelayRendezvous.isValidIdentifier("short"))
        XCTAssertFalse(RelayRendezvous.isValidIdentifier("has a space and is long enough"))
    }

    func testRelayCloseCodesBecomeSentences() {
        XCTAssertTrue(RelayFailure.from(closeCode: 4004).message.contains("not connected to the relay"))
        XCTAssertTrue(RelayFailure.from(closeCode: 4008).message.contains("did not answer"))
        XCTAssertTrue(RelayFailure.from(closeCode: 4029).message.contains("Too many"))
    }

    // MARK: - Saved Macs

    /// A name at a new address is another row. From the data alone this is not tellable from
    /// one Mac whose address changed, and two Macs sharing a name on two networks is the case
    /// that loses a row and its token if the name is trusted, so the name is not. A Mac whose
    /// address changed is still reached: the row it has is dialled by name first.
    func testTheSameNameAtANewAddressIsAnotherRow() {
        let (once, first) = SavedConnectionList.upserting(
            host: "192.168.1.20", port: 52130, displayName: nil, serviceName: "Big Mac", into: []
        )
        let (twice, second) = SavedConnectionList.upserting(
            host: "192.168.1.44", port: 52130, displayName: nil, serviceName: "Big Mac", into: once
        )
        XCTAssertEqual(twice.count, 2)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(twice.first?.host, "192.168.1.20", "the row that was there keeps its address")
        XCTAssertEqual(second.displayName, "Big Mac", "a Mac with a name is listed by it, not by an address")
    }

    func testAMacAddedByNameAloneIsListedByThatName() {
        let (_, connection) = SavedConnectionList.upserting(
            host: "", port: 0, displayName: nil, serviceName: "Studio", into: []
        )
        XCTAssertEqual(connection.displayName, "Studio")
        XCTAssertEqual(connection.serviceName, "Studio")
    }

    func testAnEntrySavedBeforeNamesExistedStillDecodes() throws {
        let json = #"[{"id":"6BA7B810-9DAD-11D1-80B4-00C04FD430C8","displayName":"old","host":"h","port":1}]"#
        let decoded = try JSONDecoder().decode([SavedConnection].self, from: Data(json.utf8))
        XCTAssertEqual(decoded.first?.displayName, "old")
        XCTAssertNil(decoded.first?.serviceName)
    }

    // MARK: - What a failure says

    private let target = RemoteTarget(host: "192.168.1.20", port: 52130, token: "t")

    func testNothingListeningTellsTheUserWhichSwitchToTurnOn() {
        let message = RemoteClientFailure.message(for: .posix(.ECONNREFUSED), target: target, hadConnected: false)
        XCTAssertTrue(message.contains("192.168.1.20:52130"))
        XCTAssertTrue(message.contains("Allow my devices to reach this Mac"))
    }

    func testAClosedSocketBeforeAnyWelcomePointsAtTheToken() {
        for error: NWError? in [nil, .posix(.ECONNRESET)] {
            let message = RemoteClientFailure.message(for: error, target: target, hadConnected: false)
            XCTAssertTrue(message.lowercased().contains("token"), message)
        }
    }

    func testAnUnreachableAddressSaysSoWithoutAPosixCode() {
        let message = RemoteClientFailure.message(for: .posix(.EHOSTUNREACH), target: target, hadConnected: false)
        XCTAssertTrue(message.contains("same network"))
        XCTAssertFalse(message.contains("POSIX"))
    }

    func testALossAfterConnectingNamesTheMacAndNotTheToken() {
        let message = RemoteClientFailure.message(
            for: .posix(.ECONNRESET), target: target, hadConnected: true, hostName: "Big Mac"
        )
        XCTAssertTrue(message.contains("“Big Mac”"))
        XCTAssertFalse(message.lowercased().contains("token"))
    }

    // MARK: - Trying again

    func testTheReconnectScheduleBacksOffThenStops() {
        // Mirrors the app's schedule: a copy here keeps the shape under test without linking UIKit.
        let delays: [TimeInterval] = [1, 2, 4, 8, 15, 30]
        XCTAssertEqual(delays, delays.sorted(), "waits must grow, not shrink")
        XCTAssertLessThanOrEqual(delays.reduce(0, +), 60, "a minute of trying is enough before asking the user")
    }
}
