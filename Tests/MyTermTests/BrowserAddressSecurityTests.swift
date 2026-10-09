@testable import MyTerm
import Foundation
import XCTest

final class BrowserAddressSecurityTests: XCTestCase {
    func testHTTPSIsSecureIncludingLoopback() throws {
        try assertClassification("https://example.test/path", .secure)
        try assertClassification("https://localhost:8443", .secure)
    }

    func testRemoteHTTPIsInsecure() throws {
        try assertClassification("http://example.test/path", .insecure)
        try assertClassification("http://localhost.example.test", .insecure)
        try assertClassification("http://127.0.0.1.example.test", .insecure)
    }

    func testHTTPLoopbackIsLocal() throws {
        for address in [
            "http://localhost:8080", "http://127.0.0.1:8080", "http://[::1]:8080",
            "http://preview.localhost", "http://PREVIEW.LOCALHOST", "http://localhost."
        ] {
            try assertClassification(address, .local)
        }
    }

    func testFileIsLocal() throws {
        try assertClassification("file:///tmp/example.html", .local)
    }

    func testBlankAndMissingURLHaveNoIndicator() throws {
        try assertClassification("about:blank", .none)
        XCTAssertEqual(BrowserAddressSecurity.classify(nil), .none)
    }

    private func assertClassification(
        _ address: String, _ expected: BrowserAddressSecurity,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let url = try XCTUnwrap(URL(string: address), file: file, line: line)
        XCTAssertEqual(BrowserAddressSecurity.classify(url), expected, address, file: file, line: line)
    }
}
