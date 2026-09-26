import Foundation

public struct TokenRecord: Codable, Equatable, Sendable {
    public let relay: RelayEndpoint
    public let accountID: UUID
    public let deviceID: UUID
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date

    public init(relay: RelayEndpoint, accountID: UUID, deviceID: UUID,
                accessToken: String, refreshToken: String, expiresAt: Date) {
        self.relay = relay
        self.accountID = accountID
        self.deviceID = deviceID
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

public struct RelayHost: Codable, Equatable, Identifiable, Sendable {
    public let hostID: UUID
    public let name: String
    public let publicKey: String
    public let transportOnline: Bool
    public var id: UUID { hostID }

    enum CodingKeys: String, CodingKey {
        case hostID = "host_id"
        case name
        case publicKey = "public_key"
        case transportOnline = "transport_online"
    }
}

public struct RelayDevice: Codable, Equatable, Identifiable, Sendable {
    public let deviceID: UUID
    public let kind: RelayRole
    public let name: String
    public let createdAt: Date
    public let revokedAt: Date?
    public var id: UUID { deviceID }

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case kind, name
        case createdAt = "created_at"
        case revokedAt = "revoked_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceID = try container.decode(UUID.self, forKey: .deviceID)
        kind = try container.decode(RelayRole.self, forKey: .kind)
        name = try container.decode(String.self, forKey: .name)
        createdAt = Date(timeIntervalSince1970: TimeInterval(try container.decode(Int64.self,
                                                                                 forKey: .createdAt)))
        if let value = try container.decodeIfPresent(Int64.self, forKey: .revokedAt) {
            revokedAt = Date(timeIntervalSince1970: TimeInterval(value))
        } else {
            revokedAt = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(deviceID, forKey: .deviceID)
        try container.encode(kind, forKey: .kind)
        try container.encode(name, forKey: .name)
        try container.encode(Int64(createdAt.timeIntervalSince1970), forKey: .createdAt)
        try container.encodeIfPresent(revokedAt.map { Int64($0.timeIntervalSince1970) },
                                      forKey: .revokedAt)
    }
}

public final class RelayHTTPClient: @unchecked Sendable {
    public let endpoint: RelayEndpoint
    public let timeout: TimeInterval
    private let session: URLSession

    public init(endpoint: RelayEndpoint, timeout: TimeInterval = 15) {
        self.endpoint = endpoint
        self.timeout = timeout
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        session = URLSession(configuration: configuration,
                             delegate: RelaySessionDelegate(endpoint: endpoint),
                             delegateQueue: nil)
    }

    /// Uses a caller-owned session for environments with a private trust root. The caller must
    /// enforce the same-origin redirect and credential-storage policy used by the default session.
    public init(endpoint: RelayEndpoint, timeout: TimeInterval = 15, session: URLSession) {
        self.endpoint = endpoint
        self.timeout = timeout
        self.session = session
    }

    public func exchangeAuthorizationCode(code: String, verifier: String,
                                          redirectURI: URL) async throws -> TokenPayload {
        try await post(path: "v1/oauth/token", bearer: nil,
                       body: TokenRequest(grantType: "authorization_code", code: code,
                                          codeVerifier: verifier,
                                          redirectURI: redirectURI.absoluteString,
                                          refreshToken: nil))
    }

    public func refresh(refreshToken: String) async throws -> TokenPayload {
        try await post(path: "v1/oauth/token", bearer: nil,
                       body: TokenRequest(grantType: "refresh_token", code: nil,
                                          codeVerifier: nil, redirectURI: nil,
                                          refreshToken: refreshToken))
    }

    public func revoke(token: String) async throws {
        let _: EmptyResponse = try await post(path: "v1/oauth/revoke", bearer: nil,
                                              body: RevokeRequest(token: token),
                                              permitsEmptyResponse: true)
    }

    public func registerHost(hostID: UUID, name: String, publicKey: Data,
                             bearer: String) async throws -> RelayHost {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty, normalizedName.utf8.count <= 100,
              publicKey.count == 65 else {
            throw RemoteError.invalidMessage
        }
        let response: HostResponse = try await send(
            method: "PUT", path: "v1/hosts/\(hostID.uuidString.lowercased())", bearer: bearer,
            body: HostRegistrationRequest(name: normalizedName, publicKey: publicKey.base64URL)
        )
        return response.host
    }

    public func hosts(bearer: String) async throws -> [RelayHost] {
        let response: HostsResponse = try await send(method: "GET", path: "v1/hosts",
                                                     bearer: bearer, body: Optional<String>.none)
        return response.hosts
    }

    public func removeHost(hostID: UUID, bearer: String) async throws {
        let _: EmptyResponse = try await send(method: "DELETE",
                                              path: "v1/hosts/\(hostID.uuidString.lowercased())",
                                              bearer: bearer, body: Optional<String>.none,
                                              permitsEmptyResponse: true)
    }

    public func devices(bearer: String) async throws -> [RelayDevice] {
        let response: DevicesResponse = try await send(method: "GET", path: "v1/devices",
                                                       bearer: bearer, body: Optional<String>.none)
        return response.devices
    }

    public func revokeDevice(deviceID: UUID, bearer: String) async throws {
        let _: EmptyResponse = try await send(method: "DELETE",
                                              path: "v1/devices/\(deviceID.uuidString.lowercased())",
                                              bearer: bearer, body: Optional<String>.none,
                                              permitsEmptyResponse: true)
    }

    public func disconnectPeer(hostID: UUID, connectionID: UUID, bearer: String) async throws {
        let _: EmptyResponse = try await send(
            method: "DELETE",
            path: "v1/hosts/\(hostID.uuidString.lowercased())/connections/\(connectionID.uuidString.lowercased())",
            bearer: bearer, body: Optional<String>.none, permitsEmptyResponse: true
        )
    }

    private func post<Body: Encodable, Response: Decodable>(path: String, bearer: String?,
                                                             body: Body,
                                                             permitsEmptyResponse: Bool = false) async throws -> Response {
        try await send(method: "POST", path: path, bearer: bearer, body: body,
                       permitsEmptyResponse: permitsEmptyResponse)
    }

    private func send<Body: Encodable, Response: Decodable>(method: String, path: String,
                                                             bearer: String?, body: Body,
                                                             permitsEmptyResponse: Bool = false) async throws -> Response {
        let url = endpoint.appending(path: path)
        guard endpoint.hasSameOrigin(as: url) else { throw RemoteError.invalidEndpoint }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer {
            guard !bearer.isEmpty, !bearer.contains(where: { $0.isNewline }) else {
                throw RemoteError.authenticationRequired
            }
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        if method != "GET" && method != "DELETE" {
            let encoder = JSONEncoder()
            request.httpBody = try encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw Self.classify(error) }
        guard let http = response as? HTTPURLResponse,
              endpoint.hasSameOrigin(as: http.url ?? url) else { throw RemoteError.unsafeRedirect }
        switch http.statusCode {
        case 200..<300: break
        case 300..<400: throw RemoteError.unsafeRedirect
        case 401, 403: throw RemoteError.authenticationRequired
        default: throw RemoteError.server(status: http.statusCode)
        }
        guard data.count <= 2 * 1_024 * 1_024 else { throw RemoteError.messageTooLarge }
        if data.isEmpty && permitsEmptyResponse, let empty = EmptyResponse() as? Response { return empty }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Response.self, from: data)
        } catch { throw RemoteError.invalidResponse }
    }

    static func classify(_ error: Error) -> RemoteError {
        guard let error = error as? URLError else { return .offline }
        switch error.code {
        case .timedOut: return .timedOut
        case .cancelled: return .disconnected
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .internationalRoamingOff,
             .dataNotAllowed: return .offline
        default: return .offline
        }
    }
}

private final class RelaySessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let endpoint: RelayEndpoint
    init(endpoint: RelayEndpoint) { self.endpoint = endpoint }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, endpoint.hasSameOrigin(as: url) else {
            completionHandler(nil)
            return
        }
        var request = request
        if let authorization = task.originalRequest?.value(forHTTPHeaderField: "Authorization") {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        completionHandler(request)
    }
}

