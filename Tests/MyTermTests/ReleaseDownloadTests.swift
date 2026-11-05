import Foundation
import XCTest
@testable import MyTermUpdating

@MainActor
final class ReleaseDownloadTests: XCTestCase {
    private func destination() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("archive")
    }

    private func downloader(_ host: String, destination: URL, maximum: Int) throws -> ReleaseDownload {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DownloadFixtureProtocol.self]
        return ReleaseDownload(url: try XCTUnwrap(URL(string: "https://\(host).download.invalid/archive")),
                               destination: destination, maximumBytes: maximum, configuration: config)
    }

    /// Delegate chunks must preserve bytes while avoiding per-byte asynchronous dispatch.
    func testChunkedDownloadWritesTheExpectedBytes() async throws {
        let file = try destination()
        try await downloader("small", destination: file, maximum: 100).download()
        XCTAssertEqual(try Data(contentsOf: file), Data("hello-world".utf8))
    }

    /// A chunked response without Content-Length must still be bounded before disk use grows.
    func testUnknownLengthResponseCannotExceedTheByteLimit() async throws {
        let file = try destination()
        do {
            try await downloader("large", destination: file, maximum: 16).download()
            XCTFail("Expected a bounded-download rejection")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("size limit"))
        }
        XCTAssertLessThanOrEqual(try Data(contentsOf: file).count, 16)
    }

    /// An already cancelled task must complete once even if cancellation precedes URLSession setup.
    func testCancellationBeforeStartupCompletesWithoutHanging() async throws {
        let file = try destination()
        let download = try downloader("small", destination: file, maximum: 100)
        let task = Task { try await download.download() }
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { XCTAssertTrue(task.isCancelled) }
        catch { XCTFail("Expected cancellation, received \(error)") }
    }
}

private final class DownloadFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".download.invalid") == true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if url.host?.hasPrefix("large") == true {
            client?.urlProtocol(self, didLoad: Data(repeating: 65, count: 65_536))
        } else {
            client?.urlProtocol(self, didLoad: Data("hello-".utf8))
            client?.urlProtocol(self, didLoad: Data("world".utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    // Responses are synchronous fixtures; no background producer remains to stop.
    override func stopLoading() { }
}
