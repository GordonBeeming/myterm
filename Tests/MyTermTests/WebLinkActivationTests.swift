import Foundation
import XCTest
import MyTermCore
@testable import MyTerm

@MainActor
final class WebLinkActivationTests: XCTestCase {
    func testAWorkspaceBrowserRouteDoesNotBringTheAppForward() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com"))
        let route = try XCTUnwrap(MyTermBrowserLauncher.browserRoute(for: WorkspaceID(), url: url))

        XCTAssertFalse(MyTermApplicationDelegate.shouldActivate(for: [route]))
    }

    func testEveryOtherKindOfURLStillBringsTheAppForward() throws {
        let web = try XCTUnwrap(URL(string: "https://example.com"))
        let ssh = try XCTUnwrap(URL(string: "ssh://example.com"))
        let file = URL(fileURLWithPath: "/tmp")

        XCTAssertTrue(MyTermApplicationDelegate.shouldActivate(for: [web]))
        XCTAssertTrue(MyTermApplicationDelegate.shouldActivate(for: [ssh]))
        XCTAssertTrue(MyTermApplicationDelegate.shouldActivate(for: [file]))
    }

    func testABatchCarryingAnythingBesidesRoutesStillBringsTheAppForward() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com"))
        let route = try XCTUnwrap(MyTermBrowserLauncher.browserRoute(for: WorkspaceID(), url: url))
        let file = URL(fileURLWithPath: "/tmp")

        XCTAssertTrue(MyTermApplicationDelegate.shouldActivate(for: [route, file]))
    }

    func testSeveralRoutesTogetherStillDoNotBringTheAppForward() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com"))
        let first = try XCTUnwrap(MyTermBrowserLauncher.browserRoute(for: WorkspaceID(), url: url))
        let second = try XCTUnwrap(MyTermBrowserLauncher.browserRoute(for: WorkspaceID(), url: url))

        XCTAssertFalse(MyTermApplicationDelegate.shouldActivate(for: [first, second]))
    }

    func testAnEmptyBatchDoesNotBringTheAppForward() {
        XCTAssertFalse(MyTermApplicationDelegate.shouldActivate(for: []))
    }

    /// A route naming a workspace that no longer exists is still a route. `AppModel.open` drops it,
    /// so the only consequence of the shape-only test here is an activation that does not happen for
    /// a batch that would not have done anything anyway.
    func testAMalformedRouteIsTreatedAsAnOrdinaryURL() throws {
        let notARoute = try XCTUnwrap(URL(string: "myterm://browser/not-a-uuid?url=abc"))

        XCTAssertTrue(MyTermApplicationDelegate.shouldActivate(for: [notARoute]))
    }
}
