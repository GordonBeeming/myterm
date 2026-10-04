import Foundation
import Network
import Testing

@testable import MyTermRemote

@Test func browserTunnelProtocolIsBoundedAndRoundTrips() throws {
    let metadata = MessageMetadata(
        hostID: UUID(), runtimeID: UUID(), workspaceID: UUID(), groupID: UUID(), tabID: UUID())
    for parameters in [
        BrowserTunnelParameters(streamID: UUID(), action: .open, host: "localhost", port: 8080),
        BrowserTunnelParameters(
            streamID: UUID(), action: .data, bytes: Data(repeating: 7, count: 32_768)),
        BrowserTunnelParameters(streamID: UUID(), action: .opened),
        BrowserTunnelParameters(streamID: UUID(), action: .ack),
        BrowserTunnelParameters(streamID: UUID(), action: .close),
    ] {
        let message = InnerMessage.browserTunnel(metadata, parameters)
        #expect(try InnerMessageCodec.decode(InnerMessageCodec.encode(message)) == message)
    }
    #expect(throws: RemoteError.self) {
        try BrowserTunnelParameters(
            streamID: UUID(), action: .data, bytes: Data(repeating: 0, count: 32_769)
        ).validate()
    }
    #expect(throws: RemoteError.self) {
        try BrowserTunnelParameters(
            streamID: UUID(), action: .open, host: "localhost\r\nInjected", port: 80
        ).validate()
    }
    #expect(throws: RemoteError.self) {
        try BrowserTunnelParameters(
            streamID: UUID(), action: .open, host: "example.com/path", port: 80
        )
        .validate()
    }
    #expect(throws: RemoteError.self) {
        try BrowserTunnelParameters(streamID: UUID(), action: .ack, bytes: Data([1])).validate()
    }
    #expect(throws: RemoteError.self) {
        try InnerMessage.browserTunnel(
            .init(hostID: UUID()), .init(streamID: UUID(), action: .close)
        )
        .validate()
    }
}

@Test func proxyConnectParserRequiresCredentialsAndRemoteAuthority() throws {
    let auth = Data("user:password".utf8).base64EncodedString()
    let header = Data(
        "CONNECT localhost:8080 HTTP/1.1\r\nProxy-Authorization: Basic \(auth)\r\n\r\n".utf8)
    let result = try RemoteBrowserProxy.parseConnect(header, username: "user", password: "password")
    #expect(result.0 == "localhost")
    #expect(result.1 == 8080)
    #expect(throws: RemoteError.self) {
        try RemoteBrowserProxy.parseConnect(header, username: "user", password: "wrong")
    }
    #expect(throws: RemoteError.self) {
        try RemoteBrowserProxy.parseConnect(
            Data("CONNECT localhost:80 HTTP/1.1\r\n\r\n".utf8), username: "user",
            password: "password")
    }
    #expect(throws: RemoteError.self) {
        try RemoteBrowserProxy.parseConnect(
            Data(
                "GET http://example.com HTTP/1.1\r\nProxy-Authorization: Basic \(auth)\r\n\r\n".utf8
            ),
            username: "user", password: "password")
    }
}