public struct TokenPayload: Codable, Equatable, Sendable {
    public let accessToken: String
    public let tokenType: String
    public let expiresIn: Int
    public let refreshToken: String
    public let deviceID: UUID
    public let accountID: UUID

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case deviceID = "device_id"
        case accountID = "account_id"
    }

    public func record(relay: RelayEndpoint, now: Date = .now) throws -> TokenRecord {
        guard tokenType.caseInsensitiveCompare("Bearer") == .orderedSame,
              !accessToken.isEmpty, !refreshToken.isEmpty, (1...86_400).contains(expiresIn) else {
            throw RemoteError.invalidResponse
        }
        return TokenRecord(relay: relay, accountID: accountID, deviceID: deviceID,
                           accessToken: accessToken, refreshToken: refreshToken,
                           expiresAt: now.addingTimeInterval(TimeInterval(expiresIn)))
    }
}

public actor RelayAuthenticator {
    private let client: RelayHTTPClient
    private let store: TokenStore

    public init(client: RelayHTTPClient, store: TokenStore) {
        self.client = client
        self.store = store
    }

    public func exchange(attempt: SignInAttempt, callback: URL,
                         now: Date = .now) async throws -> TokenRecord {
        guard attempt.relay == client.endpoint else { throw RemoteError.invalidEndpoint }
        let code = try attempt.authorizationCode(from: callback)
        let payload = try await client.exchangeAuthorizationCode(code: code,
                                                                 verifier: attempt.verifier,
                                                                 redirectURI: attempt.redirectURI)
        let record = try payload.record(relay: client.endpoint, now: now)
        try await store.save(record)
        return record
    }
}

