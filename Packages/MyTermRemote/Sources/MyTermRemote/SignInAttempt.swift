import CryptoKit
import Foundation

public enum AuthorizationCallbackValidationFailure: String, Equatable, Sendable {
    case tooLarge = "too_large"
    case malformedURL = "malformed_url"
    case redirectMismatch = "redirect_mismatch"
    case unexpectedAuthority = "unexpected_authority"
    case fragmentPresent = "fragment_present"
    case missingQuery = "missing_query"
    case errorResponse = "error_response"
    case invalidStateCount = "invalid_state_count"
    case invalidCodeCount = "invalid_code_count"
    case stateMismatch = "state_mismatch"
    case invalidCode = "invalid_code"
}

public struct SignInAttempt: Sendable {
    public let state: String
    public let verifier: String
    public let redirectURI: URL
    public let relay: RelayEndpoint

    public init(relay: RelayEndpoint, redirectURI: URL) throws {
        guard ["myterm-companion://auth/callback", "myterm-companion-dev://auth/callback", "myterm://companion-auth/callback",
               "myterm-dev://companion-auth/callback"].contains(redirectURI.absoluteString) else {
            throw RemoteError.invalidCallback
        }
        self.relay = relay
        self.redirectURI = redirectURI
        state = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64URL }
        verifier = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64URL }
    }

    public static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
    }

    public func loginURL(deviceName: String, deviceKind: String) throws -> URL {
        try authenticationURL(path: "auth/login", bootstrapToken: nil,
                              deviceName: deviceName, deviceKind: deviceKind)
    }

    public func registrationURL(bootstrapToken: String, deviceName: String,
                                deviceKind: String) throws -> URL {
        guard !bootstrapToken.isEmpty, bootstrapToken.utf8.count <= 2_048 else {
            throw RemoteError.invalidMessage
        }
        return try authenticationURL(path: "auth/register", bootstrapToken: bootstrapToken,
                                     deviceName: deviceName, deviceKind: deviceKind)
    }

    private func authenticationURL(path: String, bootstrapToken: String?, deviceName: String,
                                   deviceKind: String) throws -> URL {
        guard ["host", "client"].contains(deviceKind), deviceName.utf8.count <= 256,
              var components = URLComponents(url: relay.appending(path: path),
                                             resolvingAgainstBaseURL: false) else {
            throw RemoteError.invalidMessage
        }
        components.queryItems = [
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: Self.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "device_name", value: deviceName),
            URLQueryItem(name: "device_kind", value: deviceKind),
        ]
        if let bootstrapToken {
            var fragment = URLComponents()
            fragment.queryItems = [URLQueryItem(name: "bootstrap_token", value: bootstrapToken)]
            components.percentEncodedFragment = fragment.percentEncodedQuery
        }
        guard let url = components.url else { throw RemoteError.invalidEndpoint }
        return url
    }

    public func authorizationCode(from callback: URL) throws -> String {
        guard callbackValidationFailure(from: callback) == nil,
              let items = URLComponents(url: callback,
                                        resolvingAgainstBaseURL: false)?.queryItems,
              let code = items.first(where: { $0.name == "code" })?.value else {
            throw RemoteError.invalidCallback
        }
        return code
    }

    public func callbackValidationFailure(
        from callback: URL
    ) -> AuthorizationCallbackValidationFailure? {
        guard callback.absoluteString.utf8.count <= 8_192 else { return .tooLarge }
        guard let components = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              let expected = URLComponents(url: redirectURI,
                                           resolvingAgainstBaseURL: false) else {
            return .malformedURL
        }
        guard components.scheme == expected.scheme,
              components.host == expected.host,
              components.path == expected.path else { return .redirectMismatch }
        guard components.port == nil, components.user == nil,
              components.password == nil else { return .unexpectedAuthority }
        guard components.fragment == nil else { return .fragmentPresent }
        guard let items = components.queryItems else { return .missingQuery }
        guard !items.contains(where: { $0.name == "error" }) else { return .errorResponse }
        guard items.filter({ $0.name == "state" }).count == 1 else {
            return .invalidStateCount
        }
        guard items.filter({ $0.name == "code" }).count == 1 else {
            return .invalidCodeCount
        }
        guard items.first(where: { $0.name == "state" })?.value == state else {
            return .stateMismatch
        }
        guard let code = items.first(where: { $0.name == "code" })?.value,
              !code.isEmpty, code.utf8.count <= 1_024 else { return .invalidCode }
        return nil
    }
}
