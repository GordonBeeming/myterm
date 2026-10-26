import Foundation
import OSLog

/// Context files need to outlive insertion so an agent can read them, but not accumulate
/// indefinitely. Only owned capture directories older than the retention period are removed.
enum BrowserContextArtifacts {
    static let prefix = "myterm-browser-context-"
    static let retention: TimeInterval = 24 * 60 * 60

    static func pruneExpired(in root: URL = FileManager.default.temporaryDirectory,
                             now: Date = Date()) {
        do {
            let candidates = try FileManager.default.contentsOfDirectory(at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey])
            for candidate in candidates where candidate.lastPathComponent.hasPrefix(prefix) {
                let values = try candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey])
                guard values.isDirectory == true, values.isSymbolicLink != true,
                      let modified = values.contentModificationDate,
                      now.timeIntervalSince(modified) > retention else { continue }
                let attributes = try FileManager.default.attributesOfItem(atPath: candidate.path)
                guard let owner = attributes[.ownerAccountID] as? NSNumber,
                      owner.uint32Value == getuid() else { continue }
                try FileManager.default.removeItem(at: candidate)
            }
        } catch {
            Logger(subsystem: "com.gordonbeeming.myterm", category: "browser-context")
                .error("Could not prune expired browser captures: \(error.localizedDescription, privacy: .public)")
        }
    }
}
