import Foundation

// This adapter only opens a disposable copy supplied by the probe.
@main
struct MigrationDecoder {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 3 else { throw NSError(domain: "usage: decoder input output", code: 1) }
        let input = URL(fileURLWithPath: args[1])
        let store = try WorkspaceStore(persistenceURL: input)
        let report = store.loadReport
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let snapshot = try JSONSerialization.jsonObject(with: encoder.encode(store.snapshot))
        let result: [String: Any] = [
            "snapshot": snapshot,
            "report": ["sourceVersion": report.sourceVersion as Any,
                       "migrated": report.didMigrate,
                       "dropped": report.droppedElementCount,
                       "identifiersRepaired": report.identifierRepairCount,
                       "structureRepaired": report.structuralRepairCount,
                       "backupFailures": report.backupFailureDescriptions]
        ]
        try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
            .write(to: URL(fileURLWithPath: args[2]))
    }
}
