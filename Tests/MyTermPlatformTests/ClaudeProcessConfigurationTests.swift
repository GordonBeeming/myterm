import Darwin
import Foundation
import MyTermCore
import XCTest
@testable import MyTermPlatform

final class ClaudeProcessConfigurationTests: XCTestCase {
    func testReadsTheEnvironmentAfterTheArguments() throws {
        let buffer = procArgs(path: "/usr/local/bin/claude", padding: 3, arguments: ["claude", "--resume", "abc"],
                              environment: ["HOME=/Users/someone", "CLAUDE_CONFIG_DIR=/Users/someone/.claude-work",
                                            "CLAUDE_CONFIG_DIR=/ignored", "NOVALUE", "=nameless", "EMPTY="])
        let environment = try XCTUnwrap(ClaudeProcessConfiguration.environment(fromProcArgs: buffer))
        XCTAssertEqual(environment["CLAUDE_CONFIG_DIR"], "/Users/someone/.claude-work", "getenv returns the first definition")
        XCTAssertEqual(environment["HOME"], "/Users/someone")
        XCTAssertEqual(environment["EMPTY"], "")
        XCTAssertNil(environment["NOVALUE"])
        XCTAssertNil(environment["claude"], "an argument is never read as a variable")
    }

    func testAnArgumentThatLooksLikeAVariableStaysAnArgument() throws {
        let buffer = procArgs(path: "/bin/claude", padding: 0, arguments: ["claude", "CLAUDE_CONFIG_DIR=/spoofed"],
                              environment: [])
        let environment = try XCTUnwrap(ClaudeProcessConfiguration.environment(fromProcArgs: buffer))
        XCTAssertNil(environment["CLAUDE_CONFIG_DIR"])
    }

    func testABufferShorterThanItClaimsIsRejected() {
        XCTAssertNil(ClaudeProcessConfiguration.environment(fromProcArgs: Data([1, 0])))
        XCTAssertNil(ClaudeProcessConfiguration.environment(fromProcArgs: Data([1, 0, 0, 0] + Array("/bin/claude".utf8))),
                     "an executable path without its terminator")
        let missingArguments = procArgs(path: "/bin/claude", padding: 1, arguments: ["claude"], environment: [])
            .prefix(4 + "/bin/claude".utf8.count + 2)
        var claimsTwo = Data(missingArguments)
        claimsTwo.replaceSubrange(0..<4, with: withUnsafeBytes(of: Int32(2)) { Data($0) })
        XCTAssertNil(ClaudeProcessConfiguration.environment(fromProcArgs: claimsTwo))
        XCTAssertNil(ClaudeProcessConfiguration.environment(fromProcArgs: withUnsafeBytes(of: Int32(-1)) { Data($0) }))
    }

    func testFindsTheClaudeRunningBelowAShell() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("myterm-claude-process-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Process names come from the executable, so a copy of sleep named claude stands in for it.
        let claude = directory.appendingPathComponent("claude")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: claude)
        // A moved platform binary is killed at launch until it carries a signature of its own.
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["-s", "-", "-f", claude.path]
        sign.standardError = FileHandle.nullDevice
        try sign.run()
        sign.waitUntilExit()
        XCTAssertEqual(sign.terminationStatus, 0, "codesign could not sign the stand-in")

        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The trailing command keeps sh from exec'ing straight into the child.
        shell.arguments = ["-c", "'\(claude.path)' 30; true"]
        shell.environment = ["CLAUDE_CONFIG_DIR": "/Users/someone/.claude-work", "PATH": "/usr/bin:/bin"]
        try shell.run()
        defer {
            shell.terminate()
            shell.waitUntilExit()
        }

        var found: ClaudeConfiguration?
        let deadline = Date().addingTimeInterval(5)
        while found == nil, Date() < deadline {
            found = ClaudeProcessConfiguration.configuration(belowShell: shell.processIdentifier)
            if found == nil { usleep(50_000) }
        }
        XCTAssertEqual(found, .directory(URL(fileURLWithPath: "/Users/someone/.claude-work", isDirectory: true)))

        let plain = Process()
        plain.executableURL = URL(fileURLWithPath: "/bin/sh")
        plain.arguments = ["-c", "/bin/sleep 30; true"]
        plain.environment = shell.environment
        try plain.run()
        defer {
            plain.terminate()
            plain.waitUntilExit()
        }
        usleep(200_000)
        XCTAssertNil(ClaudeProcessConfiguration.configuration(belowShell: plain.processIdentifier),
                     "a shell running something else names no account")
    }

    private func procArgs(path: String, padding: Int, arguments: [String], environment: [String]) -> Data {
        var data = withUnsafeBytes(of: Int32(arguments.count)) { Data($0) }
        data.append(contentsOf: Array(path.utf8) + [0])
        data.append(contentsOf: [UInt8](repeating: 0, count: padding))
        for entry in arguments + environment { data.append(contentsOf: Array(entry.utf8) + [0]) }
        data.append(0)
        return data
    }
}
