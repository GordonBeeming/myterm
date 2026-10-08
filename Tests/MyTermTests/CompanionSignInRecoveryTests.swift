import AuthenticationServices
import Foundation
import MyTermCore
import MyTermRemote
import XCTest

@testable import MyTerm

@MainActor
final class CompanionSignInRecoveryTests: XCTestCase {
    private var directories: [URL] = []
    private var suites: [String] = []
    private var hosts: [CompanionHostModel] = []

    override func tearDown() async throws {
        hosts.forEach { $0.cancelSignIn(); $0.disconnect() }
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
        for directory in directories { try FileManager.default.removeItem(at: directory) }
    }

    func testLinkedRelayStartsDisconnectedUntilCredentialsAreChecked() async throws {
        let fixture = try fixture()
        try await fixture.host.installAuthenticatedSessionForTesting(fixture.record)
        let restored = CompanionHostModel(appModel: fixture.app, channel: .development,
            storageNamespace: "recovery", secrets: fixture.secrets,
            authenticationSession: fixture.authentication, defaults: fixture.defaults)
        hosts.append(restored)
        XCTAssertTrue(restored.hasLinkedRelay)
        XCTAssertEqual(restored.status, .disconnected)
        XCTAssertFalse(restored.needsSignIn)
    }

    func testStartupWithMissingCredentialsExplainsSignInWithoutOpeningBrowser() async throws {
        let fixture = try fixture()
        try await fixture.host.installAuthenticatedSessionForTesting(fixture.record)
        try await TokenStore(secrets: fixture.secrets).remove(partition: fixture.partition)

        fixture.host.startIfEnabled()
        try await wait { fixture.host.status == .signInRequired(.credentialsUnavailable) }

        XCTAssertTrue(fixture.host.hasLinkedRelay)
        XCTAssertTrue(fixture.host.needsSignIn)
        XCTAssertEqual(fixture.app.errorDescription, CompanionSignInRequirement.credentialsUnavailable.message)
        XCTAssertEqual(fixture.browserStarts.count, 0)
        XCTAssertEqual(fixture.sleeps.count, 0, "Missing credentials must not enter a reconnect loop")

        let restored = CompanionHostModel(appModel: fixture.app, channel: .development,
            storageNamespace: "recovery", secrets: fixture.secrets,
            authenticationSession: fixture.authentication, defaults: fixture.defaults)
        hosts.append(restored)
        restored.startIfEnabled()
        try await wait { restored.status == .signInRequired(.credentialsUnavailable) }
        XCTAssertEqual(fixture.browserStarts.count, 0)

        fixture.host.connect()
        try await wait { fixture.browserStarts.count == 1 }
        XCTAssertEqual(fixture.browserStarts.urls.first?.path, "/auth/login")
    }

    func testManualReconnectWithMissingCredentialsStartsExistingPasskeySignIn() async throws {
        let fixture = try fixture()
        try await fixture.host.installAuthenticatedSessionForTesting(fixture.record)
        try await TokenStore(secrets: fixture.secrets).remove(partition: fixture.partition)

        fixture.host.connect()
        try await wait { fixture.browserStarts.count == 1 }

        XCTAssertEqual(fixture.browserStarts.urls.first?.host, "relay.example.test")
        XCTAssertEqual(fixture.browserStarts.urls.first?.path, "/auth/login")
        XCTAssertTrue(fixture.host.hasLinkedRelay, "Sign-in must retain the linked relay")
        XCTAssertEqual(fixture.sleeps.count, 0)
    }

    func testCorruptAuthReferenceExplainsSignInAndStopsRetries() async throws {
        let fixture = try fixture()
        try await fixture.host.installAuthenticatedSessionForTesting(fixture.record)
        fixture.defaults.set(Data("invalid reference".utf8),
            forKey: "\(MyTermChannel.development.bundleIdentifier).companion.recovery.auth-reference")

        fixture.host.startIfEnabled()
        try await wait { fixture.host.status == .signInRequired(.credentialsUnavailable) }

        XCTAssertEqual(fixture.sleeps.count, 0)
        XCTAssertEqual(fixture.browserStarts.count, 0)
        XCTAssertEqual(fixture.app.errorDescription, CompanionSignInRequirement.credentialsUnavailable.message)
        fixture.host.connect()
        try await wait { fixture.browserStarts.count == 1 }
    }

