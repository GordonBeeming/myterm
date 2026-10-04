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
        guard let workspace = store.workspaces.first(where: { $0.id.rawValue == route.workspaceID }),
              let group = workspace.orderedGroups.first(where: { $0.id.rawValue == route.groupID }),
              let tab = group.tabs.first(where: { $0.id.rawValue == route.tabID }),
              let browser = tab.browserSession else { throw CompanionCommandError.wrongTarget }
        return browser.url
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
