import Foundation
import MyTermRemote
import XCTest
@testable import MyTerm

final class CompanionRelayChoiceTests: XCTestCase {
    func testInstalledChannelDeterminesTheDefaultAndKeepsPrivateRelayInDevelopment() {
        let development = CompanionRelayChoice.choices(channel: .development, release: .stable)
        let beta = CompanionRelayChoice.choices(channel: .production, release: .beta)
        let production = CompanionRelayChoice.choices(channel: .production, release: .stable)

        XCTAssertEqual(development, [.development, .beta, .production, .selfHosted, .setupLink])
        XCTAssertEqual(beta, [.beta, .production, .selfHosted, .setupLink])
        XCTAssertEqual(production, [.production, .selfHosted, .setupLink])
    }

    func testTypedHostedEndpointsFollowTheSameChannelPolicy() throws {
        let beta = try RelayEndpoint(XCTUnwrap(URL(string: "https://MYTERM-RELAY-BETA.gordonbeeming.dev:443/")))
        let development = try RelayEndpoint(XCTUnwrap(URL(string: MyTermHostedRelay.development.origin)))
        let custom = try RelayEndpoint(XCTUnwrap(URL(string: "https://relay.example.com:8443")))
        XCTAssertNotNil(CompanionRelayChoice.unavailableMessage(for: beta, channel: .production, release: .stable))
        XCTAssertNil(CompanionRelayChoice.unavailableMessage(for: beta, channel: .production, release: .beta))
        XCTAssertNil(CompanionRelayChoice.unavailableMessage(for: beta, channel: .development, release: .stable))
        XCTAssertNotNil(CompanionRelayChoice.unavailableMessage(for: development, channel: .production, release: .beta))
        XCTAssertNil(CompanionRelayChoice.unavailableMessage(for: custom, channel: .production, release: .stable))
    }

    func testSavedOriginTakesPrecedenceOverTheInstalledChannel() {
        let choices = CompanionRelayChoice.choices(channel: .production, release: .beta)
        XCTAssertEqual(CompanionRelayChoice.initial(savedAddress: "", choices: choices), .beta)
        XCTAssertEqual(
            CompanionRelayChoice.initial(savedAddress: " https://MYTERM-RELAY.gordonbeeming.dev:443/ ", choices: choices),
            .production
        )
        XCTAssertEqual(
            CompanionRelayChoice.initial(savedAddress: "https://relay.example.com:8443", choices: choices),
            .selfHosted
        )
    }

    func testHostedOriginsAreValidAndDistinct() throws {
        let origins = CompanionRelayChoice.allCases.compactMap(\.origin)
        XCTAssertEqual(Set(origins).count, 3)
        for origin in origins {
            XCTAssertEqual(try RelayEndpoint(XCTUnwrap(URL(string: origin))).canonicalOrigin, origin)
        }
    }

    func testRustWorkspaceRehearsalUsesItsOwnPreferencesDomain() {
        let profile = URL(fileURLWithPath: "/tmp/myterm-upgrade-copy")
        let domain = MyTermChannel.rustWorkspacePreferencesDomain(applicationSupportOverride: profile)
        XCTAssertEqual(domain, MyTermChannel.rustWorkspacePreferencesDomain(applicationSupportOverride: profile))
        XCTAssertNotEqual(domain, MyTermChannel.rustWorkspacePreferencesDomain(applicationSupportOverride: nil))
        XCTAssertNotEqual(domain, MyTermChannel.production.bundleIdentifier)
    }
}
