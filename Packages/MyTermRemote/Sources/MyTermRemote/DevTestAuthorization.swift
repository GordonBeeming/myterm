import Foundation

public enum DevTestAuthorizationError: String, Error, LocalizedError, Sendable {
    case unsupportedBuild, invalidOrigin, invalidConfiguration

    public var errorDescription: String? {
        switch self {
        case .unsupportedBuild: "Development test authentication is available only in a Debug iOS Simulator build."
        case .invalidOrigin: "Development test authentication requires an approved development relay origin."
        case .invalidConfiguration: "Development test authentication requires explicit opt-in and a valid test credential."
        }
    }
}

#if DEBUG
/// Test-only capability: no environment lookup or network entry point is compiled into Release.
public struct DevTestAuthorizationConfiguration: Sendable {
    public let relay: RelayEndpoint
    let bearer: String
    private init(relay: RelayEndpoint, bearer: String) { self.relay = relay; self.bearer = bearer }

    public static func resolve(environment: [String: String], supportedBuild: Bool,
                               relay: RelayEndpoint, redirectURI: URL) throws -> Self? {
        guard let flag = environment["MYTERM_DEV_TEST_AUTH_ENABLED"], flag != "0" else { return nil }
        guard flag == "1" else { throw DevTestAuthorizationError.invalidConfiguration }
        guard supportedBuild else { throw DevTestAuthorizationError.unsupportedBuild }
        // Validate the destination before even reading the test credential from the environment.
        let host = relay.url.host?.lowercased() ?? ""
        let approvedRemote = relay.canonicalOrigin == "https://myterm-relay-dev.gordonbeeming.dev"
        let approvedLocal = host == "localhost" || (host.hasSuffix(".localhost") && host != ".localhost")
        guard approvedRemote || approvedLocal else { throw DevTestAuthorizationError.invalidOrigin }
        guard redirectURI.absoluteString == "myterm-companion-dev://auth/callback",
              let token = environment["MYTERM_DEV_TEST_AUTH_TOKEN"], token.utf8.count <= 683,
              token.unicodeScalars.allSatisfy({
                  (65...90).contains($0.value) || (97...122).contains($0.value)
                    || (48...57).contains($0.value) || $0 == "-" || $0 == "_"
              }),
              let decoded = Data(base64URL: token), (32...512).contains(decoded.count),
              decoded.base64URL == token else { throw DevTestAuthorizationError.invalidConfiguration }
        return Self(relay: relay, bearer: token)
    }
}

struct DevTestAuthorizationRequest: Encodable {
    let redirectURI: String
    let state: String
    let codeChallenge: String
    let codeChallengeMethod = "S256"
    let deviceName: String
    let deviceKind = "client"
    enum CodingKeys: String, CodingKey {
        case redirectURI = "redirect_uri", state, codeChallenge = "code_challenge"
        case codeChallengeMethod = "code_challenge_method", deviceName = "device_name", deviceKind = "device_kind"
    }
}

struct DevTestAuthorizationResponse: Decodable {
    let code: String
    let state: String
}
#endif
