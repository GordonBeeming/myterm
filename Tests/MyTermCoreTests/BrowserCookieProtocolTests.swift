import Foundation
import Testing

@testable import MyTermCore

private func cookie(
    name: String = "session",
    value: String = "abc123",
    domain: String = "example.com",
    path: String = "/",
    expiresAt: Date? = nil,
    isSecure: Bool = true,
    isHTTPOnly: Bool = true,
    sameSite: RemoteBrowserCookieSameSite = .lax
) throws -> RemoteBrowserCookie {
    try RemoteBrowserCookie(
        name: name, value: value, domain: domain, path: path, expiresAt: expiresAt,
        isSecure: isSecure, isHTTPOnly: isHTTPOnly, sameSite: sameSite
    )
}

@Test func cookieSurvivesTheRoundTripThroughHTTPCookieWithItsFlagsIntact() throws {
    // Whole seconds, and inside the platform's expiry ceiling so this asserts the mapping rather
    // than the clamp that `farFutureExpiryIsClampedNotDropped` covers.
    let expires = Date().addingTimeInterval(3_600).timeIntervalSince1970.rounded(.down)
    let original = try cookie(
        expiresAt: Date(timeIntervalSince1970: expires), sameSite: .strict)

    let restored = try RemoteBrowserCookie(try original.httpCookie())

    #expect(restored.name == original.name)
    #expect(restored.value == original.value)
    #expect(restored.domain == original.domain)
    #expect(restored.path == original.path)
    #expect(restored.expiresAt == original.expiresAt)
    #expect(restored.isSecure)
    // The flags that make a sign-in a sign-in; losing either silently breaks the sync.
    #expect(restored.isHTTPOnly)
    #expect(restored.sameSite == .strict)
}

@Test func farFutureExpiryIsClampedNotDropped() throws {
    // `HTTPCookie` shortens an expiry beyond roughly thirteen months, the same ceiling Safari applies
    // to what it stores. A long-lived cookie therefore arrives with a nearer expiry than it left
    // with. It must still arrive live, and must not become a session cookie.
    let original = try cookie(expiresAt: Date(timeIntervalSince1970: 2_000_000_000))

    let restored = try RemoteBrowserCookie(try original.httpCookie())

    let clamped = try #require(restored.expiresAt)
    let requested = try #require(original.expiresAt)
    #expect(clamped > Date(), "A clamped expiry that lands in the past would sign the user out")
    #expect(clamped < requested)
    #expect(!restored.hasExpired())
}

@Test func aSessionCookieStaysSessionScopedAndSameSiteNoneStaysAbsent() throws {
    let original = try cookie(expiresAt: nil, isSecure: false, isHTTPOnly: false, sameSite: .none)

    let restored = try RemoteBrowserCookie(try original.httpCookie())

    #expect(restored.expiresAt == nil)
    #expect(!restored.isSecure)
    #expect(!restored.isHTTPOnly)
    #expect(restored.sameSite == .none)
}

@Test func cookieRejectsEmptyAndOversizedFields() throws {
    #expect(throws: RemoteBrowserCookieError.self) { try cookie(name: "") }
    #expect(throws: RemoteBrowserCookieError.self) { try cookie(domain: "") }
    #expect(throws: RemoteBrowserCookieError.self) { try cookie(path: "") }
    #expect(throws: RemoteBrowserCookieError.self) {
        try cookie(value: String(repeating: "x", count: RemoteBrowserCookie.maximumValueBytes + 1))
    }
    #expect(throws: RemoteBrowserCookieError.self) {
        try cookie(name: String(repeating: "x", count: RemoteBrowserCookie.maximumNameBytes + 1))
    }
}

@Test func sortKeySeparatesCookiesThatDifferOnlyByBoundary() throws {
    // Without a separator WebKit would not distinguish these, and the pull cursor would skip one.
    let first = try cookie(name: "b", domain: "example.com", path: "/a")
    let second = try cookie(name: "a", domain: "example.com", path: "/ab")
    #expect(first.sortKey != second.sortKey)
}

@Test func expiredCookiesAreRecognisedAndSessionCookiesAreNot() throws {
    let now = Date(timeIntervalSince1970: 1_000_000)
    #expect(try cookie(expiresAt: now.addingTimeInterval(-1)).hasExpired(asOf: now))
    #expect(try cookie(expiresAt: now).hasExpired(asOf: now))
    #expect(!(try cookie(expiresAt: now.addingTimeInterval(1)).hasExpired(asOf: now)))
    #expect(!(try cookie(expiresAt: nil).hasExpired(asOf: now)))
}

