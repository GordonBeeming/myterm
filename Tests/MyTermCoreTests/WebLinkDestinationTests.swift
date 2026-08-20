import XCTest
@testable import MyTermCore

final class WebLinkDestinationTests: XCTestCase {
    func testDestinationSurvivesACodingRoundTrip() throws {
        let destinations: [WebLinkDestination] = [
            .myterm,
            .systemDefaultBrowser,
            .application(bundleIdentifier: "com.apple.Safari"),
        ]
        for destination in destinations {
            let data = try JSONEncoder().encode(destination)
            XCTAssertEqual(try JSONDecoder().decode(WebLinkDestination.self, from: data), destination)
        }
    }

    func testUnreadableDestinationsFallBackToMyTerm() throws {
        let cases = [
            #"{"type":"unknownFuture"}"#,
            #"{"type":"application"}"#,
            #"{"type":"application","bundleIdentifier":"   "}"#,
            #"{}"#,
        ]
        for json in cases {
            let destination = try JSONDecoder().decode(
                WebLinkDestination.self,
                from: Data(json.utf8)
            )
            XCTAssertEqual(destination, .myterm, "Expected \(json) to decode as myterm")
        }
    }

    func testPreferencesDefaultToMyTermAndKeepTheChosenBrowser() throws {
        XCTAssertEqual(TerminalPreferences.default.webLinkDestination, .myterm)
        XCTAssertTrue(TerminalPreferences.default.webLinkDestination.opensInMyTerm)

        var preferences = TerminalPreferences.default
        preferences.webLinkDestination = .application(bundleIdentifier: "com.apple.Safari")
        let data = try JSONEncoder().encode(preferences)
        let decoded = try JSONDecoder().decode(TerminalPreferences.self, from: data)
        XCTAssertEqual(decoded.webLinkDestination, .application(bundleIdentifier: "com.apple.Safari"))
        XCTAssertFalse(decoded.webLinkDestination.opensInMyTerm)
        XCTAssertEqual(decoded.normalized().webLinkDestination, decoded.webLinkDestination)
    }

    func testSettingsWrittenBeforeThisFeatureStillOpenInMyTerm() throws {
        let legacy = #"{"browserDataScope":"workspace","fontSize":12}"#
        let preferences = try JSONDecoder().decode(
            TerminalPreferences.self,
            from: Data(legacy.utf8)
        )
        XCTAssertEqual(preferences.webLinkDestination, .myterm)
    }

    func testAWorkspaceOverridesTheApplicationWideBrowser() throws {
        var base = TerminalPreferences.default
        base.webLinkDestination = .systemDefaultBrowser

        var overrides = TerminalPreferencesOverrides()
        XCTAssertEqual(overrides.applying(to: base).webLinkDestination, .systemDefaultBrowser)

        overrides.webLinkDestination = .myterm
        XCTAssertEqual(overrides.applying(to: base).webLinkDestination, .myterm)

        let data = try JSONEncoder().encode(overrides)
        let decoded = try JSONDecoder().decode(TerminalPreferencesOverrides.self, from: data)
        XCTAssertEqual(decoded.webLinkDestination, .myterm)
    }
}
