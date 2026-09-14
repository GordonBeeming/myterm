import CryptoKit
import Foundation
import Security
import Testing
@testable import MyTermRemote

private struct RelayFixtureInfo: Decodable {
    let url: URL
    let certificatePath: String
    let accountID: UUID
    let hostDeviceID: UUID
    let hostToken: String
    let clientDeviceID: UUID
    let clientToken: String

    enum CodingKeys: String, CodingKey {
        case url
        case certificatePath = "certificate_path"
        case accountID = "account_id"
        case hostDeviceID = "host_device_id"
        case hostToken = "host_token"
        case clientDeviceID = "client_device_id"
        case clientToken = "client_token"
    }
}

private final class FixtureTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let certificate: SecCertificate

    init(certificateData: Data) throws {
        guard let certificate = SecCertificateCreateWithData(nil, certificateData as CFData) else {
            throw RemoteError.invalidResponse
        }
        self.certificate = certificate
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              SecTrustSetAnchorCertificates(trust, [certificate] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

private let fixtureBuildTimeout: Duration = .seconds(180)
private let fixtureReadyTimeout: Duration = .seconds(10)
private let fixturePollInterval: Duration = .milliseconds(50)
private let maximumFixtureLogBytes = 32 * 1_024

private func buildRelayFixture(in tempDirectory: URL, relayDirectory: URL) async throws -> URL {
    let binaryURL = tempDirectory.appendingPathComponent("relay-test-fixture")
    let logURL = tempDirectory.appendingPathComponent("build.log")
    FileManager.default.createFile(atPath: logURL.path, contents: nil)
    let log = try FileHandle(forWritingTo: logURL)
    defer { try? log.close() }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["go", "build", "-o", binaryURL.path, "./cmd/relay-test-fixture"]
    process.currentDirectoryURL = relayDirectory
    process.standardOutput = log
    process.standardError = log
    try process.run()

    do {
        try await waitForExit(process, timeout: fixtureBuildTimeout)
    } catch {
        stopAndWait(process)
        throw fixtureError("Timed out while compiling the relay fixture.", logURL: logURL)
    }
    guard process.terminationStatus == 0 else {
        throw fixtureError("Relay fixture compilation failed with status \(process.terminationStatus).",
                           logURL: logURL)
    }
    return binaryURL
}

private func launchRelayFixture(binaryURL: URL, tempDirectory: URL) throws -> (Process, FileHandle, URL) {
    let logURL = tempDirectory.appendingPathComponent("server.log")
    FileManager.default.createFile(atPath: logURL.path, contents: nil)
    let log = try FileHandle(forWritingTo: logURL)
    let process = Process()
    process.executableURL = binaryURL
    process.arguments = ["--temp-dir", tempDirectory.path]
    process.standardOutput = log
    process.standardError = log
    do {
        try process.run()
        return (process, log, logURL)
    } catch {
        try? log.close()
        throw error
    }
}

private func waitForFixture(process: Process, readyURL: URL, logURL: URL) async throws -> RelayFixtureInfo {
    let deadline = ContinuousClock.now.advanced(by: fixtureReadyTimeout)
    while ContinuousClock.now < deadline {
        if FileManager.default.fileExists(atPath: readyURL.path),
           let data = try? Data(contentsOf: readyURL),
           let fixture = try? JSONDecoder().decode(RelayFixtureInfo.self, from: data) {
            return fixture
        }
        guard process.isRunning else {
            process.waitUntilExit()
            throw fixtureError("Relay fixture exited with status \(process.terminationStatus) before becoming ready.",
                               logURL: logURL)
        }
        try await Task.sleep(for: fixturePollInterval)
    }
    throw fixtureError("Timed out waiting for the compiled relay fixture to become ready.",
                       logURL: logURL)
}

private func waitForExit(_ process: Process, timeout: Duration) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while process.isRunning {
        guard ContinuousClock.now < deadline else { throw RemoteError.timedOut }
        try await Task.sleep(for: fixturePollInterval)
    }
    process.waitUntilExit()
}

private func stopAndWait(_ process: Process) {
    if process.isRunning { process.terminate() }
    process.waitUntilExit()
}

private func fixtureError(_ message: String, logURL: URL) -> NSError {
    let data = (try? Data(contentsOf: logURL)) ?? Data()
    let tail = data.suffix(maximumFixtureLogBytes)
    let log = String(decoding: tail, as: UTF8.self)
    let description = log.isEmpty ? message : "\(message)\n\(log)"
    return NSError(domain: "RelayFixture", code: 1,
                   userInfo: [NSLocalizedDescriptionKey: description])
}

@Test func nativeHTTPAndWebSocketInteroperateWithRealGoRelay() async throws {
    let fileURL = URL(fileURLWithPath: #filePath)
    let repository = (0..<5).reduce(fileURL) { value, _ in value.deletingLastPathComponent() }
    let relayDirectory = repository.appendingPathComponent("Services/relay")
    let tempDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("myterm-relay-native-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDirectory) }

    let binaryURL = try await buildRelayFixture(in: tempDirectory, relayDirectory: relayDirectory)
    let (process, serverLog, serverLogURL) = try launchRelayFixture(
        binaryURL: binaryURL, tempDirectory: tempDirectory
    )
    defer {
        stopAndWait(process)
        try? serverLog.close()
    }

    let readyURL = tempDirectory.appendingPathComponent("ready.json")
    let fixture = try await waitForFixture(process: process, readyURL: readyURL,
                                           logURL: serverLogURL)
    let certificatePEM = try Data(contentsOf: URL(fileURLWithPath: fixture.certificatePath))
    guard let certificateText = String(data: certificatePEM, encoding: .utf8),
          let bodyRange = certificateText.range(of: "-----BEGIN CERTIFICATE-----\n")?.upperBound,
          let endRange = certificateText.range(of: "\n-----END CERTIFICATE-----")?.lowerBound,
          let certificateDER = Data(base64Encoded: String(certificateText[bodyRange..<endRange])
            .replacingOccurrences(of: "\n", with: "")) else { throw RemoteError.invalidResponse }
    let delegate = try FixtureTrustDelegate(certificateData: certificateDER)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    let endpoint = try RelayEndpoint(fixture.url)
    let http = RelayHTTPClient(endpoint: endpoint, timeout: 5, session: session)

    let hostID = UUID()
    let hostKey = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
    let registered = try await http.registerHost(hostID: hostID, name: "Native Mac",
                                                 publicKey: hostKey, bearer: fixture.hostToken)
    #expect(registered.hostID == hostID)
    #expect(registered.publicKey == hostKey.base64URL)
    #expect(try await http.hosts(bearer: fixture.clientToken).map(\.hostID) == [hostID])
    let devices = try await http.devices(bearer: fixture.hostToken)
    #expect(Set(devices.map(\.deviceID)) == [fixture.hostDeviceID, fixture.clientDeviceID])

    let hostSocket = RelayWebSocketClient(endpoint: endpoint, hostID: hostID,
                                          role: .host, session: session)
    let clientSocket = RelayWebSocketClient(endpoint: endpoint, hostID: hostID,
                                            role: .client, session: session)
    var hostEvents = try await hostSocket.connect(accessToken: fixture.hostToken).makeAsyncIterator()
    guard case .ready(let hostReady) = try await hostEvents.next() else {
        throw RemoteError.invalidResponse
    }
    var clientEvents = try await clientSocket.connect(accessToken: fixture.clientToken).makeAsyncIterator()
    guard case .ready = try await clientEvents.next() else { throw RemoteError.invalidResponse }

    var clientConnectionID: UUID?
    while clientConnectionID == nil {
        guard let event = try await hostEvents.next() else { throw RemoteError.disconnected }
        if case .peer(let peer) = event, peer.transportOnline { clientConnectionID = peer.connectionID }
    }
    let innerPayload = Data(repeating: 7, count: EncryptedEnvelope.binaryHeaderBytes + 16)
    let packet = try RelayApplicationPacket.encryptedFrame(innerPayload).encoded()
    try await clientSocket.send(destinationConnectionID: RelayFrame.broadcastDestination,
                                payload: packet)
    guard case .application(let source, let received) = try await hostEvents.next() else {
        throw RemoteError.invalidResponse
    }
    #expect(source == clientConnectionID)
    #expect(received == packet)

    let replyPacket = try RelayApplicationPacket.encryptedFrame(
        Data(repeating: 8, count: EncryptedEnvelope.binaryHeaderBytes + 16)
    ).encoded()
    try await hostSocket.send(destinationConnectionID: try #require(clientConnectionID),
                              payload: replyPacket)
    var response: Data?
    while response == nil {
        guard let event = try await clientEvents.next() else { throw RemoteError.disconnected }
        if case .application(let source, let payload) = event {
            #expect(source == hostReady.connectionID)
            response = payload
        }
    }
    #expect(response == replyPacket)
    try await http.disconnectPeer(hostID: hostID,
                                  connectionID: try #require(clientConnectionID),
                                  bearer: fixture.hostToken)
    guard case .peer(let offline) = try await hostEvents.next() else {
        throw RemoteError.invalidResponse
    }
    #expect(offline.connectionID == clientConnectionID)
    #expect(!offline.transportOnline)
    await hostSocket.disconnect()
}
