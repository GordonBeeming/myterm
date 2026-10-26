import Foundation
import OSLog
import MyTermCore
import MyTermPlatform

struct BrowserContextTerminalTarget: Identifiable, Hashable {
    let workspaceID: WorkspaceID
    let groupID: TabGroupID
    let tabID: TabID
    let sessionID: TerminalSessionID
    let title: String
    var id: TabID { tabID }
}

extension AppModel {
    func browserContextTargets(in workspaceID: WorkspaceID) -> [BrowserContextTerminalTarget] {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else { return [] }
        return workspace.layout.orderedGroups.flatMap { group in
            group.tabs.compactMap { tab -> BrowserContextTerminalTarget? in
                guard let session = tab.terminalSession,
                      terminalSessions[session.id]?.isRunning == true else { return nil }
                return BrowserContextTerminalTarget(workspaceID: workspaceID, groupID: group.id,
                    tabID: tab.id, sessionID: session.id, title: tab.customTitle ?? tab.automaticDisplayTitle)
            }
        }
    }

    func insertBrowserContext(_ text: String, screenshot: Data?,
                              target: BrowserContextTerminalTarget,
                              artifactRoot: URL = FileManager.default.temporaryDirectory) throws {
        guard browserContextTargets(in: target.workspaceID).contains(target),
              let session = terminalSessions[target.sessionID] else {
            throw BrowserContextDeliveryError.targetUnavailable
        }
        BrowserContextArtifacts.pruneExpired(in: artifactRoot)
        var body = text
        var imageURL: URL?
        if let screenshot {
            let directory = artifactRoot.appending(path: BrowserContextArtifacts.prefix + UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            let file = directory.appending(path: UUID().uuidString + ".png")
            try screenshot.write(to: file, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            imageURL = file
            body += "\n\nScreenshot file on this Mac (read this image): \(file.path)"
        }
        do {
            try session.insertLocalText(body)
        } catch {
            if let imageURL {
                do { try FileManager.default.removeItem(at: imageURL.deletingLastPathComponent()) }
                catch { Logger(subsystem: "com.gordonbeeming.myterm", category: "browser-context")
                    .error("Could not remove unused browser capture: \(error.localizedDescription, privacy: .public)") }
            }
            throw error
        }
        revealTab(target.tabID, in: target.workspaceID)
    }
}

enum BrowserContextDeliveryError: LocalizedError {
    case targetUnavailable
    var errorDescription: String? { "The selected terminal is no longer available. Choose another terminal." }
}