    func testRejectedUnexpiredAccessTokenOffersSignInWithoutRetrying() async throws {
        let fixture = try fixture()
        try await fixture.host.installAuthenticatedSessionForTesting(fixture.record)

        fixture.host.startIfEnabled()
        try await wait { fixture.host.status == .signInRequired(.authorizationRejected) }

        XCTAssertEqual(fixture.sleeps.count, 0)
        XCTAssertEqual(fixture.browserStarts.count, 0)
        let saved = try await TokenStore(secrets: fixture.secrets).load(partition: fixture.partition)
        XCTAssertEqual(saved, fixture.record)
        fixture.host.connect()
        try await wait { fixture.browserStarts.count == 1 }
    }

    func testRejectedRefreshExplainsExpiredOrRevokedSignInAndStopsRetries() async throws {
        let fixture = try fixture(expiry: .distantPast)
        try await fixture.host.installAuthenticatedSessionForTesting(fixture.record)

        fixture.host.startIfEnabled()
        try await wait { fixture.host.status == .signInRequired(.authorizationRejected) }

        XCTAssertEqual(fixture.app.errorDescription, CompanionSignInRequirement.authorizationRejected.message)
        XCTAssertTrue(fixture.host.needsSignIn)
        XCTAssertEqual(fixture.browserStarts.count, 0, "Background failures must not open a browser")
        XCTAssertEqual(fixture.sleeps.count, 0)
        let remaining = try await TokenStore(secrets: fixture.secrets).load(partition: fixture.partition)
        XCTAssertNil(remaining)

        fixture.host.connect()
        try await wait { fixture.browserStarts.count == 1 }
        XCTAssertEqual(fixture.browserStarts.urls.first?.path, "/auth/login")
    }

    func testCancellingSignInRetainsRecoveryActionAndStartupPreference() async throws {
        let fixture = try fixture(browserCanStart: true)
        try await fixture.host.installAuthenticatedSessionForTesting(fixture.record)
        try await TokenStore(secrets: fixture.secrets).remove(partition: fixture.partition)
        fixture.host.startIfEnabled()
        try await wait { fixture.host.needsSignIn }
        fixture.host.connect()
        try await wait { fixture.browserStarts.count == 1 }
        XCTAssertTrue(fixture.host.isSigningIn)

        fixture.host.cancelSignIn()
        XCTAssertEqual(fixture.host.status, .signInRequired(.credentialsUnavailable))
        XCTAssertTrue(fixture.host.needsSignIn)

        let restored = CompanionHostModel(appModel: fixture.app, channel: .development,
            storageNamespace: "recovery", secrets: fixture.secrets,
            authenticationSession: fixture.authentication, defaults: fixture.defaults)
        hosts.append(restored)
        restored.startIfEnabled()
        try await wait { restored.needsSignIn }
        XCTAssertEqual(fixture.browserStarts.count, 1)
    }

    func testFailedSignInRetainsRecoveryActionAndStartupPreference() async throws {
        let fixture = try fixture()
        try await fixture.host.installAuthenticatedSessionForTesting(fixture.record)
        try await TokenStore(secrets: fixture.secrets).remove(partition: fixture.partition)
        fixture.host.connect()
        try await wait { fixture.browserStarts.count == 1 && !fixture.host.isSigningIn }
        XCTAssertEqual(fixture.host.status, .signInRequired(.credentialsUnavailable))
        XCTAssertNotNil(fixture.app.errorDescription)

        let restored = CompanionHostModel(appModel: fixture.app, channel: .development,
            storageNamespace: "recovery", secrets: fixture.secrets,
            authenticationSession: fixture.authentication, defaults: fixture.defaults)
        hosts.append(restored)
        restored.startIfEnabled()
        try await wait { restored.needsSignIn }
    }

