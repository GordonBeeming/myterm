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
        await allCookies()
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

    /// Deletes the named cookies. Matching is on domain, path and name, the triple WebKit replaces on.
    func remove(_ keys: [RemoteBrowserCookieKey]) async {
        guard !keys.isEmpty else { return }
        let wanted = Set(keys.map(\.sortKey))
        for cookie in await allCookies() {
            guard let mapped = try? RemoteBrowserCookie(cookie), wanted.contains(mapped.sortKey) else {
                continue
            }
            await withCheckedContinuation { continuation in
                cookieStore.delete(cookie) { continuation.resume() }
            }
        }
    }

    private func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            cookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
    }
}

/// Works out what each side owes the other, given both jars and what they agreed on last time.
///
/// Deletions need that third input. Seeing a cookie on one side and not the other says nothing on its
/// own: it could be new there or deleted here. The baseline, the keys both sides held at the last
/// successful sync, is what tells the two apart.
enum BrowserCookieReconciler {
    struct Plan: Equatable {
        var deleteLocally: [RemoteBrowserCookieKey] = []
        var applyLocally: [RemoteBrowserCookie] = []
        var push: [RemoteBrowserCookie] = []
        var baseline: Set<String> = []
        /// What both sides are believed to hold once this plan is carried out.
        var synced: Set<RemoteBrowserCookie> = []
    }

    /// First sync of a session, against the Mac's full snapshot.
    static func plan(
        local: [RemoteBrowserCookie],
        remote: [RemoteBrowserCookie],
        baseline: Set<String>
    ) -> Plan {
        let remoteKeys = Set(remote.map(\.sortKey))
        var plan = Plan()

        // In the baseline and still here, but gone from the Mac: the Mac deleted it, so follow suit.
        plan.deleteLocally = local
            .filter { baseline.contains($0.sortKey) && !remoteKeys.contains($0.sortKey) }
            .map(RemoteBrowserCookieKey.init)

        plan.applyLocally = remote

        // Here, unknown to the Mac, and never synced: this device signed in, so send it over. A
        // cookie that is in the baseline but missing from the Mac is a deletion, handled above.
        plan.push = local.filter { !remoteKeys.contains($0.sortKey) && !baseline.contains($0.sortKey) }

        plan.baseline = remoteKeys.union(plan.push.map(\.sortKey))
        plan.synced = Set(remote).union(plan.push)
        return plan
    }

    /// A later push from this device, with no fresh snapshot to compare against.
    static func push(
        current: [RemoteBrowserCookie],
        synced: Set<RemoteBrowserCookie>,
        baseline: Set<String>
    ) -> (changed: [RemoteBrowserCookie], removed: [RemoteBrowserCookieKey]) {
        let currentKeys = Set(current.map(\.sortKey))
        let changed = current.filter { !synced.contains($0) }
        let removed = baseline.subtracting(currentKeys).compactMap(Self.key(fromSortKey:))
        return (changed, removed)
    }

    static func key(fromSortKey sortKey: String) -> RemoteBrowserCookieKey? {
        let parts = sortKey.components(separatedBy: "\u{1F}")
        guard parts.count == 3 else { return nil }
        return try? RemoteBrowserCookieKey(domain: parts[0], path: parts[1], name: parts[2])
    }
}

/// Keeps one persistent website data store per Mac browser profile, so the native-proxy browser holds
/// its cookies across mode switches, reconnects and tab changes instead of starting over each time.
///
/// Only one live web view may use a given store: `proxyConfigurations` is a property of the data
/// store, not of the web view, so a second view pointing the same store at its own loopback proxy
/// would silently retarget the first one's traffic and break its artifact origin.
///
/// Process-wide rather than per scene, because the thing it guards is process-wide: WebKit gives one
/// data store per identifier for the whole app. The companion supports multiple scenes, so a
/// per-scene cache let two iPad windows hold the same store without either knowing.
@MainActor
final class BrowserProfileStores {
    static let shared = BrowserProfileStores()

    private static let ownershipKey = "browserProfileStoreOwners"
    private static let baselineKey = "browserProfileCookieBaselines"

    private struct Holder {
        let owner: UUID
        /// Flushes the holder's pending cookies and stands down. Awaited before the store changes
        /// hands, so an unsent sign-in is not overwritten by the next holder's snapshot.
        let standDown: () async -> Void
    }

    private var stores: [UUID: WKWebsiteDataStore] = [:]
    private var holders: [UUID: Holder] = [:]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The companion's own store identifier for a Mac profile. Derived rather than reused verbatim so
    /// two paired Macs stay isolated even if a workspace import leaves them sharing a profile UUID.
    ///
    /// Falls back to the workspace when the host is too old to send a profile identifier. That is
    /// workspace-scoped whatever the Mac's "Browser data" setting says, so it can be a narrower
    /// boundary than the Mac's, but it persists, which is the part that was broken.
    nonisolated static func identifier(hostID: UUID, profileStoreID: UUID?, workspaceID: UUID) -> UUID {
        let key = profileStoreID.map { "profile|\($0.uuidString)" } ?? "workspace|\(workspaceID.uuidString)"
        return derivedUUID(from: "myterm-companion|browser-data-profile|\(hostID.uuidString)|\(key)")
    }

    /// Hands the store to `owner`, a token identifying one live web view rather than its route: the
    /// same tab can be open in two scenes, so a route cannot tell two holders apart.
    ///
    /// Any current holder is asked to stand down first, and that is awaited, so its pending cookies
    /// reach the Mac before this caller pulls the snapshot it will apply.
    func acquire(
        identifier: UUID,
        owner: UUID,
        hostID: UUID,
        standDown: @escaping () async -> Void
    ) async -> WKWebsiteDataStore {
        if let previous = holders[identifier], previous.owner != owner {
            holders.removeValue(forKey: identifier)
            await previous.standDown()
        }

        let store = stores[identifier] ?? WKWebsiteDataStore(forIdentifier: identifier)
        stores[identifier] = store
        recordOwnership(identifier: identifier, hostID: hostID)
        holders[identifier] = Holder(owner: owner, standDown: standDown)
        return store
    }

    func release(identifier: UUID, owner: UUID) {
        guard holders[identifier]?.owner == owner else { return }
        holders.removeValue(forKey: identifier)
        stores[identifier]?.proxyConfigurations = []
    }

    func store(identifier: UUID) -> WKWebsiteDataStore? { stores[identifier] }

    func baseline(identifier: UUID) -> Set<String> {
        let stored = defaults.dictionary(forKey: Self.baselineKey) as? [String: [String]] ?? [:]
        return Set(stored[identifier.uuidString] ?? [])
    }

    func setBaseline(_ keys: Set<String>, identifier: UUID) {
        var stored = defaults.dictionary(forKey: Self.baselineKey) as? [String: [String]] ?? [:]
        if keys.isEmpty {
            stored.removeValue(forKey: identifier.uuidString)
        } else {
            stored[identifier.uuidString] = Array(keys)
        }
        defaults.set(stored, forKey: Self.baselineKey)
    }

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
            // Whoever still holds it has to let go first; the delete fails while a web view is using
            // the store.
            if let holder = holders.removeValue(forKey: identifier) {
                await holder.standDown()
            }
            do {
                try await WKWebsiteDataStore.remove(forIdentifier: identifier)
                // Only drop our reference once the store is actually gone. Dropping it on a failed
                // delete would let a later acquire build a second store object for the same
                // identifier while the first is still live in a web view.
                stores.removeValue(forKey: identifier)
                owners.removeValue(forKey: identifier.uuidString)
                setBaseline([], identifier: identifier)
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