@Test func pagingKeepsEveryPageInsideTheByteBudget() throws {
    let encoder = JSONEncoder()
    let cookies = try (0..<40).map { index in
        try cookie(name: "c\(index)", value: String(repeating: "v", count: 1_000))
    }

    let pages = RemoteBrowserCookieTransfer.pages(of: cookies, encoder: encoder)

    #expect(pages.count > 1, "A 40 KB jar has to split")
    #expect(pages.flatMap { $0 }.count == cookies.count, "No cookie may be dropped")
    for page in pages {
        #expect(!page.isEmpty, "An empty page would stall the cursor")
        let bytes = try page.reduce(0) { try $0 + encoder.encode($1).count + 1 }
        #expect(bytes <= RemoteBrowserCookieTransfer.maximumCookieBytesPerPage)
    }
}

@Test func aCookieTooLargeToPageIsSkippedRatherThanStallingTheRest() throws {
    // A cookie at the field maxima encodes larger than one page, so the skip is reachable with
    // cookies that are individually valid.
    let oversized = try cookie(
        name: String(repeating: "n", count: RemoteBrowserCookie.maximumNameBytes),
        value: String(repeating: "v", count: RemoteBrowserCookie.maximumValueBytes)
    )
    let ordinary = try cookie(name: "small", value: "v")

    let pages = RemoteBrowserCookieTransfer.pages(of: [oversized, ordinary, oversized])

    #expect(pages.count == 1)
    #expect(pages.first?.map(\.name) == ["small"])
}

@Test func pagingNeverExceedsEitherCap() throws {
    let encoder = JSONEncoder()
    let cookies = try (0..<400).map { try cookie(name: "c\($0)", value: "v") }

    let pages = RemoteBrowserCookieTransfer.pages(of: cookies, encoder: encoder)

    #expect(pages.count > 1)
    #expect(pages.flatMap { $0 }.count == cookies.count)
    for page in pages {
        #expect(page.count <= RemoteBrowserCookieTransfer.maximumCookiesPerPage)
        let bytes = try page.reduce(0) { try $0 + encoder.encode($1).count + 1 }
        #expect(bytes <= RemoteBrowserCookieTransfer.maximumCookieBytesPerPage)
    }
}

@Test func pullRequestRejectsAnOverlongCursor() throws {
    let store = UUID()
    #expect(try RemoteBrowserCookiePullRequest(profileStoreID: store, cursor: "a").cursor == "a")
    #expect(throws: RemoteBrowserCookieError.self) {
        try RemoteBrowserCookiePullRequest(
            profileStoreID: store,
            cursor: String(repeating: "x", count: RemoteBrowserCookieTransfer.maximumCursorBytes + 1)
        )
    }
}

@Test func theCursorBoundAdmitsTheLongestKeyACookieCanHave() throws {
    // A page ending on a maximal cookie emits that cookie's sortKey as the cursor. If the bound were
    // smaller the client would reject the response and the pull would stop early, losing the rest.
    let longest = try cookie(
        name: String(repeating: "n", count: RemoteBrowserCookie.maximumNameBytes),
        domain: String(repeating: "d", count: RemoteBrowserCookie.maximumDomainBytes),
        path: String(repeating: "p", count: RemoteBrowserCookie.maximumPathBytes)
    )

    #expect(longest.sortKey.utf8.count == RemoteBrowserCookieTransfer.maximumCursorBytes)
    let request = try RemoteBrowserCookiePullRequest(
        profileStoreID: UUID(), cursor: longest.sortKey)
    #expect(request.cursor == longest.sortKey)
    #expect(
        try JSONDecoder().decode(
            RemoteBrowserCookiePullResponse.self,
            from: JSONEncoder().encode(
                RemoteBrowserCookiePullResponse(cookies: [longest], nextCursor: longest.sortKey))
        ).nextCursor == longest.sortKey)
}

@Test func pushCarriesDeletionsAndAcceptsAChunkThatOnlyDeletes() throws {
    let key = try RemoteBrowserCookieKey(domain: "example.com", path: "/", name: "session")

    let deletionOnly = try RemoteBrowserCookiePushRequest(
        profileStoreID: UUID(), transferID: UUID(), chunkIndex: 0, chunkCount: 1,
        cookies: [], removed: [key])
    #expect(deletionOnly.removed == [key])

    // A chunk that neither sets nor deletes is pure cost.
    #expect(throws: RemoteBrowserCookieError.self) {
        try RemoteBrowserCookiePushRequest(
            profileStoreID: UUID(), transferID: UUID(), chunkIndex: 0, chunkCount: 1,
            cookies: [], removed: [])
    }

    // A peer that predates deletions sends no `removed` key at all.
    let legacy = try JSONDecoder().decode(
        RemoteBrowserCookiePushRequest.self,
        from: Data(
            #"{"profileStoreID":"\#(UUID().uuidString)","transferID":"\#(UUID().uuidString)","chunkIndex":0,"chunkCount":1,"cookies":[\#(String(decoding: try JSONEncoder().encode(try cookie()), as: UTF8.self))]}"#
                .utf8))
    #expect(legacy.removed.isEmpty)
}

