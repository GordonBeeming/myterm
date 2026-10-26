#if DEBUG
import Foundation
import XCTest
@testable import MyTermRemote

private final class DevAuthorizationURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?
    nonisolated(unsafe) static var redirectTarget: URL?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            if status == 302, let target = Self.redirectTarget {
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target),
                    redirectResponse: HTTPURLResponse(url: request.url!, statusCode: 302,
                        httpVersion: nil, headerFields: ["Location": target.absoluteString])!)
            }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private final class DevAuthorizationMemorySecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: [String: Data] = [:]
    func read(account: String) throws -> Data? { lock.withLock { data[account] } }
    func write(_ value: Data, account: String) throws { lock.withLock { data[account] = value } }
    func delete(account: String) throws { _ = lock.withLock { data.removeValue(forKey: account) } }
}

@MainActor
final class DevTestAuthorizationTests: XCTestCase {
    private let redirect = URL(string: "myterm-companion-dev://auth/callback")!
    // Deliberately public fixture data, never a live credential.
    private var token: String { Data(repeating: 66, count: 32).base64URL }
    private var environment: [String: String] {
        ["MYTERM_DEV_TEST_AUTH_ENABLED": "1", "MYTERM_DEV_TEST_AUTH_TOKEN": token]
    }
    private func relay(_ value: String = "https://test.localhost:8443") throws -> RelayEndpoint {
        try RelayEndpoint(URL(string: value)!)
    }
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DevAuthorizationURLProtocol.self]
        return URLSession(configuration: configuration)
    }
    private func body(_ request: URLRequest) throws -> [String: String] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1_024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try JSONDecoder().decode([String: String].self, from: data)
    }

    func testDefaultDisabledAndUnsupportedBuildOrOriginFailClosed() throws {
        let endpoint = try relay()
        XCTAssertNil(try DevTestAuthorizationConfiguration.resolve(environment: [:], supportedBuild: true,
                                                                   relay: endpoint, redirectURI: redirect))
        XCTAssertNil(try DevTestAuthorizationConfiguration.resolve(environment: ["MYTERM_DEV_TEST_AUTH_ENABLED": "0"],
            supportedBuild: true, relay: endpoint, redirectURI: redirect))
        XCTAssertThrowsError(try DevTestAuthorizationConfiguration.resolve(environment: environment,
            supportedBuild: false, relay: endpoint, redirectURI: redirect))
        for origin in ["https://myterm-relay.gordonbeeming.dev", "https://evil.example", "https://myterm-relay-dev.gordonbeeming.dev:8443"] {
            XCTAssertThrowsError(try DevTestAuthorizationConfiguration.resolve(environment: environment,
                supportedBuild: true, relay: relay(origin), redirectURI: redirect))
        }
        XCTAssertThrowsError(try DevTestAuthorizationConfiguration.resolve(environment: environment,
            supportedBuild: true, relay: endpoint, redirectURI: URL(string: "myterm-companion://auth/callback")!))
        for origin in ["https://myterm-relay-dev.gordonbeeming.dev", "https://localhost:8443"] {
            XCTAssertNotNil(try DevTestAuthorizationConfiguration.resolve(environment: environment,
                supportedBuild: true, relay: relay(origin), redirectURI: redirect))
        }
    }

    func testInvalidOptInAndMissingWeakOrMalformedSecretsAreRejectedWithoutEchoingThem() throws {
        for env in [["MYTERM_DEV_TEST_AUTH_ENABLED": "yes"], ["MYTERM_DEV_TEST_AUTH_ENABLED": "1"],
                    ["MYTERM_DEV_TEST_AUTH_ENABLED": "1", "MYTERM_DEV_TEST_AUTH_TOKEN": "weak\ninvalid"]] {
            XCTAssertThrowsError(try DevTestAuthorizationConfiguration.resolve(environment: env,
                supportedBuild: true, relay: relay(), redirectURI: redirect)) { error in
                XCTAssertEqual(error as? DevTestAuthorizationError, .invalidConfiguration)
                XCTAssertFalse(error.localizedDescription.contains("weak"))
            }
        }
    }

    func testAuthorizationUsesHeaderOnlyThenNormalStateValidationPKCEAndTokenPersistence() async throws {
        let endpoint = try relay()
        let attempt = try SignInAttempt(relay: endpoint, redirectURI: redirect)
        let configuration = try XCTUnwrap(DevTestAuthorizationConfiguration.resolve(environment: environment,
            supportedBuild: true, relay: endpoint, redirectURI: redirect))
        let http = session()
        defer { http.invalidateAndCancel(); DevAuthorizationURLProtocol.handler = nil }
        let client = RelayHTTPClient(endpoint: endpoint, session: http)
        let accountID = UUID(), deviceID = UUID()
        var paths: [String] = []
        DevAuthorizationURLProtocol.handler = { request in
            paths.append(request.url!.path)
            let fields = try self.body(request)
            XCTAssertNil(request.url?.query)
            if request.url?.path == "/v1/dev-test/authorize" {
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + self.token)
                XCTAssertEqual(fields, ["redirect_uri": self.redirect.absoluteString, "state": attempt.state,
                    "code_challenge": SignInAttempt.challenge(for: attempt.verifier), "code_challenge_method": "S256",
                    "device_name": "Simulator", "device_kind": "client"])
                XCTAssertFalse(fields.values.contains(self.token))
                return (200, try JSONSerialization.data(withJSONObject: ["code": "test-code", "state": attempt.state]))
            }
            XCTAssertEqual(request.url?.path, "/v1/oauth/token")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(fields["code"], "test-code")
            XCTAssertEqual(fields["code_verifier"], attempt.verifier)
            return (200, try JSONSerialization.data(withJSONObject: ["access_token": "access-fixture", "token_type": "Bearer",
                "expires_in": 3600, "refresh_token": "refresh-fixture", "device_id": deviceID.uuidString,
                "account_id": accountID.uuidString]))
        }
        let callback = try await client.devTestAuthorizationCallback(configuration: configuration, attempt: attempt,
                                                                     deviceName: "Simulator")
        let store = TokenStore(secrets: DevAuthorizationMemorySecrets())
        let record = try await RelayAuthenticator(client: client, store: store).exchange(attempt: attempt, callback: callback)
        XCTAssertEqual(record.accountID, accountID)
        let saved = try await store.load(partition: TokenPartition(relay: endpoint, accountID: accountID, deviceID: deviceID))
        XCTAssertEqual(saved, record)
        XCTAssertEqual(paths, ["/v1/dev-test/authorize", "/v1/oauth/token"])
    }

    func testWrongStateErrorsAndOversizedResponseNeverProduceCallback() async throws {
        let endpoint = try relay()
        let attempt = try SignInAttempt(relay: endpoint, redirectURI: redirect)
        let configuration = try XCTUnwrap(DevTestAuthorizationConfiguration.resolve(environment: environment,
            supportedBuild: true, relay: endpoint, redirectURI: redirect))
        let http = session()
        defer { http.invalidateAndCancel(); DevAuthorizationURLProtocol.handler = nil }
        let client = RelayHTTPClient(endpoint: endpoint, session: http)
        for (status, payload, expected) in [(200, Data(#"{"code":"code","state":"wrong"}"#.utf8), RemoteError.invalidCallback),
            (401, Data(), .authenticationRequired), (302, Data(), .unsafeRedirect),
            (200, Data(repeating: 32, count: 4097), .messageTooLarge)] {
            DevAuthorizationURLProtocol.handler = { _ in (status, payload) }
            do {
                _ = try await client.devTestAuthorizationCallback(configuration: configuration, attempt: attempt, deviceName: "Simulator")
                XCTFail("Expected rejection")
            } catch { XCTAssertEqual(error as? RemoteError, expected) }
        }
    }

    func testBearerAuthorizationRefusesEvenSameOriginRedirect() throws {
        let endpoint = try relay()
        let http = session()
        defer { http.invalidateAndCancel() }
        let original = URLRequest(url: endpoint.appending(path: "v1/dev-test/authorize"))
        let task = http.dataTask(with: original)
        let response = HTTPURLResponse(url: original.url!, statusCode: 302, httpVersion: nil, headerFields: nil)!
        let delegate = RelaySessionDelegate(endpoint: endpoint)
        var called = false
        delegate.urlSession(http, task: task, willPerformHTTPRedirection: response,
                            newRequest: URLRequest(url: endpoint.appending(path: "other"))) { request in
            called = true
            XCTAssertNil(request)
        }
        XCTAssertTrue(called)
    }
    func testCancelledOrMismatchedAttemptNeverSendsCredential() async throws {
        let endpoint = try relay()
        let attempt = try SignInAttempt(relay: endpoint, redirectURI: redirect)
        let configuration = try XCTUnwrap(DevTestAuthorizationConfiguration.resolve(environment: environment,
            supportedBuild: true, relay: endpoint, redirectURI: redirect))
        let http = session()
        defer { http.invalidateAndCancel(); DevAuthorizationURLProtocol.handler = nil }
        var requests = 0
        DevAuthorizationURLProtocol.handler = { _ in requests += 1; return (500, Data()) }
        let wrongClient = RelayHTTPClient(endpoint: try relay("https://other.localhost"), session: http)
        do {
            _ = try await wrongClient.devTestAuthorizationCallback(configuration: configuration,
                attempt: attempt, deviceName: "Simulator")
            XCTFail("Expected relay mismatch rejection")
        } catch { XCTAssertEqual(error as? DevTestAuthorizationError, .invalidOrigin) }
        let client = RelayHTTPClient(endpoint: endpoint, session: http)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.devTestAuthorizationCallback(configuration: configuration,
                attempt: attempt, deviceName: "Simulator")
        }
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(requests, 0)
    }

    func testInjectedSessionCannotFollowAuthorizeRedirect() async throws {
        let endpoint = try relay()
        let attempt = try SignInAttempt(relay: endpoint, redirectURI: redirect)
        let configuration = try XCTUnwrap(DevTestAuthorizationConfiguration.resolve(environment: environment,
            supportedBuild: true, relay: endpoint, redirectURI: redirect))
        let http = session() // Deliberately has no RelaySessionDelegate.
        defer {
            http.invalidateAndCancel()
            DevAuthorizationURLProtocol.handler = nil
            DevAuthorizationURLProtocol.redirectTarget = nil
        }
        let target = URL(string: "https://unexpected.localhost/stolen")!
        DevAuthorizationURLProtocol.redirectTarget = target
        var destinations: [URL] = []
        DevAuthorizationURLProtocol.handler = { request in
            destinations.append(request.url!)
            if request.url == target { return (500, Data()) }
            return (302, Data())
        }
        let client = RelayHTTPClient(endpoint: endpoint, timeout: 2, session: http)
        do {
            _ = try await client.devTestAuthorizationCallback(configuration: configuration,
                attempt: attempt, deviceName: "Simulator")
            XCTFail("Expected redirect rejection")
        } catch { XCTAssertEqual(error as? RemoteError, .unsafeRedirect) }
        XCTAssertEqual(destinations, [endpoint.appending(path: "v1/dev-test/authorize")])
    }

}
#endif