    func testHostRegistrationAuthorizationErrorDoesNotDiscardValidCredentials() async throws {
        let fixture = try fixture(forbiddenHost: true)
        try await fixture.host.installAuthenticatedSessionForTesting(fixture.record)
        fixture.host.startIfEnabled()
        try await wait { fixture.sleeps.count == 1 }
        guard case .failed = fixture.host.status else { return XCTFail("Expected a retryable connection failure") }
        XCTAssertFalse(fixture.host.needsSignIn)
        XCTAssertNil(fixture.app.errorDescription)
        let saved = try await TokenStore(secrets: fixture.secrets).load(partition: fixture.partition)
        XCTAssertEqual(saved, fixture.record)
        XCTAssertEqual(fixture.browserStarts.count, 0)
    }

    private func wait(until predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The expected authentication transition did not occur")
        throw URLError(.timedOut)
    }

    private struct Fixture {
        let app: AppModel
        let host: CompanionHostModel
        let secrets: RecoveryMemorySecrets
        let defaults: UserDefaults
        let record: TokenRecord
        let authentication: CompanionAuthenticationSession
        let browserStarts: BrowserStarts
        let sleeps: RecoverySleepRecorder
        var partition: TokenPartition {
            TokenPartition(relay: record.relay, accountID: record.accountID, deviceID: record.deviceID)
        }
    }

    private func fixture(expiry: Date = .distantFuture, browserCanStart: Bool = false, forbiddenHost: Bool = false) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appending(path: "myterm-signin-recovery-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let suite = "myterm-signin-recovery-\(UUID())"
        suites.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let app = try AppModel(channel: .development, applicationSupportDirectory: directory,
            terminalEngine: nil, startsTerminalProcesses: false)
        let secrets = RecoveryMemorySecrets()
        let browserStarts = BrowserStarts()
        let authentication = CompanionAuthenticationSession { url, _, _ in
            browserStarts.urls.append(url)
            return TestBrowserSession(canStart: browserCanStart)
        }
        let sleeps = RecoverySleepRecorder()
        let host = CompanionHostModel(appModel: app, channel: .development, storageNamespace: "recovery",
            sleep: { _ in sleeps.record(); throw CancellationError() },
            secrets: secrets, authenticationSession: authentication, defaults: defaults,
            makeHTTPClient: { endpoint in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = forbiddenHost ? [ForbiddenHostProtocol.self] : [RejectedRefreshProtocol.self]
                return RelayHTTPClient(endpoint: endpoint, session: URLSession(configuration: configuration))
            })
        hosts.append(host)
        let relay = try RelayEndpoint(XCTUnwrap(URL(string: "https://relay.example.test")))
        let record = TokenRecord(relay: relay, accountID: UUID(), deviceID: UUID(),
            accessToken: "test-access", refreshToken: "test-refresh", expiresAt: expiry)
        return Fixture(app: app, host: host, secrets: secrets, defaults: defaults, record: record,
            authentication: authentication, browserStarts: browserStarts, sleeps: sleeps)
    }

    private final class BrowserStarts {
        var urls: [URL] = []
        var count: Int { urls.count }
    }

    private final class TestBrowserSession: CompanionBrowserSession {
        weak var presentationContextProvider: (any ASWebAuthenticationPresentationContextProviding)?
        var prefersEphemeralWebBrowserSession = false
        let canStart: Bool
        init(canStart: Bool) { self.canStart = canStart }
        func start() -> Bool { canStart }
        func cancel() {}
    }
}

private final class RecoveryMemorySecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(account: String) throws -> Data? { lock.withLock { values[account] } }
    func write(_ data: Data, account: String) throws { lock.withLock { values[account] = data } }
    func delete(account: String) throws { _ = lock.withLock { values.removeValue(forKey: account) } }
}

private final class RecoverySleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.withLock { calls } }
    func record() { lock.withLock { calls += 1 } }
}

private class RejectedRefreshProtocol: URLProtocol, @unchecked Sendable {
    class var responseStatus: Int { 401 }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: Self.responseStatus, httpVersion: nil,
                                             headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"error":"invalid_grant"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class ForbiddenHostProtocol: RejectedRefreshProtocol, @unchecked Sendable {
    override class var responseStatus: Int { 403 }
}
