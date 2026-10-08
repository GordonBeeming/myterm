import Foundation
import Testing
@testable import MyTermRemote

@Test func reconnectManagersShareOneTokenRefresh() async throws {
    let fixture = try await RefreshRaceFixture.make()
    defer { fixture.finish() }
    let managers = try (0..<8).map { _ in try RelayTokenManager(client: fixture.client, store: fixture.store, record: fixture.old) }
    let requests = managers.map { manager in Task { try await manager.accessToken() } }
    try await fixture.responses.waitForRequest()
    fixture.responses.complete(status: 200, body: fixture.payload(access: "rotated-access", refresh: "rotated-refresh"))
    for request in requests { #expect(try await request.value == "rotated-access") }
    #expect(fixture.responses.count == 1)
    #expect(try await fixture.store.load(partition: fixture.partition)?.refreshToken == "rotated-refresh")
}

@Test func lateRefreshRejectionCannotDeleteNewLogin() async throws {
    let fixture = try await RefreshRaceFixture.make()
    defer { fixture.finish() }
    let manager = try RelayTokenManager(client: fixture.client, store: fixture.store, record: fixture.old)
    let request = Task { try await manager.accessToken() }
    try await fixture.responses.waitForRequest()
    let login = fixture.login()
    try await fixture.store.save(login)
    fixture.responses.complete(status: 401, body: Data(#"{"error":"invalid_grant"}"#.utf8))
    #expect(try await request.value == login.accessToken)
    #expect(try await fixture.store.load(partition: fixture.partition) == login)
    #expect(try await manager.accessToken() == login.accessToken)
    #expect(fixture.responses.count == 1)
}

@Test func lateRefreshSuccessCannotOverwriteNewLogin() async throws {
    let fixture = try await RefreshRaceFixture.make()
    defer { fixture.finish() }
    let manager = try RelayTokenManager(client: fixture.client, store: fixture.store, record: fixture.old)
    let request = Task { try await manager.refresh() }
    try await fixture.responses.waitForRequest()
    let login = fixture.login()
    try await fixture.store.save(login)
    fixture.responses.complete(status: 200, body: fixture.payload(access: "stale-access", refresh: "stale-refresh"))
    #expect(try await request.value == login)
    #expect(try await fixture.store.load(partition: fixture.partition) == login)
}

@Test func lateRefreshCannotResurrectLoggedOutCredentials() async throws {
    let fixture = try await RefreshRaceFixture.make()
    defer { fixture.finish() }
    let manager = try RelayTokenManager(client: fixture.client, store: fixture.store, record: fixture.old)
    let request = Task { try await manager.refresh() }
    try await fixture.responses.waitForRequest()
    try await fixture.store.remove(partition: fixture.partition)
    fixture.responses.complete(status: 200, body: fixture.payload(access: "stale-access", refresh: "stale-refresh"))
    await #expect(throws: RemoteError.authenticationRevoked) { try await request.value }
    #expect(try await fixture.store.load(partition: fixture.partition) == nil)
}

@Test func identicalCredentialWriteStillInvalidatesOldRefresh() async throws {
    let fixture = try await RefreshRaceFixture.make()
    defer { fixture.finish() }
    let manager = try RelayTokenManager(client: fixture.client, store: fixture.store, record: fixture.old)
    let request = Task { try await manager.refresh() }
    try await fixture.responses.waitForRequest()
    try await fixture.store.save(fixture.old)
    fixture.responses.complete(status: 401, body: Data(#"{"error":"invalid_grant"}"#.utf8))
    #expect(try await request.value == fixture.old)
    #expect(try await fixture.store.load(partition: fixture.partition) == fixture.old)
}

@Test func currentRefreshRejectionRemovesOnlyCurrentCredentials() async throws {
    let fixture = try await RefreshRaceFixture.make()
    defer { fixture.finish() }
    let manager = try RelayTokenManager(client: fixture.client, store: fixture.store, record: fixture.old)
    let request = Task { try await manager.refresh() }
    try await fixture.responses.waitForRequest()
    fixture.responses.complete(status: 401, body: Data(#"{"error":"invalid_grant"}"#.utf8))
    await #expect(throws: RemoteError.authenticationRevoked) { try await request.value }
    #expect(try await fixture.store.load(partition: fixture.partition) == nil)
}

@Test func unreadableCredentialsRequireSignInWithoutSendingRefresh() async throws {
    let relay = try RelayEndpoint(#require(URL(string: "https://invalid-record.example.test")))
    let secrets = RaceMemorySecrets()
    let store = TokenStore(secrets: secrets)
    let record = TokenRecord(relay: relay, accountID: UUID(), deviceID: UUID(), accessToken: "test", refreshToken: "test", expiresAt: .distantFuture)
    try await store.save(record)
    secrets.corruptRecords()
    let manager = try RelayTokenManager(client: RelayHTTPClient(endpoint: relay), store: store, record: record)
    await #expect(throws: RemoteError.authenticationRevoked) { try await manager.accessToken() }
}

private struct RefreshRaceFixture: Sendable {
    let host: String
    let old: TokenRecord
    let store: TokenStore
    let client: RelayHTTPClient
    let responses: ControlledRefreshResponses
    var partition: TokenPartition { TokenPartition(relay: old.relay, accountID: old.accountID, deviceID: old.deviceID) }
    static func make() async throws -> Self {
        let host = "\(UUID().uuidString.lowercased()).example.test"
        let relay = try RelayEndpoint(#require(URL(string: "https://\(host)")))
        let old = TokenRecord(relay: relay, accountID: UUID(), deviceID: UUID(), accessToken: "old-access", refreshToken: "old-refresh", expiresAt: .distantPast)
        let store = TokenStore(secrets: RaceMemorySecrets())
        try await store.save(old)
        let responses = ControlledRefreshResponses()
        ControlledRefreshProtocol.register(responses, host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ControlledRefreshProtocol.self]
        return Self(host: host, old: old, store: store, client: RelayHTTPClient(endpoint: relay, session: URLSession(configuration: configuration)), responses: responses)
    }
    func finish() { ControlledRefreshProtocol.unregister(host: host) }
    func login() -> TokenRecord {
        TokenRecord(relay: old.relay, accountID: old.accountID, deviceID: old.deviceID, accessToken: "login-access", refreshToken: "login-refresh", expiresAt: .distantFuture)
    }
    func payload(access: String, refresh: String) -> Data {
        Data("""
        {"access_token":"\(access)","token_type":"Bearer","expires_in":900,"refresh_token":"\(refresh)","device_id":"\(old.deviceID)","account_id":"\(old.accountID)"}
        """.utf8)
    }
}

private final class RaceMemorySecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(account: String) throws -> Data? { lock.withLock { values[account] } }
    func write(_ data: Data, account: String) throws { lock.withLock { values[account] = data } }
    func delete(account: String) throws { _ = lock.withLock { values.removeValue(forKey: account) } }
    func corruptRecords() { lock.withLock { for key in Array(values.keys) { values[key] = Data("invalid-json".utf8) } } }
}

private final class ControlledRefreshResponses: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [ControlledRefreshProtocol] = []
    private var requests = 0
    var count: Int { lock.withLock { requests } }
    func receive(_ request: ControlledRefreshProtocol) { lock.withLock { requests += 1; pending.append(request) } }
    func waitForRequest() async throws {
        for _ in 0..<200 {
            if count > 0 { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw URLError(.timedOut)
    }
    func complete(status: Int, body: Data) {
        let requests = lock.withLock { let result = pending; pending.removeAll(); return result }
        for request in requests { request.complete(status: status, body: body) }
    }
}

private final class ControlledRefreshProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: ControlledRefreshResponses] = [:]
    static func register(_ responses: ControlledRefreshResponses, host: String) { lock.withLock { handlers[host] = responses } }
    static func unregister(host: String) { _ = lock.withLock { handlers.removeValue(forKey: host) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let host = request.url?.host, let responses = Self.lock.withLock({ Self.handlers[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        responses.receive(self)
    }
    func complete(status: Int, body: Data) {
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
