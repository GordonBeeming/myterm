import Foundation
import MyTermRemote
import XCTest
@testable import MyTerm

final class CompanionRelayChoiceTests: XCTestCase {
    func testInstalledChannelDeterminesTheDefaultAndKeepsPrivateRelayInDevelopment() {
        let development = CompanionRelayChoice.choices(channel: .development, release: .stable)
        let beta = CompanionRelayChoice.choices(channel: .production, release: .beta)
        let production = CompanionRelayChoice.choices(channel: .production, release: .stable)

        XCTAssertEqual(development.first, .development)
        XCTAssertEqual(beta.first, .beta)
        XCTAssertEqual(production.first, .production)
        XCTAssertTrue(beta.contains(.production))
        XCTAssertTrue(production.contains(.beta))
        for choices in [beta, production] {
            XCTAssertFalse(choices.contains(.development))
        }
        for choices in [development, beta, production] {
            XCTAssertTrue(choices.contains(.selfHosted))
            XCTAssertTrue(choices.contains(.setupLink))
        }
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
