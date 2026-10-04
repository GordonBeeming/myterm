import XCTest
@testable import MyTermCompanion

@MainActor
final class RemoteBrowserTests: XCTestCase {
    func testNavigationRejectsSchemesThatEscapeProxy() {
        for address in ["file:///etc/passwd", "javascript:alert(1)", "data:text/html,hello", "ftp://example.com", "https://user:password@example.com"] {
            XCTAssertNil(NativeRemoteBrowser.addressURL(address))
        }
        XCTAssertEqual(NativeRemoteBrowser.addressURL("localhost:3000")?.absoluteString, "https://localhost:3000")
        XCTAssertEqual(NativeRemoteBrowser.addressURL("http://localhost:3000/path")?.host, "localhost")
    }

    func testHostFileURLUsesVirtualRemoteOrigin() {
        let url = URL(fileURLWithPath: "/Users/host/artifacts/My report.html")
        let remote = NativeRemoteBrowser.remoteURL(url, artifactHost: "test-session.myterm-artifact.invalid")
        XCTAssertEqual(remote.scheme, "http")
        XCTAssertEqual(remote.host, "test-session.myterm-artifact.invalid")
        XCTAssertEqual(remote.path, "/My report.html")
        XCTAssertFalse(remote.absoluteString.contains("/Users/host"))
    }

    func testModeSwitchPreservesNestedArtifactPathAndRejectsTraversal() throws {
        let source = URL(fileURLWithPath: "/Users/host/artifacts/report.html")
        let nested = URL(fileURLWithPath: "/Users/host/artifacts/images/details.html")
        let native = NativeRemoteBrowser.remoteURL(nested, source: source, artifactHost: "test-session.myterm-artifact.invalid")
        XCTAssertEqual(native.path, "/images/details.html")
        XCTAssertEqual(RemoteBrowserView.renderingURL(native, source: source, artifactHost: "test-session.myterm-artifact.invalid"), nested)
        XCTAssertNil(RemoteBrowserView.renderingURL(URL(string: "http://test-session.myterm-artifact.invalid/../secret"), source: source, artifactHost: "test-session.myterm-artifact.invalid"))
    }

    func testRendererViewportAdaptsToRotationAndClampsBounds() {
        XCTAssertEqual(RemoteBrowserView.renderViewport(CGSize(width: 393, height: 600)), CGSize(width: 393, height: 600))
        XCTAssertEqual(RemoteBrowserView.renderViewport(CGSize(width: 800, height: 300)), CGSize(width: 800, height: 300))
        XCTAssertEqual(RemoteBrowserView.renderViewport(CGSize(width: 2000, height: 50)), CGSize(width: 1600, height: 240))
    }

    func testNativeRoutingKeepsDomainNamesAndDetectsLegacyLoopbackAddresses() throws {
        XCTAssertFalse(NativeRemoteBrowser.requiresMacRendering(try XCTUnwrap(URL(string: "https://abc.cc"))))
        for host in ["127.1", "2130706433", "0x7f000001", "localhost."] {
            XCTAssertTrue(NativeRemoteBrowser.requiresMacRendering(try XCTUnwrap(URL(string: "http://\(host)"))))
        }
        XCTAssertEqual(RemoteBrowserView.pollDelay(failures: 0), 0.8)
        XCTAssertEqual(RemoteBrowserView.pollDelay(failures: 2), 3.2)
        XCTAssertEqual(RemoteBrowserView.pollDelay(failures: 100), 8)
    }

    func testRenderedCoordinatesUseImageAspectRatio() {
        XCTAssertEqual(RemoteBrowserView.fittedSize(image: CGSize(width: 1024, height: 768),
            bounds: CGSize(width: 400, height: 800)), CGSize(width: 400, height: 300))
        XCTAssertEqual(RemoteBrowserView.fittedSize(image: .zero, bounds: CGSize(width: 400, height: 800)), .zero)
    }
}
