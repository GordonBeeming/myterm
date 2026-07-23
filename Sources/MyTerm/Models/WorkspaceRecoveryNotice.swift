import Foundation
import MyTermCore

struct WorkspaceRecoveryNotice: Equatable, Sendable {
    let message: String
    let identifierRepairCount: Int
    let structuralRepairCount: Int
    let droppedElementCount: Int
    let didMigrate: Bool
    let backupURLs: [URL]

    init?(loadReport: WorkspaceStoreLoadReport) {
        let repairedCount = loadReport.identifierRepairCount + loadReport.structuralRepairCount
        guard loadReport.didMigrate || repairedCount > 0 || loadReport.droppedElementCount > 0 else {
            return nil
        }

        identifierRepairCount = loadReport.identifierRepairCount
        structuralRepairCount = loadReport.structuralRepairCount
        droppedElementCount = loadReport.droppedElementCount
        didMigrate = loadReport.didMigrate
        backupURLs = loadReport.backupURLs

        var changes: [String] = []
        if loadReport.didMigrate {
            changes.append("upgraded the workspace format")
        }
        if loadReport.identifierRepairCount > 0 {
            changes.append("repaired \(Self.counted(loadReport.identifierRepairCount, singular: "identifier"))")
        }
        if loadReport.structuralRepairCount > 0 {
            changes.append("repaired \(Self.counted(loadReport.structuralRepairCount, singular: "structural issue"))")
        }
        if loadReport.droppedElementCount > 0 {
            changes.append("removed \(Self.counted(loadReport.droppedElementCount, singular: "invalid item"))")
        }

        let summary = changes.joined(separator: ", ")
        if loadReport.backupURLs.isEmpty {
            message = "MyTerm repaired workspace state during startup: \(summary)."
        } else {
            let paths = loadReport.backupURLs.map(\.path).joined(separator: ", ")
            message = "MyTerm repaired workspace state during startup: \(summary). Original data is backed up at \(paths)."
        }
    }

    private static func counted(_ count: Int, singular: String) -> String {
        "\(count) \(singular)\(count == 1 ? "" : "s")"
    }
}
