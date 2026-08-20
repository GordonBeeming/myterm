import Foundation
import MyTermCore

struct WorkspaceRecoveryNotice: Equatable, Sendable {
    let message: String
    let identifierRepairCount: Int
    let structuralRepairCount: Int
    let droppedElementCount: Int
    let didMigrate: Bool
    let backupURLs: [URL]
    let backupFailureDescriptions: [String]

    init?(loadReport: WorkspaceStoreLoadReport) {
        let repairedCount = loadReport.identifierRepairCount + loadReport.structuralRepairCount
        guard loadReport.didMigrate
            || repairedCount > 0
            || loadReport.droppedElementCount > 0
            || !loadReport.backupFailureDescriptions.isEmpty else {
            return nil
        }

        identifierRepairCount = loadReport.identifierRepairCount
        structuralRepairCount = loadReport.structuralRepairCount
        droppedElementCount = loadReport.droppedElementCount
        didMigrate = loadReport.didMigrate
        backupURLs = loadReport.backupURLs
        backupFailureDescriptions = loadReport.backupFailureDescriptions

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

        var sentences: [String] = []
        if !changes.isEmpty {
            sentences.append(
                "MyTerm repaired workspace state during startup: \(changes.joined(separator: ", "))."
            )
        }
        if !loadReport.backupURLs.isEmpty {
            let paths = loadReport.backupURLs.map(\.path).joined(separator: ", ")
            sentences.append("Original data is backed up at \(paths).")
        }
        if !loadReport.backupFailureDescriptions.isEmpty {
            let reasons = loadReport.backupFailureDescriptions.joined(separator: " ")
            sentences.append("MyTerm could not back up the original data: \(reasons)")
        }
        message = sentences.joined(separator: " ")
    }

    private static func counted(_ count: Int, singular: String) -> String {
        "\(count) \(singular)\(count == 1 ? "" : "s")"
    }
}
