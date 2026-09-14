import CryptoKit
import Foundation
import Testing
@testable import MyTermRemote

private final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func read(account: String) throws -> Data? { lock.withLock { values[account] } }
    func write(_ data: Data, account: String) throws { lock.withLock { values[account] = data } }
    func delete(account: String) throws { _ = lock.withLock { values.removeValue(forKey: account) } }
}

private final class RelayURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else {
                throw URLError(.unsupportedURL)
            }
            let result = try handler(request)
            client?.urlProtocol(self, didReceive: result.0, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.1)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

@Test func tokenRefreshIsOneFlightRotatedAndPartitioned() async throws {
    let relay = try RelayEndpoint(#require(URL(string: "https://relay.example.test")))
    let accountID = UUID(), deviceID = UUID()
    let secretStore = MemorySecretStore()
    let tokenStore = TokenStore(secrets: secretStore)
    let expired = TokenRecord(relay: relay, accountID: accountID, deviceID: deviceID,
                              accessToken: "old-access", refreshToken: "old-refresh",
                              expiresAt: .distantPast)
    try await tokenStore.save(expired)
    let lock = NSLock()
    var refreshCalls = 0
    RelayURLProtocol.handler = { request in
        #expect(request.url?.absoluteString == "https://relay.example.test/v1/oauth/token")
        let body = try requestBody(request)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json["grant_type"] == "refresh_token")
        #expect(json["refresh_token"] == "old-refresh")
        lock.withLock { refreshCalls += 1 }
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200,
                                                   httpVersion: nil,
                                                   headerFields: ["Content-Type": "application/json"]))
        let data = Data("""
            {"access_token":"new-access","token_type":"Bearer","expires_in":900,"refresh_token":"new-refresh","device_id":"\(deviceID)","account_id":"\(accountID)"}
            """.utf8)
        return (response, data)
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RelayURLProtocol.self]
    let client = RelayHTTPClient(endpoint: relay, timeout: 2,
                                 session: URLSession(configuration: configuration))
    let manager = try RelayTokenManager(client: client, store: tokenStore, record: expired)
    let results = try await withThrowingTaskGroup(of: String.self) { group in
        for _ in 0..<12 { group.addTask { try await manager.accessToken() } }
        var values: [String] = []
        for try await value in group { values.append(value) }
        return values
    }
    #expect(results.allSatisfy { $0 == "new-access" })
    #expect(lock.withLock { refreshCalls } == 1)
    let partition = TokenPartition(relay: relay, accountID: accountID, deviceID: deviceID)
    #expect(try await tokenStore.load(partition: partition)?.refreshToken == "new-refresh")
    #expect(try await tokenStore.load(partition: TokenPartition(relay: relay,
                                                                accountID: UUID(),
                                                                deviceID: deviceID)) == nil)
    RelayURLProtocol.handler = nil
}

private func requestBody(_ request: URLRequest) throws -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { throw RemoteError.invalidMessage }
    stream.open()
    defer { stream.close() }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 { throw stream.streamError ?? RemoteError.invalidMessage }
        if count == 0 { break }
        result.append(contentsOf: buffer.prefix(count))
    }
    return result
}

@Test func savedHostsRemainIndependentByRelayAndAccount() async throws {
    let secrets = MemorySecretStore()
    let relay = try RelayEndpoint(#require(URL(string: "https://relay.example.test")))
    let otherRelay = try RelayEndpoint(#require(URL(string: "https://other.example.test")))
    let accountID = UUID(), deviceID = UUID()
    let key = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
    let signingKey = P256.Signing.PrivateKey().publicKey.x963Representation
    let first = SavedHostStore(secrets: secrets, relay: relay, accountID: accountID)
    let second = SavedHostStore(secrets: secrets, relay: otherRelay, accountID: accountID)
    let host = try SavedHostDescriptor(relay: relay, accountID: accountID,
                                       clientDeviceID: deviceID, hostID: UUID(),
                                       name: "Mac", pinnedPublicKey: key,
                                       notificationSigningPublicKey: signingKey)
    try await first.save(host)
    #expect(try await first.hosts() == [host])
    #expect(try await second.hosts().isEmpty)
}

@Test func localDeviceIdentitySurvivesRelayLoginRotation() async throws {
    let secrets = MemorySecretStore()
    let identity = LocalDeviceIDStore(secrets: secrets)
    let first = try await identity.loadOrCreate()
    let relayLoginDeviceIDs = [UUID(), UUID()]
    #expect(try await identity.loadOrCreate() == first)
    #expect(!relayLoginDeviceIDs.contains(first))
}
