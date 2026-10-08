import Foundation
import MyTermCore
@preconcurrency import WebKit

/// Reads and writes one browser profile's cookie jar without standing up a web view, so the host can
/// serve a companion's cookie sync for a workspace whose browser tab isn't on screen.
@MainActor
public struct BrowserCookieStore {
    private let cookieStore: WKHTTPCookieStore

    public init(persistentStoreID: UUID) {
        cookieStore = WKWebsiteDataStore(forIdentifier: persistentStoreID).httpCookieStore
    }

    init(cookieStore: WKHTTPCookieStore) {
        self.cookieStore = cookieStore
    }

    /// Cookies after `cursor` in `sortKey` order, trimmed to one payload. Expired cookies are dropped
    /// rather than shipped, and the cursor advances past them so a stale jar still drains.
    public func page(after cursor: String?) async -> RemoteBrowserCookiePullResponse {
        let all = await allCookies()
        let live = all
            .compactMap { try? RemoteBrowserCookie($0) }
            .filter { !$0.hasExpired() }
            .sorted { $0.sortKey < $1.sortKey }
        let remaining = cursor.map { cursor in live.filter { $0.sortKey > cursor } } ?? live

        guard let first = RemoteBrowserCookieTransfer.pages(of: remaining).first else {
            return RemoteBrowserCookiePullResponse(cookies: [])
        }
        let isLast = first.count == remaining.count
        return RemoteBrowserCookiePullResponse(
            cookies: first,
            nextCursor: isLast ? nil : first.last?.sortKey
        )
    }

    /// Returns how many cookies were stored. `setCookie` replaces on name/domain/path, so applying a
    /// chunk twice is harmless and a chunk that never arrives costs only its own cookies.
    public func apply(_ cookies: [RemoteBrowserCookie]) async -> Int {
        var accepted = 0
        for cookie in cookies where !cookie.hasExpired() {
            guard let httpCookie = try? cookie.httpCookie() else { continue }
            await setCookie(httpCookie)
            accepted += 1
        }
        return accepted
    }

    private func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            cookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
    }

    private func setCookie(_ cookie: HTTPCookie) async {
        await withCheckedContinuation { continuation in
            cookieStore.setCookie(cookie) { continuation.resume() }
        }
    }
}
