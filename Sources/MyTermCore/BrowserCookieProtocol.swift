import Foundation

public enum RemoteBrowserCookieSameSite: String, Codable, Equatable, Hashable, Sendable {
    case none
    case lax
    case strict
}

public enum RemoteBrowserCookieError: Error, Sendable {
    case invalidCookie
    case invalidRequest
    case invalidResponse
}

extension RemoteBrowserCookieSameSite {
    init(_ policy: HTTPCookieStringPolicy?) {
        switch policy {
        case .some(.sameSiteLax): self = .lax
        case .some(.sameSiteStrict): self = .strict
        default: self = .none
        }
    }

    var policy: HTTPCookieStringPolicy? {
        switch self {
        case .lax: .sameSiteLax
        case .strict: .sameSiteStrict
        case .none: nil
        }
    }
}

public extension RemoteBrowserCookie {
    init(_ cookie: HTTPCookie) throws {
        try self.init(
            name: cookie.name,
            value: cookie.value,
            domain: cookie.domain,
            path: cookie.path,
            expiresAt: cookie.expiresDate,
            isSecure: cookie.isSecure,
            isHTTPOnly: cookie.isHTTPOnly,
            sameSite: RemoteBrowserCookieSameSite(cookie.sameSitePolicy)
        )
    }

    /// `HTTPCookie` exposes `isHTTPOnly` for reading but has no public property key for setting it, so
    /// the flag round-trips through the documented wire spelling that `HTTPCookie` parses.
    static let httpOnlyPropertyKey = HTTPCookiePropertyKey("HttpOnly")

    /// `HTTPCookie` shortens any expiry beyond roughly thirteen months, the same ceiling Safari
    /// applies to cookies it stores. A long-lived cookie therefore lands on the other device with a
    /// nearer expiry than it had. It stays valid, so a sign-in still carries; it just renews sooner.
    func httpCookie() throws -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: path,
        ]
        if let expiresAt { properties[.expires] = expiresAt }
        if isSecure { properties[.secure] = "TRUE" }
        if isHTTPOnly { properties[Self.httpOnlyPropertyKey] = "TRUE" }
        if let policy = sameSite.policy { properties[.sameSitePolicy] = policy.rawValue }

        guard let cookie = HTTPCookie(properties: properties) else {
            throw RemoteBrowserCookieError.invalidCookie
        }
        return cookie
    }
}

/// One cookie as it crosses the companion link. Deliberately a value type over `Foundation` only, so
/// both the AppKit host and the UIKit companion can share it without either importing WebKit here.
public struct RemoteBrowserCookie: Codable, Equatable, Hashable, Sendable {
    public static let maximumNameBytes = 4_096
    public static let maximumValueBytes = 8_192
    public static let maximumDomainBytes = 253
    public static let maximumPathBytes = 2_048

    public let name: String
    public let value: String
    public let domain: String
    public let path: String
    public let expiresAt: Date?
    public let isSecure: Bool
    public let isHTTPOnly: Bool
    public let sameSite: RemoteBrowserCookieSameSite

    public init(
        name: String,
        value: String,
        domain: String,
        path: String,
        expiresAt: Date? = nil,
        isSecure: Bool = false,
        isHTTPOnly: Bool = false,
        sameSite: RemoteBrowserCookieSameSite = .none
    ) throws {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.expiresAt = expiresAt
        self.isSecure = isSecure
        self.isHTTPOnly = isHTTPOnly
        self.sameSite = sameSite
        try validate()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        value = try container.decode(String.self, forKey: .value)
        domain = try container.decode(String.self, forKey: .domain)
        path = try container.decode(String.self, forKey: .path)
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        isSecure = try container.decode(Bool.self, forKey: .isSecure)
        isHTTPOnly = try container.decode(Bool.self, forKey: .isHTTPOnly)
        sameSite = try container.decode(RemoteBrowserCookieSameSite.self, forKey: .sameSite)
        try validate()
    }

    public func validate() throws {
        guard !name.isEmpty, name.utf8.count <= Self.maximumNameBytes,
              value.utf8.count <= Self.maximumValueBytes,
              !domain.isEmpty, domain.utf8.count <= Self.maximumDomainBytes,
              !path.isEmpty, path.utf8.count <= Self.maximumPathBytes,
              expiresAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true
        else { throw RemoteBrowserCookieError.invalidCookie }
    }

    /// Identity WebKit replaces on, and the paging order. Unit separators keep a domain or path that
    /// contains the delimiter from colliding with a different cookie's key.
    public var sortKey: String { "\(domain)\u{1F}\(path)\u{1F}\(name)" }

    public func hasExpired(asOf now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }

    private enum CodingKeys: String, CodingKey {
        case name, value, domain, path, expiresAt, isSecure, isHTTPOnly, sameSite
    }
}

public struct RemoteBrowserCookiePullRequest: Codable, Equatable, Sendable {
    public static let capability = "browser-cookies-v1"

    public let profileStoreID: UUID
    /// `sortKey` of the last cookie the previous page returned; nil starts at the beginning. A cursor
    /// rather than a page number because the jar can change between round trips, and an index into a
    /// shifting list silently skips or repeats cookies.
    public let cursor: String?

    public init(profileStoreID: UUID, cursor: String? = nil) throws {
        self.profileStoreID = profileStoreID
        self.cursor = cursor
        try validate()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profileStoreID = try container.decode(UUID.self, forKey: .profileStoreID)
        cursor = try container.decodeIfPresent(String.self, forKey: .cursor)
        try validate()
    }

