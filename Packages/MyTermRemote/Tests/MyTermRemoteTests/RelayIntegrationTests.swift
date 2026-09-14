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

@Test func nativeHTTPAndWebSocketInteroperateWithRealGoRelay() async throws {
    let fileURL = URL(fileURLWithPath: #filePath)
    let repository = (0..<5).reduce(fileURL) { value, _ in value.deletingLastPathComponent() }
    let relayDirectory = repository.appendingPathComponent("Services/relay")
    let tempDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("myterm-relay-native-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["go", "run", "./cmd/relay-test-fixture", "--temp-dir", tempDirectory.path]
    process.currentDirectoryURL = relayDirectory
    let errorPipe = Pipe()
    process.standardError = errorPipe
    process.standardOutput = Pipe()
    try process.run()
    defer {
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    let readyURL = tempDirectory.appendingPathComponent("ready.json")
    var ready = false
    for _ in 0..<200 {
        if FileManager.default.fileExists(atPath: readyURL.path) {
            ready = true
            break
        }
        guard process.isRunning else {
            let error = errorPipe.fileHandleForReading.readDataToEndOfFile()
            throw NSError(domain: "RelayFixture", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: String(decoding: error, as: UTF8.self)])
        }
        try await Task.sleep(for: .milliseconds(50))
    }
    guard ready else { throw RemoteError.timedOut }
    let fixture = try JSONDecoder().decode(RelayFixtureInfo.self, from: Data(contentsOf: readyURL))
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
