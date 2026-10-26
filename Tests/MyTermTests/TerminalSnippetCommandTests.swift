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

    func testSnippetSheetRecreationKeepsOriginalDestinationAfterCompanionClosesItsTab() throws {
        let model = try makeModel()
        model.createTerminalTab()
        let workspaceID = model.selectedWorkspace.id
        let original = try XCTUnwrap(model.selectedTab)
        let groupID = model.selectedWorkspace.focusedTabGroupID
        model.isTerminalSnippetsPresented = true
        let before = TerminalSnippetsView(model: model)
        try model.closeCompanionTab(workspaceID: workspaceID, groupID: groupID, tabID: original.id)
        XCTAssertNotEqual(model.selectedTab?.terminalSession?.id, original.terminalSession?.id,
                          "The closed terminal must have an actual neighboring replacement")
        // SwiftUI may call init again while retaining the sheet's edit state. Exercise the real
        // View initializer after the companion mutation, rather than testing a copied capture.
        let recreated = TerminalSnippetsView(model: model)
        XCTAssertEqual(recreated.destination, before.destination)
        XCTAssertEqual(recreated.destination.sessionID, original.terminalSession?.id)
        XCTAssertThrowsError(try recreated.destination.insert("do not redirect", into: model))
        model.isTerminalSnippetsPresented = false
        model.isTerminalSnippetsPresented = true
        XCTAssertEqual(TerminalSnippetsView(model: model).destination.sessionID, model.selectedTab?.terminalSession?.id,
                       "Only a newly opened sheet captures the current destination")
    }

    func testDesktopAndCompanionWorkspaceClosureRemoveOnlyOwnedSnippets() throws {
        for throughCompanion in [false, true] {
            let model = try makeModel()
            let closed = model.selectedWorkspace.id
            let other = try model.store.createWorkspace(title: "Other")
            let global = TerminalSnippet(title: "Global", text: "global")
            let scoped = TerminalSnippet(title: "Scoped", text: "scoped", workspaceID: closed.rawValue)
            let otherScoped = TerminalSnippet(title: "Other", text: "other", workspaceID: other.rawValue)
            for entry in [global, scoped, otherScoped] { XCTAssertTrue(model.terminalSnippetStore.save(entry)) }
            if throughCompanion {
                _ = try model.performCompanionCommand(
                    metadata: MessageMetadata(hostID: UUID(), workspaceID: closed.rawValue),
                    command: CommandParameters(operation: .workspaceClose,
                        payload: JSONEncoder().encode(RemoteClosePayload())))
            } else {
                model.deleteWorkspace(closed)
            }
            XCTAssertFalse(model.workspaces.contains { $0.id == closed })
            XCTAssertEqual(model.terminalSnippetStore.snippets, [global, otherScoped])
            XCTAssertEqual(model.companionWorkspaceProjection().terminalSnippets, [global, otherScoped])
        }
    }

    func testClosingLastTabViaDesktopAndCompanionCleansOnlyRemovedWorkspaceScope() throws {
        for throughCompanion in [false, true] {
            for hasNeighbor in [false, true] {
                let model = try makeModel()
                let closed = model.selectedWorkspace.id
                let closingTab = try XCTUnwrap(model.selectedTab)
                let groupID = model.selectedWorkspace.focusedTabGroupID
                let global = TerminalSnippet(title: "Global", text: "global")
                let scoped = TerminalSnippet(title: "Closed", text: "closed", workspaceID: closed.rawValue)
                var retained = [global]
                if hasNeighbor {
                    let otherID = try model.store.createWorkspace(title: "Other")
                    retained.append(TerminalSnippet(title: "Other", text: "other", workspaceID: otherID.rawValue))
                }
                for entry in retained + [scoped] { XCTAssertTrue(model.terminalSnippetStore.save(entry)) }
                model.selectWorkspace(closed)
                if throughCompanion {
                    try model.closeCompanionTab(workspaceID: closed, groupID: groupID, tabID: closingTab.id)
                } else {
                    model.closeTab(closingTab.id)
                }
                XCTAssertFalse(model.workspaces.contains { $0.id == closed },
                               "The closed workspace identity must disappear even when it was the final workspace")
                XCTAssertFalse(model.workspaces.isEmpty, "The store replaces the final workspace with a new identity")
                XCTAssertEqual(model.terminalSnippetStore.snippets, retained)
                XCTAssertEqual(model.companionWorkspaceProjection().terminalSnippets, retained)
            }
        }
    }

    func testClosingOneOfSeveralTabsPreservesSurvivingWorkspaceSnippets() throws {
        for throughCompanion in [false, true] {
            let model = try makeModel()
            let workspaceID = model.selectedWorkspace.id
            model.createTerminalTab()
            let closingTab = try XCTUnwrap(model.selectedTab)
            let groupID = model.selectedWorkspace.focusedTabGroupID
            let scoped = TerminalSnippet(title: "Kept", text: "kept", workspaceID: workspaceID.rawValue)
            XCTAssertTrue(model.terminalSnippetStore.save(scoped))
            if throughCompanion {
                try model.closeCompanionTab(workspaceID: workspaceID, groupID: groupID, tabID: closingTab.id)
            } else {
                model.closeTab(closingTab.id)
            }
            XCTAssertTrue(model.workspaces.contains { $0.id == workspaceID })
            XCTAssertEqual(model.terminalSnippetStore.snippets, [scoped])
        }
    }

}
