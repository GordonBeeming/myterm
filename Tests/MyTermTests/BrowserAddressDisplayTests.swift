@testable import MyTerm
import Foundation
import XCTest

final class BrowserAddressDisplayTests: XCTestCase {
    func testHTTPSIncludesPortAndSeparatesPathQueryAndFragment() throws {
        let url = try XCTUnwrap(URL(string: "https://example.test:8443/path?query=value#section"))
        let parts = BrowserAddressDisplay.parts(for: url)
        XCTAssertEqual(parts.primary, "example.test:8443")
        XCTAssertEqual(parts.secondary, "/path?query=value#section")
    }

    func testFileSeparatesSchemeAndPath() throws {
        let url = try XCTUnwrap(URL(string: "file:///tmp/example.html"))
        let parts = BrowserAddressDisplay.parts(for: url)
        XCTAssertEqual(parts.primary, "file://")
        XCTAssertEqual(parts.secondary, "/tmp/example.html")
    }

    func testAboutBlankIsDisplayedOnce() throws {
        try assertHostlessDisplay("about:blank")
    }

    func testDataPayloadIsDisplayedOnce() throws {
        try assertHostlessDisplay("data:text/plain,hi")
    }

    func testHostlessFragmentIsDisplayedOnce() throws {
        try assertHostlessDisplay("about:blank#section")
    }

    private func assertHostlessDisplay(_ address: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let url = try XCTUnwrap(URL(string: address), file: file, line: line)
        let parts = BrowserAddressDisplay.parts(for: url)
        XCTAssertEqual(parts.primary, address, file: file, line: line)
        XCTAssertEqual(parts.secondary, "", file: file, line: line)
    }
}
