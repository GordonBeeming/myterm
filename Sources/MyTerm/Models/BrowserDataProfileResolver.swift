import CryptoKit
import Foundation
import MyTermCore

struct ProjectDirectoryResolver {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func resolve(from currentDirectory: URL) -> URL {
        var directory = currentDirectory.standardizedFileURL

        while true {
            let gitMarker = directory.appending(path: ".git", directoryHint: .notDirectory)
            if fileManager.fileExists(atPath: gitMarker.path) {
                return directory
            }

            let parent = directory.deletingLastPathComponent().standardizedFileURL
            guard parent.path != directory.path else {
                return currentDirectory.standardizedFileURL
            }
            directory = parent
        }
    }
}

struct BrowserDataProfileResolver {
    private let channel: MyTermChannel
    private let projectDirectoryResolver: ProjectDirectoryResolver
    private let homeDirectory: URL

    init(
        channel: MyTermChannel,
        projectDirectoryResolver: ProjectDirectoryResolver = ProjectDirectoryResolver(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.channel = channel
        self.projectDirectoryResolver = projectDirectoryResolver
        self.homeDirectory = homeDirectory.standardizedFileURL
    }

    func resolve(
        scope: BrowserDataScope,
        workspace: Workspace,
        sourceWorkingDirectory: URL? = nil
    ) -> BrowserDataProfile {
        switch scope {
        case .appWide:
            return BrowserDataProfile(
                scope: scope,
                persistentStoreID: persistentStoreID(for: "app-wide")
            )
        case .workspace:
            return BrowserDataProfile(
                scope: scope,
                persistentStoreID: persistentStoreID(for: "workspace|\(workspace.id)")
            )
        case .projectDirectory:
            let workingDirectory = sourceWorkingDirectory?.standardizedFileURL
                ?? workingDirectory(in: workspace)
            let directory = projectDirectoryResolver.resolve(from: workingDirectory)
            return BrowserDataProfile(
                scope: scope,
                persistentStoreID: persistentStoreID(for: "project-directory|\(directory.path)"),
                projectDirectory: directory
            )
        }
    }

    private func workingDirectory(in workspace: Workspace) -> URL {
        let preferredTabs = [workspace.selectedTab].compactMap { $0 }
            + workspace.allTabs.filter { $0.id != workspace.selectedTabID }

        for tab in preferredTabs {
            if case .terminal(let session) = tab.content,
               let workingDirectory = session.workingDirectory {
                return workingDirectory.standardizedFileURL
            }
        }

        return homeDirectory
    }

    private func persistentStoreID(for key: String) -> UUID {
        let namespace = "\(channel.bundleIdentifier)|browser-data-profile|\(key)"
        let digest = Array(SHA256.hash(data: Data(namespace.utf8)))
        let bytes = digest.prefix(16).enumerated().map { index, byte -> UInt8 in
            switch index {
            case 6:
                return (byte & 0x0F) | 0x50
            case 8:
                return (byte & 0x3F) | 0x80
            default:
                return byte
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