private actor BrowserTestBridge {
    var host: RemoteBrowserHostTunnel?
    var proxy: RemoteBrowserProxy?
    var frames: [BrowserTunnelParameters] = []
    func connect(host: RemoteBrowserHostTunnel, proxy: RemoteBrowserProxy) {
        self.host = host
        self.proxy = proxy
    }
    func clientSend(_ frame: BrowserTunnelParameters) async throws {
        frames.append(frame)
        try await host?.receive(frame)
    }
    func hostSend(_ frame: BrowserTunnelParameters) async throws {
        frames.append(frame)
        try await proxy?.receive(frame)
    }
    func hasData(_ bytes: Data) -> Bool {
        frames.contains { $0.action == .data && $0.bytes == bytes }
    }
}
private func browserStart(_ connection: NWConnection) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        connection.stateUpdateHandler = { [connection] state in
            switch state {
            case .ready:
                connection.stateUpdateHandler = nil
                continuation.resume()
            case .failed(let error):
                connection.stateUpdateHandler = nil
                continuation.resume(throwing: error)
            case .cancelled:
                connection.stateUpdateHandler = nil
                continuation.resume(throwing: CancellationError())
            default: break
            }
        }
        connection.start(queue: .global())
    }
}
private func browserWrite(_ connection: NWConnection, _ data: Data) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        connection.send(
            content: data,
            completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
    }
}
private func browserRead(_ connection: NWConnection) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { bytes, _, _, error in
            if let error {
                continuation.resume(throwing: error)
            } else if let bytes {
                continuation.resume(returning: bytes)
            } else {
                continuation.resume(throwing: CancellationError())
            }
        }
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [RemoteBrowserProxyProtocol.httpConnect, .socks5])
func browserProxyTransportsRealTCPWithAcknowledgedChunks(proxyProtocol: RemoteBrowserProxyProtocol)
    async throws
{
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    let listener = try NWListener(using: parameters)
    listener.newConnectionHandler = { connection in
        Task {
            do {
                try await browserStart(connection)
                var count = 0
                while count < 70_000 {
                    let bytes = try await browserRead(connection)
                    count += bytes.count
                    try await browserWrite(connection, bytes)
                }
            } catch { connection.cancel() }
        }
    }
    let targetPort: UInt16 = try await withCheckedThrowingContinuation { continuation in
        listener.stateUpdateHandler = { [listener] state in
            switch state {
            case .ready:
                listener.stateUpdateHandler = nil
                if let port = listener.port {
                    continuation.resume(returning: port.rawValue)
                } else {
                    continuation.resume(throwing: RemoteError.invalidMessage)
                }
            case .failed(let error):
                listener.stateUpdateHandler = nil
                continuation.resume(throwing: error)
            default: break
            }
        }
        listener.start(queue: .global())
    }
    defer { listener.cancel() }
    let bridge = BrowserTestBridge()
    let host = RemoteBrowserHostTunnel(send: { try await bridge.hostSend($0) })
    let proxy = RemoteBrowserProxy(send: { try await bridge.clientSend($0) })
    await bridge.connect(host: host, proxy: proxy)
    let endpoint = try await proxy.start(protocolKind: proxyProtocol)
    let client = NWConnection(
        host: "127.0.0.1", port: try #require(NWEndpoint.Port(rawValue: endpoint.port)), using: .tcp
    )
    defer { client.cancel() }
    try await browserStart(client)
    if proxyProtocol == .httpConnect {
        let authentication = Data("\(endpoint.username):\(endpoint.password)".utf8)
            .base64EncodedString()
        try await browserWrite(
            client,
            Data(
                "CONNECT localhost:\(targetPort) HTTP/1.1\r\nProxy-Authorization: Basic \(authentication)\r\n\r\n"
                    .utf8))
        let response = try await browserRead(client)
        #expect(
            String(data: response, encoding: .utf8)?.contains("200 Connection Established") == true)
    } else {
        try await browserWrite(client, Data([5, 1, 2]))
        #expect(try await browserRead(client) == Data([5, 2]))
        var authentication = Data([1, UInt8(endpoint.username.utf8.count)])
        authentication.append(Data(endpoint.username.utf8))
        authentication.append(UInt8(endpoint.password.utf8.count))
        authentication.append(Data(endpoint.password.utf8))
        try await browserWrite(client, authentication)
        #expect(try await browserRead(client) == Data([1, 0]))
        var request = Data([5, 1, 0, 3, 9])
        request.append(Data("localhost".utf8))
        request.append(UInt8(targetPort >> 8))
        request.append(UInt8(targetPort & 255))
        try await browserWrite(client, request)
        #expect(try await browserRead(client) == Data([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]))
    }
    let payload = Data(repeating: 23, count: 70_000)
    try await browserWrite(client, payload)
    var received = Data()
    while received.count < payload.count { received.append(try await browserRead(client)) }
    #expect(received == payload)
    #expect(await bridge.hasData(Data(repeating: 23, count: 32_768)))
    await proxy.stop()
    await host.closeAll()
}

@Test(.timeLimit(.minutes(1))) func browserSOCKSProxyRejectsUnauthenticatedMethod() async throws {
    let proxy = RemoteBrowserProxy(send: { _ in throw RemoteError.invalidMessage })
    let endpoint = try await proxy.start(protocolKind: .socks5)
    let client = NWConnection(
        host: "127.0.0.1", port: try #require(NWEndpoint.Port(rawValue: endpoint.port)), using: .tcp
    )
    defer { client.cancel() }
    try await browserStart(client)
    try await browserWrite(client, Data([5, 1, 0]))
    #expect(try await browserRead(client) == Data([5, 255]))
    await proxy.stop()
}

