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
    /// Whether a needed backup ran and nothing came out of it — see `WorkspaceStoreLoadReport`.
    ///
    /// Exposed here too so the banner text and any other reader of this notice (the startup log)
    /// branch on the same fact instead of each re-deriving it and risking drift.
    let preservedNothing: Bool

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
        preservedNothing = loadReport.preservedNothing

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
            // The system reason isn't guaranteed to end in a period, so add one before joining
            // sentences; otherwise the next sentence reads as a continuation of the reason.
            let reasons = loadReport.backupFailureDescriptions
                .map { $0.hasSuffix(".") ? $0 : "\($0)." }
                .joined(separator: " ")
            // A version-1 source that also needs a repair writes two backups of the same bytes. When
            // one succeeds, the "Original data is backed up at ..." sentence above already covers it,
            // so this failure is a second, redundant copy, not the loss the other wording implies.
            if preservedNothing {
                sentences.append(
                    "MyTerm could not back up the original data: \(reasons) Changes in this session will not be saved."
                )
            } else {
                sentences.append("MyTerm could not write a second backup copy: \(reasons)")
            }
        }
        message = sentences.joined(separator: " ")
    }

    private static func counted(_ count: Int, singular: String) -> String {
        "\(count) \(singular)\(count == 1 ? "" : "s")"
    }
}
