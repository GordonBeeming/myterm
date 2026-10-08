import CryptoKit
import Foundation
import MyTermCore
import WebKit

/// Reads and writes one companion data store's cookie jar. The Mac has its own equivalent; only the
/// `RemoteBrowserCookie` model is shared, because the two platforms cannot share a WebKit wrapper.
@MainActor
struct CompanionBrowserCookies {
    private let cookieStore: WKHTTPCookieStore

    init(dataStore: WKWebsiteDataStore) {
        cookieStore = dataStore.httpCookieStore
    }

    func all() async -> [RemoteBrowserCookie] {
        let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            cookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        return cookies
            .compactMap { try? RemoteBrowserCookie($0) }
            .filter { !$0.hasExpired() }
    }

    func apply(_ cookies: [RemoteBrowserCookie]) async {
        for cookie in cookies where !cookie.hasExpired() {
            guard let httpCookie = try? cookie.httpCookie() else { continue }
            await withCheckedContinuation { continuation in
                cookieStore.setCookie(httpCookie) { continuation.resume() }
            }
        }
    }
}

/// Keeps one persistent website data store per Mac browser profile, so the native-proxy browser holds
/// its cookies across mode switches, reconnects and tab changes instead of starting over each time.
///
/// Only one live web view may use a given store: `proxyConfigurations` is a property of the data
/// store, not of the web view, so a second route pointing the same store at its own loopback proxy
/// would silently retarget the first route's traffic and break its artifact origin. `acquire` hands
/// the store to one route at a time and reports who it displaced.
@MainActor
final class BrowserProfileStores {
    private static let ownershipKey = "browserProfileStoreOwners"

    private var stores: [UUID: WKWebsiteDataStore] = [:]
    private var holders: [UUID: (route: BrowserRoute, onDisplaced: () -> Void)] = [:]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The companion's own store identifier for a Mac profile. Derived rather than reused verbatim so
    /// two paired Macs stay isolated even if a workspace import leaves them sharing a profile UUID.
    ///
    /// Falls back to the workspace when the host is too old to send a profile identifier. That is
    /// workspace-scoped whatever the Mac's "Browser data" setting says, so it can be a narrower
    /// boundary than the Mac's — but it persists, which is the part that was broken.
    nonisolated static func identifier(hostID: UUID, profileStoreID: UUID?, workspaceID: UUID) -> UUID {
        let key = profileStoreID.map { "profile|\($0.uuidString)" } ?? "workspace|\(workspaceID.uuidString)"
        return derivedUUID(from: "myterm-companion|browser-data-profile|\(hostID.uuidString)|\(key)")
    }

    /// Hands the store to `route`. Any other route already holding it is told it has lost the store so
    /// it can stop its web view and say so; it is not restarted automatically, because two live views
    /// taking it back from each other would never settle.
    func acquire(
        identifier: UUID,
        for route: BrowserRoute,
        onDisplaced: @escaping () -> Void
    ) -> WKWebsiteDataStore {
        let store = stores[identifier] ?? WKWebsiteDataStore(forIdentifier: identifier)
        stores[identifier] = store
        recordOwnership(identifier: identifier, hostID: route.hostID)

        if let previous = holders[identifier], previous.route != route {
            previous.onDisplaced()
        }
        holders[identifier] = (route, onDisplaced)
        return store
    }

    func release(identifier: UUID, from route: BrowserRoute) {
        guard holders[identifier]?.route == route else { return }
        holders.removeValue(forKey: identifier)
        stores[identifier]?.proxyConfigurations = []
    }

    func store(identifier: UUID) -> WKWebsiteDataStore? { stores[identifier] }

    /// Forgets a Mac's jars when the host is removed, so a device that is no longer paired leaves no
    /// sign-ins on the phone. The identifier-to-host map is stored rather than kept in memory because
    /// a pairing is often removed in a launch where no browser tab was ever opened, and an in-memory
    /// map would be empty exactly then. The identifiers are derived hashes, not secrets.
    func removeStores(hostID: UUID) async {
        var owners = ownership
        let identifiers = owners.compactMap { key, value -> UUID? in
            guard value == hostID.uuidString, let identifier = UUID(uuidString: key) else { return nil }
            return identifier
        }
        var failures: [String] = []
        for identifier in identifiers {
            stores.removeValue(forKey: identifier)
            holders.removeValue(forKey: identifier)
            do {
                try await WKWebsiteDataStore.remove(forIdentifier: identifier)
                owners.removeValue(forKey: identifier.uuidString)
            } catch {
                // Keep the ownership row so removing this pairing again retries the delete rather
                // than orphaning a jar nothing can find any more.
                failures.append(error.localizedDescription)
            }
        }
        defaults.set(owners, forKey: Self.ownershipKey)
        if !failures.isEmpty {
            await DiagnosticsLog.shared.record(
                category: "browser",
                "could not clear \(failures.count) browser profile store(s) for a removed Mac",
                detail: failures.joined(separator: "; ")
            )
        }
    }

    private var ownership: [String: String] {
        defaults.dictionary(forKey: Self.ownershipKey) as? [String: String] ?? [:]
    }

    private func recordOwnership(identifier: UUID, hostID: UUID) {
        var owners = ownership
        guard owners[identifier.uuidString] != hostID.uuidString else { return }
        owners[identifier.uuidString] = hostID.uuidString
        defaults.set(owners, forKey: Self.ownershipKey)
    }

    /// Same shape as the Mac's `BrowserDataProfileResolver`, so both sides read as one scheme: a
    /// SHA-256 digest trimmed to 16 bytes with the version and variant bits set for a v5 UUID.
    nonisolated private static func derivedUUID(from namespace: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data(namespace.utf8)))
        let bytes = digest.prefix(16).enumerated().map { index, byte -> UInt8 in
            switch index {
            case 6: return (byte & 0x0F) | 0x50
            case 8: return (byte & 0x3F) | 0x80
            default: return byte
            }
        }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