@Test func closedHostBrowserTunnelCannotReopenSockets() async throws {
    let host = RemoteBrowserHostTunnel(send: { _ in throw RemoteError.invalidMessage })
    await host.closeAll()
    await #expect(throws: CancellationError.self) {
        try await host.receive(
            .init(streamID: UUID(), action: .open, host: "localhost", port: 8080))
    }
}

private actor BrowserFrameRecorder {
    var frames: [BrowserTunnelParameters] = []
    func append(_ frame: BrowserTunnelParameters) { frames.append(frame) }
    func closes() -> Int { frames.filter { $0.action == .close }.count }
}

@Test func proxyModeSwitchRetiresLateFramesWithoutDroppingThePairedConnection() async throws {
    let recorder = BrowserFrameRecorder()
    let old = RemoteBrowserProxy(send: { await recorder.append($0) })
    _ = try await old.start()
    await old.stop()
    let replacement = RemoteBrowserProxy(send: { await recorder.append($0) })
    _ = try await replacement.start(protocolKind: .socks5)
    let retiredStream = UUID()
    try await replacement.receive(.init(streamID: retiredStream, action: .opened))
    try await replacement.receive(.init(streamID: retiredStream, action: .data, bytes: Data([1])))
    try await replacement.receive(.init(streamID: retiredStream, action: .ack))
    try await replacement.receive(.init(streamID: retiredStream, action: .close))
    #expect(await recorder.closes() == 2)
    await replacement.stop()
}

private actor BrowserBlockedWrite {
    var waiter: CheckedContinuation<Void, Never>?
    var started = false
    var finished = false
    func write() async {
        started = true
        await withCheckedContinuation { waiter = $0 }
        finished = true
    }
    func release() {
        waiter?.resume()
        waiter = nil
    }
    func isWaiting() -> Bool { started && !finished }
}
private final class BrowserSlowSocket: BrowserTunnelSocket, Sendable {
    let gate: BrowserBlockedWrite
    init(gate: BrowserBlockedWrite) { self.gate = gate }
    func read(maximum: Int) async throws -> Data? { nil }
    func write(_ bytes: Data) async throws { await gate.write() }
    func cancel() { Task { await gate.release() } }
}

@Test(.timeLimit(.minutes(1))) func slowBrowserSocketDoesNotBlockTheRelayMessageReader()
    async throws
{
    let gate = BrowserBlockedWrite()
    let recorder = BrowserFrameRecorder()
    let streams = BrowserStreams(send: { await recorder.append($0) })
    let id = UUID()
    try await streams.insert(BrowserSlowSocket(gate: gate), id: id, opened: true)
    try await streams.receive(.init(streamID: id, action: .data, bytes: Data([1])))
    for _ in 0..<100 {
        if await gate.isWaiting() { break }
        await Task.yield()
    }
    #expect(await gate.isWaiting())
    // The same serial caller remains free to process unrelated messages while this write stalls.
    try await streams.receive(.init(streamID: UUID(), action: .ack))
    await streams.closeAll()
}

@Test(.timeLimit(.minutes(1))) func duplicateBrowserOpenDoesNotCreateConcurrentSocketPumps()
    async throws
{
    let gate = BrowserBlockedWrite()
    let streams = BrowserStreams(send: { _ in })
    let id = UUID()
    try await streams.insert(BrowserSlowSocket(gate: gate), id: id, opened: false)
    let first = Task { try await streams.begin(id, connectResponse: true) }
    for _ in 0..<100 {
        if await gate.isWaiting() { break }
        await Task.yield()
    }
    #expect(await gate.isWaiting())
    // A duplicate opened frame must return without starting a second blocked write or reader.
    try await streams.begin(id, connectResponse: true)
    #expect(await gate.isWaiting())
    await gate.release()
    try await first.value
    await streams.closeAll()
}

private actor BrowserResolverGate {
    var waiter: CheckedContinuation<Void, Never>?
    var entered = false
    func wait() async {
        entered = true
        await withCheckedContinuation { waiter = $0 }
    }
    func release() {
        waiter?.resume()
        waiter = nil
    }
    func isWaiting() -> Bool { entered }
}