@Test func deletionKeyMatchesItsCookieAndRejectsEmptyFields() throws {
    let source = try cookie(name: "session", domain: "example.com")
    #expect(RemoteBrowserCookieKey(source).sortKey == source.sortKey)

    #expect(throws: RemoteBrowserCookieError.self) {
        try RemoteBrowserCookieKey(domain: "", path: "/", name: "a")
    }
    #expect(throws: RemoteBrowserCookieError.self) {
        try RemoteBrowserCookieKey(domain: "example.com", path: "/", name: "")
    }
    #expect(throws: RemoteBrowserCookieError.self) {
        try RemoteBrowserCookieKey(domain: "example.com", path: "", name: "a")
    }
}

@Test func deletionKeyPagesStayInsideOneCommandPayload() throws {
    let keys = try (0..<500).map {
        try RemoteBrowserCookieKey(domain: "example.com", path: "/", name: "c\($0)")
    }

    let pages = RemoteBrowserCookieTransfer.keyPages(of: keys)

    #expect(pages.flatMap { $0 }.count == keys.count)
    for (index, page) in pages.enumerated() {
        #expect(page.count <= RemoteBrowserCookieTransfer.maximumCookiesPerPage)
        let request = try RemoteBrowserCookiePushRequest(
            profileStoreID: UUID(), transferID: UUID(), chunkIndex: index,
            chunkCount: max(pages.count, index + 1), cookies: [], removed: page)
        #expect(try JSONEncoder().encode(request).count <= 16 * 1_024)
    }
}

@Test func pullResponseClampsWhenBuiltButRejectsAnOverlongPageOffTheWire() throws {
    let cookies = try (0...RemoteBrowserCookieTransfer.maximumCookiesPerPage).map {
        try cookie(name: "c\($0)")
    }

    // The host builds from cookies it already paged, so it clamps rather than failing.
    let built = RemoteBrowserCookiePullResponse(cookies: cookies)
    #expect(built.cookies.count == RemoteBrowserCookieTransfer.maximumCookiesPerPage)

    // A peer sending more than a page is a different matter.
    let smuggled = try JSONEncoder().encode(["cookies": cookies])
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(RemoteBrowserCookiePullResponse.self, from: smuggled)
    }
}

@Test func pushRequestRejectsChunkIndexesOutsideTheDeclaredCount() throws {
    let store = UUID()
    let transfer = UUID()
    let payload = [try cookie()]

    #expect(
        try RemoteBrowserCookiePushRequest(
            profileStoreID: store, transferID: transfer, chunkIndex: 0, chunkCount: 1,
            cookies: payload
        ).chunkCount == 1)

    for (index, count) in [(1, 1), (-1, 2), (2, 2)] {
        #expect(throws: RemoteBrowserCookieError.self) {
            try RemoteBrowserCookiePushRequest(
                profileStoreID: store, transferID: transfer, chunkIndex: index, chunkCount: count,
                cookies: payload
            )
        }
    }
    #expect(throws: RemoteBrowserCookieError.self) {
        try RemoteBrowserCookiePushRequest(
            profileStoreID: store, transferID: transfer, chunkIndex: 0, chunkCount: 1, cookies: [])
    }
    #expect(throws: RemoteBrowserCookieError.self) {
        try RemoteBrowserCookiePushRequest(
            profileStoreID: store, transferID: transfer, chunkIndex: 0,
            chunkCount: RemoteBrowserCookieTransfer.maximumChunkCount + 1, cookies: payload)
    }
}

@Test func everyPageFitsOneCommandPayload() throws {
    // The wire limit the operation is validated against on the host is 16 KiB; a full page plus its
    // identifiers has to stay under it or the peer's connection is dropped for an invalid message.
    let cookies = try (0..<RemoteBrowserCookieTransfer.maximumCookiesPerPage).map {
        try cookie(name: "c\($0)", value: String(repeating: "v", count: 60))
    }

    for (index, page) in RemoteBrowserCookieTransfer.pages(of: cookies).enumerated() {
        let request = try RemoteBrowserCookiePushRequest(
            profileStoreID: UUID(), transferID: UUID(), chunkIndex: index,
            chunkCount: RemoteBrowserCookieTransfer.maximumChunkCount, cookies: page
        )
        #expect(try JSONEncoder().encode(request).count <= 16 * 1_024)
    }
}
