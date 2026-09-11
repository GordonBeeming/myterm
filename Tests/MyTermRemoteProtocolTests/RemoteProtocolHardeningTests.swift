import Network
import XCTest
@testable import MyTermRemoteProtocol

/// What the protocol does with input that was never meant kindly: nested payloads, frames at and
/// past the cap, replies that carry keystrokes, and a host that sends something unreadable.
final class RemoteProtocolHardeningTests: XCTestCase {
    // MARK: - Control payloads

    func testADeeplyNestedControlPayloadIsRefusedRatherThanCrashing() {
        // A hundred thousand open brackets is a stack overflow for a naive parser. Foundation
        // refuses it at a fixed depth, and this pins that the codec lets that refusal through as an
        // error rather than a crash.
        let depth = 100_000
        let nested = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        let payload = "{\"type\":\"attach\",\"attach\":\(nested)}"
        let frame = RemoteFrame(kind: .control, payload: Array(payload.utf8))
        XCTAssertThrowsError(try RemoteControlCodec.decode(frame))
    }

    func testAControlPayloadOfAnUnknownTypeIsRefused() {
        let frame = RemoteFrame(kind: .control, payload: Array(#"{"type":"shutdown","shutdown":{}}"#.utf8))
        XCTAssertThrowsError(try RemoteControlCodec.decode(frame))
    }

    func testAControlPayloadWhoseBodyIsMissingIsRefused() {
        // The type names a body the message does not carry.
        let frame = RemoteFrame(kind: .control, payload: Array(#"{"type":"attach"}"#.utf8))
        XCTAssertThrowsError(try RemoteControlCodec.decode(frame))
    }

    func testAControlPayloadThatIsNotJSONIsRefused() {
        for bytes in [[UInt8](), Array("not json".utf8), [0xFF, 0xFE, 0x00], Array("[]".utf8), Array("null".utf8)] {
            let frame = RemoteFrame(kind: .control, payload: bytes)
            XCTAssertThrowsError(try RemoteControlCodec.decode(frame), "\(bytes)")
        }
    }

    // MARK: - Frames at the cap

    func testAFrameExactlyAtTheCapIsAcceptedAndOneByteOverIsNot() throws {
        let cap = RemoteFrameCodec.maximumFrameBytes

        var atCap = RemoteFrameDecoder()
        atCap.append(header(length: cap) + [RemoteFrameKind.output.rawValue])
        XCTAssertNil(try atCap.nextFrame(), "the frame is incomplete, not invalid")

        var overCap = RemoteFrameDecoder()
        overCap.append(header(length: cap + 1) + [RemoteFrameKind.output.rawValue])
        XCTAssertThrowsError(try overCap.nextFrame()) { error in
            XCTAssertEqual(error as? RemoteFrameError, .frameTooLarge(cap + 1))
        }
    }

    func testAControlPayloadAtTheCapDecodesWithoutCrashing() throws {
        // A device may send a hello whose name fills the whole frame. It has to decode, or fail,
        // without taking the host down; nothing here caps the name, which is its own finding.
        let padding = RemoteFrameCodec.maximumFrameBytes - 200
        let hello = RemoteHello(deviceName: String(repeating: "n", count: padding), token: "t")
        let frame = try RemoteControlCodec.encode(.hello(hello))
        XCTAssertLessThanOrEqual(frame.payload.count + 1, RemoteFrameCodec.maximumFrameBytes)

        var decoder = RemoteFrameDecoder()
        decoder.append(RemoteFrameCodec.encode(frame))
        let decoded = try XCTUnwrap(try decoder.nextFrame())
        guard case .hello(let received) = try RemoteControlCodec.decode(decoded) else {
            return XCTFail("expected a hello")
        }
        XCTAssertEqual(received.deviceName.count, padding)
    }

    func testAFrameErrorIsPermanentUntilTheBufferIsDropped() {
        // The decoder does not skip a bad header on its own: it cannot know where the next frame
        // starts. Whoever owns the connection has to close it. Both ends are checked for that in
        // the socket tests; this pins the contract they rely on.
        var decoder = RemoteFrameDecoder()
        decoder.append(header(length: 0) + [1, 2, 3, 4])
        XCTAssertThrowsError(try decoder.nextFrame())
        XCTAssertThrowsError(try decoder.nextFrame())
        decoder.append(RemoteFrameCodec.encode(RemoteFrame(kind: .output, payload: [9])))
        XCTAssertThrowsError(try decoder.nextFrame(), "a good frame behind a bad header is unreachable")
    }

    func testASessionPayloadOfExactlySixteenBytesCarriesNoBytes() throws {
        let session = UUID()
        let payload = RemoteSessionPayload.encode(session: session, bytes: [])
        XCTAssertEqual(payload.count, 16)
        let decoded = try XCTUnwrap(RemoteSessionPayload.decode(payload))
        XCTAssertEqual(decoded.session, session)
        XCTAssertTrue(decoded.bytes.isEmpty)
    }

    // MARK: - What a reply may carry

    func testAReplyCarryingAnyControlCharacterIsNotTypable() {
        // Each of these would drive the agent's interface rather than talk to it: a Return
        // submits, an Escape cancels, a NUL and a DEL do whatever the line discipline decides, and
        // the C1 range is escape sequences in an 8-bit terminal.
        let controls: [Unicode.Scalar] = [
            "\u{00}", "\u{08}", "\u{09}", "\u{0A}", "\u{0D}", "\u{1B}", "\u{7F}", "\u{85}", "\u{9B}",
        ]
        for scalar in controls {
            let text = "hello " + String(Character(scalar)) + " there"
            XCTAssertFalse(RemoteAgentReply(tabID: "t", text: text).isTypable, "U+\(String(scalar.value, radix: 16))")
        }
    }

    func testAReplyOfPlainWordsInAnyScriptIsTypable() {
        for text in ["fix the test", "修复测试", "исправь тест", "🙂 nice", "a\u{301} b"] {
            XCTAssertTrue(RemoteAgentReply(tabID: "t", text: text).isTypable, text)
        }
    }

    func testAReplyAtTheCapIsTypableAndOnePastItIsNot() {
        let atCap = String(repeating: "x", count: RemoteAgentReply.maximumCharacters)
        XCTAssertTrue(RemoteAgentReply(tabID: "t", text: atCap).isTypable)
        XCTAssertFalse(RemoteAgentReply(tabID: "t", text: atCap + "x").isTypable)
        XCTAssertFalse(RemoteAgentReply(tabID: "t", text: "").isTypable)
    }

    // MARK: - A host that sends something unreadable

    @MainActor
    func testAClientSentAnUnreadableFrameGivesUpRatherThanStayingConnectedForever() async throws {
        // A frame the decoder refuses stays at the front of the buffer, so a client that shrugs
        // it off processes nothing more from this connection while still reporting itself
        // connected, and every later byte piles up behind the bad header. The host closes on the
        // same error; the client has to do the same.
        let token = RemoteTransportSecurity.makeToken()
        let host = RogueHost(token: token)
        let port = try await host.start()
        defer { host.stop() }

        let client = RemoteClient(deviceName: "Pad")
        client.connect(host: "127.0.0.1", port: port, token: token)
        await waitUntil { if case .connected = client.state { return true } else { return false } }
        guard case .connected = client.state else {
            return XCTFail("the client never reached the rogue host: \(client.state)")
        }

        // A header claiming a four-gigabyte frame, then a perfectly good tree behind it.
        host.send([0xFF, 0xFF, 0xFF, 0xFF, RemoteFrameKind.control.rawValue])
        host.send(RemoteFrameCodec.encode(try RemoteControlCodec.encode(.tree(
            RemoteTree(revision: 1, folders: [], workspaces: [])
        ))))

        await waitUntil(seconds: 3) { if case .connected = client.state { return false } else { return true } }
        if case .connected = client.state {
            XCTFail("the client is still connected behind a frame it can never read")
        }
        client.disconnect()
    }

    // MARK: - Helpers

    private func header(length: Int) -> [UInt8] {
        [
            UInt8(truncatingIfNeeded: length >> 24),
            UInt8(truncatingIfNeeded: length >> 16),
            UInt8(truncatingIfNeeded: length >> 8),
            UInt8(truncatingIfNeeded: length),
        ]
    }

    @MainActor
    private func waitUntil(seconds: TimeInterval = 5, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}

/// A host that completes the handshake, welcomes the device, and then sends whatever it is told.
private final class RogueHost: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "rogue-host")
    private var connection: NWConnection?
    private let lock = NSLock()

    init(token: String) {
        listener = try! NWListener(using: RemoteTransportSecurity.parameters(token: token), on: .any)
    }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.lock.lock()
            self.connection = connection
            self.lock.unlock()
            connection.start(queue: self.queue)
            // The device's hello arrives first. Anything at all is answered with a welcome.
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { _, _, _, _ in
                let welcome = try! RemoteControlCodec.encode(.welcome(RemoteWelcome(hostName: "Rogue", allowsInput: true)))
                connection.send(content: Data(RemoteFrameCodec.encode(welcome)), completion: .idempotent)
            }
        }
        listener.start(queue: queue)
        for _ in 0..<100 {
            if let port = listener.port?.rawValue, port != 0 { return port }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw CancellationError()
    }

    func send(_ bytes: [UInt8]) {
        lock.lock()
        let connection = self.connection
        lock.unlock()
        connection?.send(content: Data(bytes), completion: .idempotent)
    }

    func stop() {
        lock.lock()
        connection?.cancel()
        lock.unlock()
        listener.cancel()
    }
}