@Test(.timeLimit(.minutes(1))) func hostBrowserActivityIncludesPendingDestinationResolution()
    async throws
{
    let gate = BrowserResolverGate()
    let host = RemoteBrowserHostTunnel(
        send: { _ in },
        resolve: { host, port in
            await gate.wait()
            return (host, port)
        })
    #expect(await host.hasOpenStreams() == false)
    let opening = Task {
        try await host.receive(.init(streamID: UUID(), action: .open, host: "localhost", port: 1))
    }
    for _ in 0..<100 {
        if await gate.isWaiting() { break }
        await Task.yield()
    }
    #expect(await gate.isWaiting())
    #expect(await host.hasOpenStreams())
    await host.closeAll()
    await gate.release()
    try await opening.value
    #expect(await host.hasOpenStreams() == false)
}

private final class BrowserCancelledSocket: BrowserTunnelSocket, Sendable {
    func read(maximum: Int) async throws -> Data? { nil }
    func write(_ bytes: Data) async throws { throw CancellationError() }
    func cancel() {}
}

@Test func cancelledBrowserConnectResponseOnlyClosesItsOwnStream() async throws {
    let recorder = BrowserFrameRecorder()
    let streams = BrowserStreams(send: { await recorder.append($0) })
    let id = UUID()
    try await streams.insert(BrowserCancelledSocket(), id: id, opened: false)
    try await streams.begin(id, connectResponse: true)
    #expect(await streams.contains(id) == false)
    // A subsequent frame on the same paired connection remains safe to process.
    try await streams.receive(.init(streamID: UUID(), action: .ack))
    for _ in 0..<100 {
        if await recorder.closes() == 1 { break }
        await Task.yield()
    }
    #expect(await recorder.closes() == 1)
}

private actor BrowserOpeningBarrier {
    var entered = 0
    var waiters: [CheckedContinuation<Void, Never>] = []
    var countWaiter: (target: Int, continuation: CheckedContinuation<Void, Never>)?
    func waitUntilCount(_ target: Int) async {
        guard entered < target else { return }
        await withCheckedContinuation { countWaiter = (target, $0) }
    }
    func wait() async {
        entered += 1
        if let countWaiter, entered >= countWaiter.target {
            self.countWaiter = nil
            countWaiter.continuation.resume()
        }
        await withCheckedContinuation { waiters.append($0) }
    }
    func count() -> Int { entered }
    func releaseAll() {
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

@Test(.timeLimit(.minutes(1))) func browserOpeningCapacityRejectsOneStreamWithoutDisconnecting()
    async throws
{
    let barrier = BrowserOpeningBarrier()
    let recorder = BrowserFrameRecorder()
    let host = RemoteBrowserHostTunnel(
        send: { await recorder.append($0) },
        resolve: { host, port in
            await barrier.wait()
            return (host, port)
        })
    var openings: [Task<Void, Error>] = []
    for _ in 0..<32 {
        openings.append(
            Task {
                try await host.receive(
                    .init(streamID: UUID(), action: .open, host: "localhost", port: 1))
            })
    }
    await barrier.waitUntilCount(32)
    #expect(await barrier.count() == 32)
    try await host.receive(.init(streamID: UUID(), action: .open, host: "localhost", port: 1))
    #expect(await recorder.closes() == 1)
    #expect(await host.hasOpenStreams())
    await host.closeAll()
    await barrier.releaseAll()
    for opening in openings { try await opening.value }
}

@Test(.timeLimit(.minutes(1))) func refusedBrowserDestinationClosesPromptlyWithoutDisconnecting()
    async throws
{
    // Release a freshly allocated loopback port immediately before attempting a refused connection.
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    #expect(descriptor >= 0)
    guard descriptor >= 0 else { return }
    var ownsDescriptor = true
    defer { if ownsDescriptor { Darwin.close(descriptor) } }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    #expect(bound == 0)
    guard bound == 0 else { return }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let located = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(descriptor, $0, &length)
        }
    }
    #expect(located == 0)
    guard located == 0 else { return }
    Darwin.close(descriptor)
    ownsDescriptor = false
    let recorder = BrowserFrameRecorder()
    let host = RemoteBrowserHostTunnel(send: { await recorder.append($0) })
    let started = ContinuousClock.now
    try await host.receive(
        .init(
            streamID: UUID(), action: .open, host: "127.0.0.1",
            port: UInt16(bigEndian: address.sin_port)))
    #expect(started.duration(to: .now) < .seconds(2))
    #expect(await recorder.closes() == 1)
    #expect(await host.hasOpenStreams() == false)
    // A normal later message remains processable on the same paired connection.
    try await host.receive(.init(streamID: UUID(), action: .ack))
    await host.closeAll()
}