    public func validate() throws {
        guard cursor.map({ $0.utf8.count <= RemoteBrowserCookieTransfer.maximumCursorBytes }) ?? true
        else { throw RemoteBrowserCookieError.invalidRequest }
    }

    private enum CodingKeys: String, CodingKey { case profileStoreID, cursor }
}

public struct RemoteBrowserCookiePullResponse: Codable, Equatable, Sendable {
    public let cookies: [RemoteBrowserCookie]
    public let nextCursor: String?

    /// Non-throwing because the host builds this from cookies it has already paged; it clamps rather
    /// than fails. `init(from:)` still rejects an over-long page arriving off the wire.
    public init(cookies: [RemoteBrowserCookie], nextCursor: String? = nil) {
        self.cookies = Array(cookies.prefix(RemoteBrowserCookieTransfer.maximumCookiesPerPage))
        self.nextCursor = nextCursor
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cookies = try container.decode([RemoteBrowserCookie].self, forKey: .cookies)
        nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
        try validate()
    }

    public func validate() throws {
        guard cookies.count <= RemoteBrowserCookieTransfer.maximumCookiesPerPage,
              nextCursor.map({ $0.utf8.count <= RemoteBrowserCookieTransfer.maximumCursorBytes }) ?? true
        else { throw RemoteBrowserCookieError.invalidResponse }
    }

    private enum CodingKeys: String, CodingKey { case cookies, nextCursor }
}

public struct RemoteBrowserCookiePushRequest: Codable, Equatable, Sendable {
    public let profileStoreID: UUID
    /// Groups the chunks of one push so the host can bound a single transfer and trace it. Chunks are
    /// applied as they arrive rather than reassembled: `setCookie` replaces by name/domain/path, so
    /// each cookie stands alone and a dropped chunk costs those cookies, not the whole transfer.
    public let transferID: UUID
    public let chunkIndex: Int
    public let chunkCount: Int
    public let cookies: [RemoteBrowserCookie]

    public init(
        profileStoreID: UUID,
        transferID: UUID,
        chunkIndex: Int,
        chunkCount: Int,
        cookies: [RemoteBrowserCookie]
    ) throws {
        self.profileStoreID = profileStoreID
        self.transferID = transferID
        self.chunkIndex = chunkIndex
        self.chunkCount = chunkCount
        self.cookies = cookies
        try validate()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profileStoreID = try container.decode(UUID.self, forKey: .profileStoreID)
        transferID = try container.decode(UUID.self, forKey: .transferID)
        chunkIndex = try container.decode(Int.self, forKey: .chunkIndex)
        chunkCount = try container.decode(Int.self, forKey: .chunkCount)
        cookies = try container.decode([RemoteBrowserCookie].self, forKey: .cookies)
        try validate()
    }

    public func validate() throws {
        guard (1...RemoteBrowserCookieTransfer.maximumChunkCount).contains(chunkCount),
              (0..<chunkCount).contains(chunkIndex),
              !cookies.isEmpty,
              cookies.count <= RemoteBrowserCookieTransfer.maximumCookiesPerPage
        else { throw RemoteBrowserCookieError.invalidRequest }
    }

    private enum CodingKeys: String, CodingKey {
        case profileStoreID, transferID, chunkIndex, chunkCount, cookies
    }
}

public struct RemoteBrowserCookiePushResponse: Codable, Equatable, Sendable {
    public let acceptedCount: Int

    public init(acceptedCount: Int) {
        self.acceptedCount = acceptedCount
    }
}

public enum RemoteBrowserCookieTransfer {
    /// Each payload sits under the 16 KiB per-operation cap the browser commands already use, with
    /// room for the JSON envelope around the cookies.
    public static let maximumPayloadBytes = 12 * 1_024
    /// The cookie array's own budget, leaving room for the identifiers and JSON scaffolding wrapped
    /// around it in either request shape.
    public static let maximumCookieBytesPerPage = maximumPayloadBytes - 512
    public static let maximumCookiesPerPage = 128
    public static let maximumChunkCount = 64
    public static let maximumCursorBytes = 1_024
    /// Stops a jar that keeps growing under us from pulling forever.
    public static let maximumPullPages = 64

    /// Host error code when the workspace has companion sign-in sharing switched off. The companion
    /// treats it as "nothing to sync", not as a failure worth showing.
    public static let sharingDisabledCode = "browser_cookie_sharing_disabled"

    /// Splits cookies into payloads that each encode within `maximumPayloadBytes`. A cookie too large
    /// to fit a payload on its own is dropped rather than retried, so one oversized cookie cannot
    /// stall the whole transfer.
    public static func pages(
        of cookies: [RemoteBrowserCookie],
        encoder: JSONEncoder = JSONEncoder()
    ) -> [[RemoteBrowserCookie]] {
        var pages: [[RemoteBrowserCookie]] = []
        var current: [RemoteBrowserCookie] = []
        var currentBytes = 0

        for cookie in cookies {
            guard let encoded = try? encoder.encode(cookie) else { continue }
            let cost = encoded.count + 1
            guard cost <= maximumCookieBytesPerPage else { continue }
            if !current.isEmpty,
               current.count == maximumCookiesPerPage
                   || currentBytes + cost > maximumCookieBytesPerPage {
                pages.append(current)
                current = []
                currentBytes = 0
            }
            current.append(cookie)
            currentBytes += cost
        }

        if !current.isEmpty { pages.append(current) }
        return pages
    }
}
