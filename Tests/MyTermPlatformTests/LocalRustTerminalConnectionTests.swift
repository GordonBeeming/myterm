#if DEBUG
import Darwin
import Foundation
import MyTermContinuity
import XCTest
@testable import MyTermPlatform

@MainActor
final class LocalRustTerminalConnectionTests: XCTestCase {
    func testReattachmentReceivesOutputInOrderThroughAStalledReader() async throws {
        let (connection, peer) = try makeConnection()
        defer { connection.disconnect() }

        let id = try XCTUnwrap(UUID(uuidString: "D04FCE90-76FD-4C6B-AEE7-F00000000001"))
        try connection.begin(id: id, starting: false)
        let request = try XCTUnwrap(peer.read(upToCount: 21))
        XCTAssertEqual(request, Data([
            2, 0, 0, 0, 16,
            0xD0, 0x4F, 0xCE, 0x90, 0x76, 0xFD, 0x4C, 0x6B,
            0xAE, 0xE7, 0xF0, 0, 0, 0, 0, 1,
        ]))

        let writer = Task.detached {
            try peer.write(contentsOf: Self.frame(0x81, payload: Data([0, 0, 0, 12, 0, 0, 0, 34])))
            for value in UInt8(0)..<128 {
                try peer.write(contentsOf: Self.frame(0x82, payload: Data(repeating: value, count: 8_192)))
            }
            try peer.write(contentsOf: Self.frame(0x83, payload: Data("Shell finished".utf8)))
        }
        guard case let .ready(serverPID, shellPID) = try await connection.nextEvent(expectingReady: true) else {
            return XCTFail("The reattach reply did not identify the two processes")
        }
        XCTAssertEqual(serverPID, 12)
        XCTAssertEqual(shellPID, 34)
        // Give the producer time to outrun a reader that eagerly queues every reply.
        try await Task.sleep(for: .milliseconds(100))
        for value in UInt8(0)..<128 {
            guard case let .output(output) = try await connection.nextEvent(expectingReady: false) else {
                return XCTFail("Terminal output was interrupted")
            }
            XCTAssertEqual(output, Data(repeating: value, count: 8_192))
        }
        do {
            _ = try await connection.nextEvent(expectingReady: false)
            XCTFail("An ended shell should surface its terminal status")
        } catch LocalRustTerminalError.server(let message) {
            XCTAssertEqual(message, "Shell finished")
        }
        try await writer.value
    }

    func testReadyMustIdentifyTheAuthenticatedServer() async throws {
        let (connection, peer) = try makeConnection()
        defer { connection.disconnect() }

        try peer.write(contentsOf: Self.frame(0x81, payload: Data([0, 0, 0, 99, 0, 0, 0, 34])))
        do {
            _ = try await connection.nextEvent(expectingReady: true)
            XCTFail("The session accepted a server PID that differs from its authenticated peer")
        } catch LocalRustTerminalError.invalidMessage {
            // The claimed ID cannot substitute for the kernel's process identity.
        }
    }

    func testWorkspaceAttachmentReceivesControllerAndAuthoritativeGeometry() async throws {
        let (connection, peer) = try makeConnection()
        defer { connection.disconnect() }
        let client = UUID()

        try connection.beginWorkspace(sessionID: UUID(), clientID: client, launch: nil)
        let request = try XCTUnwrap(peer.read(upToCount: 37))
        XCTAssertEqual(request.prefix(5), Data([6, 0, 0, 0, 32]))

        try peer.write(contentsOf: Self.frame(0x81, payload: Data([0, 0, 0, 12, 0, 0, 0, 34])))
        var rawClient = client.uuid
        var control = withUnsafeBytes(of: &rawClient) { Data($0) }
        control.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 7, 1])
        try peer.write(contentsOf: Self.frame(0x84, payload: control))
        try peer.write(contentsOf: Self.frame(0x88, payload: Data([0, 101, 0, 38])))

        let attachment = try await connection.workspaceAttachment()
        XCTAssertEqual(attachment.shellPID, 34)
        XCTAssertEqual(attachment.control.owner, client)
        XCTAssertEqual(attachment.control.revision, 7)
        guard case .geometry(let columns, let rows, _) = try await connection.nextWorkspaceEvent() else {
            return XCTFail("The client did not receive the size applied by the server")
        }
        XCTAssertEqual(columns, 101)
        XCTAssertEqual(rows, 38)
    }

    func testCheckpointChunksPrecedeAnExplicitAppliedAcknowledgement() async throws {
        let (connection, peer) = try makeConnection()
        defer { connection.disconnect() }
        try connection.beginWorkspace(sessionID: UUID(), clientID: UUID(), launch: nil, checkpoint: true)
        XCTAssertEqual(try peer.read(upToCount: 37)?.prefix(5), Data([12, 0, 0, 0, 32]))

        try peer.write(contentsOf: Self.frame(0x81, payload: Data([0, 0, 0, 12, 0, 0, 0, 34, 1])))
        try peer.write(contentsOf: Self.frame(0x84, payload: Data(count: 25)))
        try peer.write(contentsOf: Self.frame(0x86, payload: Data([0, 0, 0, 0, 0, 0, 0, 42, 0, 0, 0, 5])))
        try peer.write(contentsOf: Self.frame(0x87, payload: Data([1, 2])))
        try peer.write(contentsOf: Self.frame(0x87, payload: Data([3, 4, 5])))
        let checkpoint = try await connection.workspaceAttachment().checkpoint
        XCTAssertEqual(checkpoint?.sequence, 42)
        XCTAssertEqual(checkpoint?.bytes, Data([1, 2, 3, 4, 5]))

        try connection.acknowledgeWorkspaceCheckpoint(sequence: 42)
        XCTAssertEqual(try peer.read(upToCount: 13), Data([13, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 42]))
    }

    private func makeConnection() throws -> (LocalRustTerminalConnection, FileHandle) {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw SessionHostError.system("create terminal test socket", errno)
        }
        let peer = FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
        let connection = LocalRustTerminalConnection(descriptor: descriptors[0], peerPID: 12)
        try SessionHostSocket.configure(descriptors[0])
        try SessionHostSocket.configure(descriptors[1])
        return (connection, peer)
    }

    private nonisolated static func frame(_ kind: UInt8, payload: Data) -> Data {
        var length = UInt32(payload.count).bigEndian
        var frame = Data([kind])
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }
}
#endif
