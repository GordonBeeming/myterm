import Foundation
import MyTermCore
import MyTermRemote
import XCTest
@testable import MyTerm

@MainActor
final class TerminalSnippetCommandTests: XCTestCase {
    private func makeModel() throws -> AppModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("snippet-command-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let model = try AppModel(applicationSupportDirectory: directory, terminalEngine: nil,
                                 startsTerminalProcesses: false, browserLauncherURL: nil)
        let suite = "snippet-command.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        model.terminalSnippetStore = DesktopTerminalSnippetStore(defaults: defaults)
        return model
    }

    private func mutate(_ model: AppModel, operation: CommandOperation, value: some Encodable,
                        workspaceID: UUID? = nil) throws -> [TerminalSnippet] {
        let maybe = try model.performCompanionCommand(
            metadata: MessageMetadata(requestID: UUID(), hostID: UUID(), workspaceID: workspaceID),
            command: CommandParameters(operation: operation, payload: JSONEncoder().encode(value)))
        let result = try XCTUnwrap(maybe)
        return try JSONDecoder().decode([TerminalSnippet].self, from: result)
    }

    func testMacCatalogProjectsToCompanionAndCompanionUpsertPreservesIdentity() throws {
        let model = try makeModel()
        var snippet = TerminalSnippet(title: "Review", text: "Review this change")
        XCTAssertTrue(model.terminalSnippetStore.save(snippet))
        XCTAssertEqual(model.companionWorkspaceProjection().terminalSnippets, [snippet])
        snippet.text = "Review this carefully"
        for _ in 0..<2 {
            let catalog = try mutate(model, operation: .snippetUpsert, value: snippet)
            XCTAssertEqual(catalog, [snippet])
        }
        XCTAssertEqual(model.terminalSnippetStore.snippets, [snippet])
        XCTAssertEqual(model.companionWorkspaceProjection().terminalSnippets, [snippet])
        XCTAssertEqual(try mutate(model, operation: .snippetDelete,
                                  value: RemoteIdentifierResult(id: snippet.id)), [])
    }

    func testScopedCommandsRequireMatchingExistingWorkspace() throws {
        let model = try makeModel()
        let workspace = model.selectedWorkspace.id.rawValue
        let snippet = TerminalSnippet(title: "Build", text: "build", kind: .command, workspaceID: workspace)
        XCTAssertThrowsError(try mutate(model, operation: .snippetUpsert, value: snippet))
        XCTAssertEqual(try mutate(model, operation: .snippetUpsert, value: snippet, workspaceID: workspace), [snippet])
        XCTAssertThrowsError(try mutate(model, operation: .snippetDelete,
                                       value: RemoteIdentifierResult(id: snippet.id), workspaceID: UUID()))
        XCTAssertEqual(model.terminalSnippetStore.snippets, [snippet])
        var missing = snippet
        missing.workspaceID = UUID()
        XCTAssertThrowsError(try mutate(model, operation: .snippetUpsert, value: missing,
                                       workspaceID: missing.workspaceID))
        XCTAssertEqual(try mutate(model, operation: .snippetDelete,
                                  value: RemoteIdentifierResult(id: snippet.id), workspaceID: workspace), [])
    }

    func testCommandRejectsOversizedEntryAndNameWithoutChangingCatalog() throws {
        let model = try makeModel()
        XCTAssertThrowsError(try mutate(model, operation: .snippetUpsert,
            value: TerminalSnippet(title: "Huge", text: String(repeating: "x", count: 65_537))))
        XCTAssertThrowsError(try mutate(model, operation: .snippetUpsert,
            value: TerminalSnippet(title: String(repeating: "x", count: 257), text: "hi")))
        XCTAssertTrue(model.terminalSnippetStore.snippets.isEmpty)
    }
    func testUpsertCannotOverwriteAnotherWorkspacesEntryByRescopingIt() throws {
        let model = try makeModel()
        let originalWorkspace = model.selectedWorkspace.id.rawValue
        let otherWorkspace = try model.store.createWorkspace(title: "Other").rawValue
        let original = TerminalSnippet(title: "Scoped", text: "original", workspaceID: originalWorkspace)
        _ = try mutate(model, operation: .snippetUpsert, value: original, workspaceID: originalWorkspace)
        var changed = original
        changed.workspaceID = otherWorkspace
        changed.text = "replaced"
        XCTAssertThrowsError(try mutate(model, operation: .snippetUpsert, value: changed, workspaceID: otherWorkspace))
        changed.workspaceID = nil
        XCTAssertThrowsError(try mutate(model, operation: .snippetUpsert, value: changed))
        XCTAssertEqual(model.terminalSnippetStore.snippets, [original])
        // Removing scope is allowed only from the workspace that owns the existing entry.
        XCTAssertEqual(try mutate(model, operation: .snippetUpsert, value: changed,
                                  workspaceID: originalWorkspace), [changed])
    }

}
