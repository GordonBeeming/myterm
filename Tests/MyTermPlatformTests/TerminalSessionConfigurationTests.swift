import XCTest
@testable import MyTermPlatform

final class TerminalSessionConfigurationTests: XCTestCase {
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
}
