import XCTest
@testable import MyTermPlatform

final class BrowserURLNormalizerTests: XCTestCase {
    func testAddsHTTPSAndNormalizesHost() throws {
        let url = try BrowserURLNormalizer.normalize("  EXAMPLE.com/docs?q=swift  ")

        XCTAssertEqual(url.absoluteString, "https://example.com/docs?q=swift")
    }

    func testPreservesHTTPSAddress() throws {
        let url = try BrowserURLNormalizer.normalize("HTTPS://Example.COM:8443/path#fragment")

        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "example.com")
        XCTAssertEqual(url.port, 8443)
        XCTAssertEqual(url.path, "/path")
        XCTAssertEqual(url.fragment, "fragment")
    }

    func testRejectsEmptyAddress() {
        XCTAssertThrowsError(try BrowserURLNormalizer.normalize(" \n ")) { error in
            XCTAssertEqual(error as? BrowserURLNormalizationError, .emptyAddress)
        }
    }

    func testAllowsExplicitFileURLs() throws {
        for address in ["file:/tmp/example.html", "file:///tmp/example.html"] {
            let url = try BrowserURLNormalizer.normalize(address)

            XCTAssertTrue(url.isFileURL)
            XCTAssertEqual(url.path, "/tmp/example.html")
        }
    }

    func testRejectsUnsupportedScheme() {
        XCTAssertThrowsError(try BrowserURLNormalizer.normalize("ssh://example.com")) { error in
            XCTAssertEqual(error as? BrowserURLNormalizationError, .invalidAddress("ssh://example.com"))
        }
    }
}
