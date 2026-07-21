import XCTest
@testable import MyTermPlatform

final class TerminalSessionConfigurationTests: XCTestCase {
    func testConfigurationCarriesOneShotInitialCommand() {
        let configuration = TerminalSessionConfiguration(
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            initialCommand: "echo ready",
            environment: ["BROWSER": "/Applications/myterm.app/Contents/Resources/myterm-browser"]
        )

        XCTAssertEqual(configuration.initialCommand, "echo ready")
        XCTAssertEqual(
            configuration.environment["BROWSER"],
            "/Applications/myterm.app/Contents/Resources/myterm-browser"
        )
    }

    func testStandardizesWorkingDirectory() {
        let configuration = TerminalSessionConfiguration(
            shell: URL(fileURLWithPath: "/bin/zsh"),
            workingDirectory: URL(fileURLWithPath: "/tmp/../tmp")
        )

        XCTAssertEqual(configuration.workingDirectory.path, "/tmp")
    }

    func testNormalizesOSC7FileURL() {
        let workingDirectory = TerminalWorkingDirectoryNormalizer.normalize(
            "file:///Users/gordon%20beeming/Developer/../workspace"
        )

        XCTAssertEqual(workingDirectory?.path, "/Users/gordon beeming/workspace")
    }

    func testNormalizesShellDirectoryPath() {
        let workingDirectory = TerminalWorkingDirectoryNormalizer.normalize("/tmp/../workspace")

        XCTAssertEqual(workingDirectory?.path, "/workspace")
    }

    func testRejectsNonFileOSC7Value() {
        XCTAssertNil(TerminalWorkingDirectoryNormalizer.normalize("https://example.com/workspace"))
    }

    func testTerminalLinkRouterAcceptsEveryValidWebHostAndRejectsOtherSchemes() {
        XCTAssertEqual(
            TerminalLinkRouter.webURL(from: "https://example.com/path?query=yes#result")?.absoluteString,
            "https://example.com/path?query=yes#result"
        )
        XCTAssertEqual(TerminalLinkRouter.webURL(from: "http://localhost:3000")?.host, "localhost")
        XCTAssertNil(TerminalLinkRouter.webURL(from: "file:///tmp/report.html"))
        XCTAssertNil(TerminalLinkRouter.webURL(from: "ssh://example.com"))
        XCTAssertNil(TerminalLinkRouter.webURL(from: "https:///missing-host"))
    }
}
