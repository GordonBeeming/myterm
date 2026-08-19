import Foundation
import XCTest
@testable import MyTermCore

final class AppVersionTests: XCTestCase {
    func testParsesTwoAndThreeComponentVersionsWithOrWithoutV() {
        XCTAssertEqual(AppVersion("0.23")?.description, "0.23")
        XCTAssertEqual(AppVersion("v0.23")?.description, "0.23")
        XCTAssertEqual(AppVersion("0.23.1")?.description, "0.23.1")
        XCTAssertEqual(AppVersion("V1.0.0")?.description, "1.0.0")
    }

    func testRejectsThingsThatAreNotVersions() {
        for raw in ["", "v", "1", "1.2.3.4", "1.x", "1..2", "0.23-beta", "latest", "1.2.3 "] where raw != "1.2.3 " {
            XCTAssertNil(AppVersion(raw), "expected \(raw) to be rejected")
        }
        XCTAssertEqual(AppVersion("1.2.3 ")?.description, "1.2.3", "surrounding whitespace is fine")
    }

    func testTrailingZeroesDoNotMakeAVersionNewer() {
        XCTAssertEqual(AppVersion("0.23"), AppVersion("0.23.0"))
        XCTAssertFalse(AppVersion("0.23.0")! > AppVersion("0.23")!)
        XCTAssertEqual(AppVersion("0.23")!.hashValue, AppVersion("0.23.0")!.hashValue)
    }

    func testOrdersByComponentNotLexically() {
        XCTAssertTrue(AppVersion("0.9")! < AppVersion("0.10")!)
        XCTAssertTrue(AppVersion("0.23")! < AppVersion("0.23.1")!)
        XCTAssertTrue(AppVersion("0.23.1")! < AppVersion("1.0")!)
        XCTAssertTrue(AppVersion("1.0")! > AppVersion("0.99.99")!)
    }
}

final class UpdateCheckTests: XCTestCase {
    private func releaseJSON(tag: String, name: String = "MyTerm") -> Data {
        Data(
            """
            {
              "tag_name": "\(tag)",
              "name": "\(name)",
              "html_url": "https://github.com/GordonBeeming/myterm/releases/tag/\(tag)",
              "draft": false,
              "prerelease": false
            }
            """.utf8
        )
    }

    func testNewerReleaseIsOffered() throws {
        let availability = try UpdateCheck.availability(
            currentVersion: "0.23",
            latestReleaseJSON: releaseJSON(tag: "v0.24")
        )
        let release = try XCTUnwrap(availability.release)
        XCTAssertEqual(release.version.description, "0.24")
        XCTAssertEqual(release.tag, "v0.24")
        XCTAssertEqual(release.name, "MyTerm")
        XCTAssertEqual(
            release.releaseURL.absoluteString,
            "https://github.com/GordonBeeming/myterm/releases/tag/v0.24"
        )
    }

    func testSameVersionIsUpToDate() throws {
        let availability = try UpdateCheck.availability(
            currentVersion: "0.23",
            latestReleaseJSON: releaseJSON(tag: "v0.23")
        )
        XCTAssertEqual(availability, .upToDate(current: AppVersion("0.23")!))
    }

    /// A local build can easily be ahead of the newest published release.
    func testOlderPublishedReleaseIsNotOffered() throws {
        let availability = try UpdateCheck.availability(
            currentVersion: "0.24",
            latestReleaseJSON: releaseJSON(tag: "v0.23")
        )
        XCTAssertNil(availability.release)
    }

    func testPatchReleaseIsOfferedOverATwoComponentCurrentVersion() throws {
        let availability = try UpdateCheck.availability(
            currentVersion: "0.23",
            latestReleaseJSON: releaseJSON(tag: "v0.23.1")
        )
        XCTAssertEqual(availability.release?.version.description, "0.23.1")
    }

    func testRepositoryWithNoReleasesIsReportedPlainly() {
        let body = Data(#"{ "message": "Not Found", "status": "404" }"#.utf8)
        XCTAssertThrowsError(try UpdateCheck.availability(currentVersion: "0.23", latestReleaseJSON: body)) {
            XCTAssertEqual($0 as? UpdateCheckError, .noPublishedRelease)
        }
    }

    func testRateLimitMessageIsSurfacedRatherThanSwallowed() {
        let body = Data(#"{ "message": "API rate limit exceeded for 1.2.3.4." }"#.utf8)
        XCTAssertThrowsError(try UpdateCheck.availability(currentVersion: "0.23", latestReleaseJSON: body)) {
            guard case .unreadableResponse(let reason) = $0 as? UpdateCheckError else {
                return XCTFail("expected unreadableResponse, got \($0)")
            }
            XCTAssertTrue(reason.contains("rate limit"), reason)
        }
    }

    func testUnreadableTagIsRejected() {
        XCTAssertThrowsError(
            try UpdateCheck.availability(currentVersion: "0.23", latestReleaseJSON: releaseJSON(tag: "nightly"))
        ) {
            guard case .unreadableResponse(let reason) = $0 as? UpdateCheckError else {
                return XCTFail("expected unreadableResponse, got \($0)")
            }
            XCTAssertTrue(reason.contains("nightly"), reason)
        }
    }

    func testGarbageResponseIsRejected() {
        XCTAssertThrowsError(
            try UpdateCheck.availability(currentVersion: "0.23", latestReleaseJSON: Data("not json".utf8))
        ) {
            guard case .unreadableResponse = $0 as? UpdateCheckError else {
                return XCTFail("expected unreadableResponse, got \($0)")
            }
        }
    }

    /// A development build carries the placeholder version, and must not be told to update.
    func testUnreadableCurrentVersionIsReportedAgainstTheBuild() {
        XCTAssertThrowsError(
            try UpdateCheck.availability(currentVersion: "dev", latestReleaseJSON: releaseJSON(tag: "v0.24"))
        ) {
            XCTAssertEqual($0 as? UpdateCheckError, .unreadableCurrentVersion("dev"))
        }
    }
}
