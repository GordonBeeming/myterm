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
        let environment = try XCTUnwrap(ClaudeProcessConfiguration.arguments(fromProcArgs: buffer)?.environment)
        XCTAssertEqual(environment["CLAUDE_CONFIG_DIR"], "/Users/someone/.claude-work", "getenv returns the first definition")
        XCTAssertEqual(environment["HOME"], "/Users/someone")
        XCTAssertEqual(environment["EMPTY"], "")
        XCTAssertNil(environment["NOVALUE"])
        XCTAssertNil(environment["claude"], "an argument is never read as a variable")
    }

    func testAnArgumentThatLooksLikeAVariableStaysAnArgument() throws {
        let buffer = procArgs(path: "/bin/claude", padding: 0, arguments: ["claude", "CLAUDE_CONFIG_DIR=/spoofed"],
                              environment: [])
        let environment = try XCTUnwrap(ClaudeProcessConfiguration.arguments(fromProcArgs: buffer)?.environment)
        XCTAssertNil(environment["CLAUDE_CONFIG_DIR"])
    }

    func testABufferShorterThanItClaimsIsRejected() {
        XCTAssertNil(ClaudeProcessConfiguration.arguments(fromProcArgs: Data([1, 0])))
        XCTAssertNil(ClaudeProcessConfiguration.arguments(fromProcArgs: Data([1, 0, 0, 0] + Array("/bin/claude".utf8))),
                     "an executable path without its terminator")
        let missingArguments = procArgs(path: "/bin/claude", padding: 1, arguments: ["claude"], environment: [])
            .prefix(4 + "/bin/claude".utf8.count + 2)
        var claimsTwo = Data(missingArguments)
        claimsTwo.replaceSubrange(0..<4, with: withUnsafeBytes(of: Int32(2)) { Data($0) })
        XCTAssertNil(ClaudeProcessConfiguration.arguments(fromProcArgs: claimsTwo))
        XCTAssertNil(ClaudeProcessConfiguration.arguments(fromProcArgs: withUnsafeBytes(of: Int32(-1)) { Data($0) }))
    }

    func testTheExecutablePathIsTheNameTheProcessWasStartedAs() throws {
        let buffer = procArgs(path: "/Users/someone/.local/bin/claude", padding: 2, arguments: ["claude"], environment: [])
        let arguments = try XCTUnwrap(ClaudeProcessConfiguration.arguments(fromProcArgs: buffer))
        XCTAssertEqual(arguments.executablePath, "/Users/someone/.local/bin/claude")
        XCTAssertTrue(arguments.isClaude)
        let node = try XCTUnwrap(ClaudeProcessConfiguration.arguments(fromProcArgs:
            procArgs(path: "/usr/local/bin/node", padding: 0, arguments: ["node", "claude"], environment: [])))
        XCTAssertFalse(node.isClaude)
    }

    func testFindsTheForegroundClaudeBelowAShellAndIgnoresABackgroundOne() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("myterm-claude-process-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Claude Code is installed as a `claude` link to a versioned file, so the kernel's process
        // name is the version. A signed copy of sleep stands in for that file.
        let versioned = directory.appendingPathComponent("2.1.0")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: versioned)
        // A moved platform binary is killed at launch until it carries a signature of its own.
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["-s", "-", "-f", versioned.path]
        sign.standardError = FileHandle.nullDevice
        try sign.run()
        sign.waitUntilExit()
        XCTAssertEqual(sign.terminationStatus, 0, "codesign could not sign the stand-in")
        let claude = directory.appendingPathComponent("claude")
        try FileManager.default.createSymbolicLink(at: claude, withDestinationURL: versioned)

        // script gives the shell a terminal; job control puts the background Claude in its own
        // group, so only the foreground one holds the terminal.
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        shell.arguments = ["-q", "/dev/null", "/bin/sh", "-c",
                           "set -m; CLAUDE_CONFIG_DIR=/Users/someone/.claude-background '\(claude.path)' 30 & " +
                           "CLAUDE_CONFIG_DIR=/Users/someone/.claude-work '\(claude.path)' 30; true"]
        shell.standardInput = FileHandle.nullDevice
        shell.standardOutput = FileHandle.nullDevice
        try shell.run()
        defer {
            shell.terminate()
            shell.waitUntilExit()
        }

        var found: ClaudeConfiguration?
        let deadline = Date().addingTimeInterval(5)
        while found == nil, Date() < deadline {
            // The shell is script's child; the lookup starts from the shell, as MyTerm's panes do.
            if let sh = childProcesses(of: shell.processIdentifier).first {
                found = ClaudeProcessConfiguration.configuration(belowShell: sh)
            }
            if found == nil { usleep(50_000) }
        }
        XCTAssertEqual(found, .directory(URL(fileURLWithPath: "/Users/someone/.claude-work", isDirectory: true)))
        XCTAssertNil(ClaudeProcessConfiguration.configuration(belowShell: getpid()), "the test has no terminal")
    }

    private func childProcesses(of parent: pid_t) -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 64)
        let count = pids.withUnsafeMutableBytes { proc_listchildpids(parent, $0.baseAddress, Int32($0.count)) }
        return count > 0 ? Array(pids.prefix(Int(count))) : []
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
