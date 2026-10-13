import Foundation
import XCTest
@testable import MyTermPlatform

final class BashStartupIntegrationTests: XCTestCase {
    func testFirstReadableProfileKeepsItsSymlinkContentsAndMode() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "myterm-bash-profile-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appending(path: "dotfile")
        try "export USER_PROFILE_RAN=1".write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: real.path)
        let link = root.appending(path: ".bash_login")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: real.path)
        XCTAssertEqual(try BashStartupIntegration.install(in: root), link)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType, .typeSymbolicLink)
        let content = try String(contentsOf: real, encoding: .utf8)
        XCTAssertTrue(content.hasPrefix("export USER_PROFILE_RAN=1\n"))
        XCTAssertTrue(content.contains(BashStartupIntegration.hook))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: real.path)[.posixPermissions] as? Int, 0o600)
        _ = try BashStartupIntegration.install(in: root)
        XCTAssertEqual(try String(contentsOf: real, encoding: .utf8), content)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: ".bash_profile").path))
    }
}
