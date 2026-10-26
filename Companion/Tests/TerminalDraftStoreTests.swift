import Foundation
import MyTermCore
import MyTermRemote
import XCTest
@testable import MyTermCompanion

@MainActor
final class TerminalDraftStoreTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "TerminalDraftStoreTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return defaults
    }

    private func route(connection: SavedConnectionID? = nil, workspace: UUID = UUID(),
                       session: UUID = UUID()) -> TerminalRoute {
        TerminalRoute(connectionID: connection ?? SavedConnectionID(
            relayOrigin: "https://relay.example", accountID: UUID(), hostID: UUID()),
            workspaceID: workspace, groupID: UUID(), tabID: UUID(), sessionID: session, title: "Test")
    }

    func testDraftRestoresAcrossStoreRelaunchAndNeverReplaysAnInterruptedInsertion() {
        let defaults = defaults()
        let route = route()
        // Retain the store: its callback owns persistence, not the scene or editor.
        let first = TerminalDraftStore(defaults: defaults)
        let persisted = first.draft(for: route)
        persisted.text = "Please inspect this 👋\nthen explain"
        persisted.beginInsertion()

        let restored = TerminalDraftStore(defaults: defaults).draft(for: route)
        XCTAssertEqual(restored.text, persisted.text)
        XCTAssertEqual(restored.insertionOutcome, .unconfirmed)
        XCTAssertFalse(restored.isSending)
    }

    func testDraftScopeIncludesPairingWorkspaceAndSessionAndForgetOnlyClearsThatPairing() {
        let store = TerminalDraftStore(defaults: defaults())
        let original = route()
        store.draft(for: original).text = "original"
        let anotherWorkspace = route(connection: original.connectionID, session: original.sessionID)
        XCTAssertEqual(store.draft(for: anotherWorkspace).text, "")
        let anotherSession = route(connection: original.connectionID, workspace: original.workspaceID)
        XCTAssertEqual(store.draft(for: anotherSession).text, "")
        let anotherPairing = route(workspace: original.workspaceID, session: original.sessionID)
        store.draft(for: anotherPairing).text = "other pairing"
        let retained = store.draft(for: original)
        store.forget(original.connectionID)
        XCTAssertEqual(retained.text, "")
        retained.text = "stale editor must not restore forgotten draft"
        XCTAssertEqual(store.draft(for: original).text, "")
        XCTAssertEqual(store.draft(for: anotherPairing).text, "other pairing")
    }

    func testTransportSuccessAndFailureKeepDraftAndDescribeOnlyKnownOutcome() {
        let draft = TerminalComposerDraft(text: "echo hello")
        draft.beginInsertion()
        draft.finishInsertion(error: nil)
        XCTAssertEqual(draft.insertionOutcome, .transportSent)
        XCTAssertEqual(draft.text, "echo hello")
        draft.beginInsertion()
        draft.finishInsertion(error: RemoteError.disconnected)
        XCTAssertEqual(draft.insertionOutcome, .unconfirmed)
        XCTAssertFalse(draft.isSending)
        XCTAssertEqual(draft.text, "echo hello")
        draft.beginInsertion()
        draft.finishInsertion(error: TerminalComposerError.requiresControl)
        XCTAssertEqual(draft.insertionOutcome, .notInserted)
    }

    func testSharedSnippetCatalogRoundTripsAndOlderHostIsRecognised() throws {
        let oldProjection = Data(#"{"folders":[],"workspaces":[]}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(RemoteWorkspaceProjection.self, from: oldProjection).terminalSnippets)
        let snippet = TerminalSnippet(title: "Inspect", text: "inspect\nthen report 👋", kind: .command,
                                      workspaceID: UUID())
        let projection = RemoteWorkspaceProjection(folders: [], workspaces: [], terminalSnippets: [snippet])
        let decoded = try JSONDecoder().decode(RemoteWorkspaceProjection.self,
                                               from: JSONEncoder().encode(projection))
        XCTAssertEqual(decoded.terminalSnippets, [snippet])
    }
    func testCreatingAnotherSnippetRotatesIdentityOnlyAfterConfirmedSave() {
        var creation = TerminalSnippetCreationState()
        let firstID = creation.id
        // No acknowledgement (including a timeout) leaves the retry targeting the same entry.
        XCTAssertEqual(creation.id, firstID)
        creation.didConfirmSave(of: UUID())
        XCTAssertEqual(creation.id, firstID)
        creation.didConfirmSave(of: firstID)
        let secondID = creation.id
        XCTAssertNotEqual(secondID, firstID)
        // A late acknowledgement for the first entry cannot change the next entry's identity.
        creation.didConfirmSave(of: firstID)
        XCTAssertEqual(creation.id, secondID)
        creation.didConfirmSave(of: secondID)
        XCTAssertNotEqual(creation.id, secondID)
    }

    func testUnbracketedMultilinePasteIsRejectedBeforeAnyInputIsBuilt() throws {
        for text in ["one\ntwo", "one\rtwo", "one\r\ntwo"] {
            for appendReturn in [false, true] {
                XCTAssertThrowsError(try TerminalComposerDraft.pasteBytes(text, bracketed: false,
                                                                         appendReturn: appendReturn)) { error in
                    guard case TerminalComposerError.multilineRequiresBracketedPaste = error else {
                        return XCTFail("Unexpected error: \(error)")
                    }
                }
            }
        }
        XCTAssertEqual(try TerminalComposerDraft.pasteBytes("echo safe", bracketed: false,
                                                           appendReturn: false), Data("echo safe".utf8))
    }

    func testCapacityKeepsNewDraftInMemoryWithWarningAndPreservesExistingDrafts() {
        let defaults = defaults()
        let store = TerminalDraftStore(defaults: defaults)
        var routes: [TerminalRoute] = []
        for index in 0..<TerminalDraftStore.maximumEntries {
            let route = route()
            routes.append(route)
            store.draft(for: route).text = "Saved \(index)"
        }
        let extraRoute = route()
        let extra = store.draft(for: extraRoute)
        extra.text = "Not yet saved"
        XCTAssertNotNil(extra.persistenceErrorMessage)
        XCTAssertEqual(extra.text, "Not yet saved")
        XCTAssertEqual(TerminalDraftStore(defaults: defaults).draft(for: extraRoute).text, "")
        let first = store.draft(for: routes[0])
        first.text = "Updated existing"
        XCTAssertNil(first.persistenceErrorMessage)
        XCTAssertEqual(TerminalDraftStore(defaults: defaults).draft(for: routes[0]).text, "Updated existing")
        first.text = ""
        extra.text += " now saved"
        XCTAssertNil(extra.persistenceErrorMessage)
        XCTAssertEqual(TerminalDraftStore(defaults: defaults).draft(for: extraRoute).text, extra.text)
    }

    func testAuthoritativePruningOnlyRemovesClosedCurrentHostDraftsAndKeepsPendingInsertion() {
        let defaults = defaults()
        let store = TerminalDraftStore(defaults: defaults)
        let closed = route()
        let pending = route(connection: closed.connectionID)
        let live = route(connection: closed.connectionID)
        let uncertain = route(connection: closed.connectionID)
        let otherHost = route()
        store.draft(for: closed).text = "Closed terminal"
        store.draft(for: live).text = "Live terminal"
        let pendingDraft = store.draft(for: pending)
        pendingDraft.text = "Still sending"
        pendingDraft.beginInsertion()
        let uncertainDraft = store.draft(for: uncertain)
        uncertainDraft.text = "Unconfirmed"
        uncertainDraft.beginInsertion()
        uncertainDraft.finishInsertion(error: RemoteError.disconnected)
        store.draft(for: otherHost).text = "Offline other Mac"
        let projection = RemoteWorkspaceProjection(folders: [], workspaces: [RemoteWorkspaceItem(
            id: WorkspaceID(rawValue: live.workspaceID), title: "Live", folderID: nil,
            isPinned: false, color: nil, emoji: nil, groups: [RemoteTabGroupProjection(
                id: TabGroupID(rawValue: live.groupID), tabs: [RemoteTabProjection(
                    id: TabID(rawValue: live.tabID), title: "Terminal", kind: .terminal,
                    terminalSessionID: TerminalSessionID(rawValue: live.sessionID))])])])
        store.pruneClosedTerminals(for: closed.connectionID, projection: projection)
        let reopened = TerminalDraftStore(defaults: defaults)
        XCTAssertEqual(reopened.draft(for: closed).text, "")
        XCTAssertEqual(reopened.draft(for: live).text, "Live terminal")
        XCTAssertEqual(reopened.draft(for: pending).text, "Still sending")
        XCTAssertEqual(reopened.draft(for: uncertain).text, "Unconfirmed")
        XCTAssertEqual(reopened.draft(for: otherHost).text, "Offline other Mac")
    }

    func testOversizedEditsWarnWithoutReplacingPreviouslySavedText() {
        let defaults = defaults()
        let store = TerminalDraftStore(defaults: defaults)
        let route = route()
        let draft = store.draft(for: route)
        draft.text = "Saved text"
        draft.text = String(repeating: "x", count: TerminalComposerDraft.maximumUTF8Bytes + 1)
        XCTAssertNotNil(draft.persistenceErrorMessage)
        XCTAssertEqual(TerminalDraftStore(defaults: defaults).draft(for: route).text, "Saved text")
        draft.text = "Shortened"
        XCTAssertNil(draft.persistenceErrorMessage)
        XCTAssertEqual(TerminalDraftStore(defaults: defaults).draft(for: route).text, "Shortened")
    }

}
