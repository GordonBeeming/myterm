import Foundation
import MyTermCore
import MyTermPlatform
import MyTermRemote

struct CompanionBrowserRoute: Hashable {
    let workspaceID: UUID
    let groupID: UUID
    let tabID: UUID

    init(_ metadata: MessageMetadata) throws {
        guard let workspaceID = metadata.workspaceID, let groupID = metadata.groupID,
              let tabID = metadata.tabID, metadata.sessionID == nil else {
            throw CompanionCommandError.wrongTarget
        }
        self.workspaceID = workspaceID
        self.groupID = groupID
        self.tabID = tabID
    }
}

@MainActor
extension AppModel {
    func companionBrowserURL(route: CompanionBrowserRoute) throws -> URL {
        try companionBrowserSession(route: route).url
    }

    /// The data profile behind a route's browser tab. Cookie sync is keyed on this rather than on the
    /// route, so every tab sharing a workspace's profile shares one jar — the same boundary the
    /// "Browser data" setting draws on the Mac.
    func companionBrowserProfile(route: CompanionBrowserRoute) throws -> BrowserDataProfile {
        guard let profile = try companionBrowserSession(route: route).profile else {
            throw CompanionCommandError.wrongTarget
        }
        return profile
    }

    /// Whether a profile's jar may cross to a companion. The setting is per workspace but a profile can
    /// be shared by many of them, under a folder-wide or app-wide browser-data scope, and the jar is
    /// one jar. So consent has to be unanimous: a single workspace with sharing off keeps the whole
    /// profile on this Mac, because exporting it would carry that workspace's sign-ins too.
    func companionSharesBrowserSignIns(profile: BrowserDataProfile) -> Bool {
        var found = false
        for workspace in store.workspaces {
            let usesProfile = workspace.allTabs.contains {
                $0.browserSession?.profile?.persistentStoreID == profile.persistentStoreID
            }
            guard usesProfile else { continue }
            found = true
            guard (try? store.resolvedSettings(for: workspace.id))?
                .sharesBrowserSignInsWithCompanion == true else { return false }
        }
        return found
    }

    private func companionBrowserSession(route: CompanionBrowserRoute) throws -> BrowserSession {
        guard let workspace = store.workspaces.first(where: { $0.id.rawValue == route.workspaceID }),
              let group = workspace.orderedGroups.first(where: { $0.id.rawValue == route.groupID }),
              let tab = group.tabs.first(where: { $0.id.rawValue == route.tabID }),
              let browser = tab.browserSession else { throw CompanionCommandError.wrongTarget }
        return browser
    }
}

@MainActor
final class CompanionBrowserSessions {
    struct Native {
        var openingStreams: Set<UUID> = []
        let tunnel: RemoteBrowserHostTunnel
        let artifact: CompanionBrowserArtifactServer?
        let sourceURL: URL
        let allowsLocalFileJavaScript: Bool
    }
    struct Rendered {
        let rendererID: UUID?
        let controller: RemoteBrowserRenderer
        let sourceURL: URL
        let allowsLocalFileJavaScript: Bool
        let artifact: CompanionBrowserArtifactServer?
    }
    var native: [CompanionBrowserRoute: Native] = [:]
    var rendered: [CompanionBrowserRoute: Rendered] = [:]

    func close(route: CompanionBrowserRoute) {
        closeNative(route: route)
        closeRendered(route: route)
    }

    func closeNative(route: CompanionBrowserRoute) {
        if let entry = native.removeValue(forKey: route) {
            Task { await entry.tunnel.closeAll(); await entry.artifact?.close() }
        }
    }

    func closeRendered(route: CompanionBrowserRoute) {
        if let entry = rendered.removeValue(forKey: route) {
            entry.controller.close()
            Task { await entry.artifact?.close() }
        }
    }

    func closeAll() {
        for route in Set(native.keys).union(rendered.keys) { close(route: route) }
    }

    func prune(model: AppModel) {
        for route in Set(native.keys).union(rendered.keys) {
            let current = try? model.companionBrowserURL(route: route)
            let scriptPermission = try? model.store.resolvedSettings(for: WorkspaceID(rawValue: route.workspaceID)).allowsLocalFileJavaScript
            if current == nil || native[route].map({ $0.sourceURL != current || $0.allowsLocalFileJavaScript != scriptPermission }) == true
                || rendered[route].map({ $0.sourceURL != current || $0.allowsLocalFileJavaScript != scriptPermission }) == true { close(route: route) }
        }
    }
}
