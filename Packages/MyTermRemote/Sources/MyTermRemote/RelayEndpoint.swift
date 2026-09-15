import Foundation

public enum RemoteError: Error, LocalizedError, Equatable, Sendable {
    case invalidEndpoint
    case invalidMessage
    case unsupportedVersion
    case messageTooLarge
    case wrongPeer
    case replayedMessage
    case sequenceExhausted
    case expiredPairing
    case unknownPairing
    case invalidCallback
    case authenticationRequired
    case authenticationRevoked
    case disconnected
    case offline
    case timedOut
    case unsafeRedirect
    case invalidResponse
    case checkpointIncomplete
    case checkpointExpired
    case controlDenied
    case server(status: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Enter an HTTPS relay address without credentials, a path, or a query."
        case .invalidMessage: "The remote message is invalid."
        case .unsupportedVersion: "This connection requires a compatible myterm version."
        case .messageTooLarge: "The remote message exceeds the supported size."
        case .wrongPeer: "The remote identity does not match the paired device."
        case .replayedMessage: "An expired or repeated remote message was rejected."
        case .sequenceExhausted: "Reconnect to establish a new secure session."
        case .expiredPairing: "This pairing code has expired. Enable Pair Mode on the Mac again."
        case .unknownPairing: "This pairing code is invalid or has already been used."
        case .invalidCallback: "The sign-in response does not match this sign-in attempt."
        case .authenticationRequired: "Sign in to this relay again."
        case .authenticationRevoked: "This device's sign-in has been revoked. Sign in again."
        case .disconnected: "The host is not connected."
        case .offline: "The relay could not be reached."
        case .timedOut: "The relay did not respond in time."
        case .unsafeRedirect: "The relay attempted to redirect credentials to another origin."
        case .invalidResponse: "The relay returned an invalid response."
        case .checkpointIncomplete: "The terminal checkpoint is incomplete."
        case .checkpointExpired: "The terminal checkpoint transfer expired."
        case .controlDenied: "Another device currently controls this terminal."
        case .server(let status): "The relay returned an error (HTTP \(status))."
        }
    }
}

public struct RelayEndpoint: Hashable, Codable, Sendable {
    public let url: URL

    public init(_ url: URL) throws {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              parts.port.map({ (1...65535).contains($0) }) ?? true else {
            throw RemoteError.invalidEndpoint
        }
        parts.scheme = "https"
        parts.host = host.lowercased()
        parts.path = ""
        if parts.port == 443 { parts.port = nil }
        guard let normalized = parts.url else { throw RemoteError.invalidEndpoint }
        self.url = normalized
    }

    public func appending(path: String) -> URL {
        url.appendingPathComponent(path)
    }

    public var canonicalOrigin: String { url.absoluteString }

    public func hasSameOrigin(as candidate: URL) -> Bool {
        guard let lhs = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let rhs = URLComponents(url: candidate, resolvingAgainstBaseURL: false) else { return false }
        return lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && (lhs.port ?? 443) == (rhs.port ?? 443)
    }

    public func hasSameSecureAuthority(as candidate: URL) -> Bool {
        guard let lhs = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let rhs = URLComponents(url: candidate, resolvingAgainstBaseURL: false),
              ["https", "wss"].contains(rhs.scheme?.lowercased() ?? "") else { return false }
        return lhs.host?.lowercased() == rhs.host?.lowercased()
            && (lhs.port ?? 443) == (rhs.port ?? 443)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(URL.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(url)
    }
}

extension Data {
    public var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public init?(base64URL: String) {
        guard base64URL.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0)
                || (48...57).contains($0) || $0 == 45 || $0 == 95
        }), base64URL.count % 4 != 1 else { return nil }
        let value = base64URL.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        self.init(base64Encoded: value + String(repeating: "=", count: (4 - value.count % 4) % 4))
    }
}