public actor RelayTokenManager {
    private let client: RelayHTTPClient
    private let store: TokenStore
    private var record: TokenRecord
    private var refreshTask: Task<TokenRecord, Error>?

    public init(client: RelayHTTPClient, store: TokenStore, record: TokenRecord) throws {
        guard client.endpoint == record.relay else { throw RemoteError.invalidEndpoint }
        self.client = client
        self.store = store
        self.record = record
    }

    /// Renewed well before expiry rather than at the last minute: a token with seconds left is
    /// enough to open a connection the relay then closes almost immediately.
    public static let refreshMargin: TimeInterval = 5 * 60

    public func accessToken(now: Date = .now) async throws -> String {
        if record.expiresAt.timeIntervalSince(now) > Self.refreshMargin { return record.accessToken }
        return try await refresh(now: now).accessToken
    }

    /// When the current token runs out, for callers that re-present it on a live connection.
    public func accessExpiry() -> Date { record.expiresAt }

    @discardableResult
    public func refresh(now: Date = .now) async throws -> TokenRecord {
        if let refreshTask { return try await refreshTask.value }
        let old = record
        let client = client
        let task = Task<TokenRecord, Error> {
            let payload = try await client.refresh(refreshToken: old.refreshToken)
            guard payload.deviceID == old.deviceID, payload.accountID == old.accountID else {
                throw RemoteError.wrongPeer
            }
            return try payload.record(relay: old.relay, now: now)
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let refreshed = try await task.value
            try await store.save(refreshed)
            record = refreshed
            return refreshed
        } catch RemoteError.authenticationRequired {
            try? await store.remove(partition: TokenPartition(relay: old.relay,
                                                              accountID: old.accountID,
                                                              deviceID: old.deviceID))
            throw RemoteError.authenticationRevoked
        }
    }

    public func revoke() async throws {
        let old = record
        try await client.revoke(token: old.refreshToken)
        try await store.remove(partition: TokenPartition(relay: old.relay,
                                                         accountID: old.accountID,
                                                         deviceID: old.deviceID))
    }
}

private struct TokenRequest: Encodable {
    let grantType: String
    let code: String?
    let codeVerifier: String?
    let redirectURI: String?
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case grantType = "grant_type"
        case code
        case codeVerifier = "code_verifier"
        case redirectURI = "redirect_uri"
        case refreshToken = "refresh_token"
    }
}
private struct RevokeRequest: Encodable { let token: String }
private struct HostRegistrationRequest: Encodable {
    let name: String
    let publicKey: String
    enum CodingKeys: String, CodingKey { case name; case publicKey = "public_key" }
}
private struct HostResponse: Decodable { let host: RelayHost }
private struct HostsResponse: Decodable { let hosts: [RelayHost] }
private struct DevicesResponse: Decodable { let devices: [RelayDevice] }
private struct EmptyResponse: Codable { init() {} }
