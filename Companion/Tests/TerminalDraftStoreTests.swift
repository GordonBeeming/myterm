import Foundation
import MyTermCore
import MyTermRemote
import XCTest
@testable import MyTermCompanion

private final class DraftRecordingDefaults: UserDefaults, @unchecked Sendable {
    private let recordedLock = NSLock()
    private var recordedWrites: [(String, Int?)] = []

    override func set(_ value: Any?, forKey defaultName: String) {
        recordedLock.withLock { recordedWrites.append((defaultName, (value as? Data)?.count)) }
        super.set(value, forKey: defaultName)
    }

    func takeWrites() -> [(String, Int?)] {
        recordedLock.withLock {
            defer { recordedWrites.removeAll() }
            return recordedWrites
        }
    }
}

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
        XCTAssertTrue(draft.beginInsertion(allowRepeat: true))
        draft.finishInsertion(error: RemoteError.disconnected)
        XCTAssertEqual(draft.insertionOutcome, .unconfirmed)
        XCTAssertFalse(draft.isSending)
        XCTAssertEqual(draft.text, "echo hello")
        XCTAssertTrue(draft.beginInsertion(allowRepeat: true))
        draft.finishInsertion(error: TerminalComposerError.requiresControl)
        XCTAssertEqual(draft.insertionOutcome, .unconfirmed, "A local refusal cannot erase the earlier uncertain send")
    }

    func testCompletedInsertionCannotBeStartedAgainByRepeatedTaps() {
        let draft = TerminalComposerDraft(text: "Please inspect this")
        draft.beginInsertion()
        draft.finishInsertion(error: nil)
        for _ in 0..<24 { draft.beginInsertion() }
        XCTAssertFalse(draft.isSending, "An unchanged sent draft must require an explicit repeat action")
        XCTAssertEqual(draft.insertionOutcome, .transportSent)
    }

    func testUnconfirmedInsertionCannotBeStartedAgainByRepeatedTaps() {
        let draft = TerminalComposerDraft(text: "Please inspect this")
        draft.beginInsertion()
        draft.finishInsertion(error: RemoteError.disconnected)
        for _ in 0..<24 { draft.beginInsertion() }
        XCTAssertFalse(draft.isSending, "An uncertain send may already have reached the terminal")
        XCTAssertEqual(draft.insertionOutcome, .unconfirmed)
    }

    func testBothInsertionButtonsShareOneSynchronousGateEvenAfterTransportFinishes() throws {
        let draft = TerminalComposerDraft(text: "Please inspect this")
        var writes: [Data] = []
        for index in 0..<24 {
            guard draft.beginInsertion() else { continue }
            writes.append(try TerminalComposerDraft.pasteBytes(draft.text, bracketed: true,
                                                               appendReturn: index.isMultiple(of: 2)))
            // Even an immediate successful write must not rearm the buttons.
            draft.finishInsertion(error: nil)
        }
        XCTAssertEqual(writes.count, 1)
        XCTAssertTrue(draft.requiresRepeatConfirmation)
        XCTAssertTrue(draft.beginInsertion(allowRepeat: true))
        XCTAssertFalse(draft.beginInsertion(allowRepeat: true), "Confirmation cannot bypass an in-flight write")
        draft.finishInsertion(error: nil)
        XCTAssertFalse(draft.beginInsertion())
    }

    func testProtectedDraftRemainsProtectedAcrossRelaunchUntilEdited() {
        let defaults = defaults()
        let route = route()
        let store = TerminalDraftStore(defaults: defaults)
        let draft = store.draft(for: route)
        XCTAssertFalse(draft.beginInsertion(), "Empty drafts cannot send")
        draft.text = "first message"
        XCTAssertTrue(draft.beginInsertion())
        draft.finishInsertion(error: nil)
        let reopenedStore = TerminalDraftStore(defaults: defaults)
        let reopened = reopenedStore.draft(for: route)
        XCTAssertFalse(reopened.beginInsertion())
        reopened.text = "first message"
        XCTAssertFalse(reopened.beginInsertion(), "Selecting the same saved prompt must keep the protection")
        reopened.text = "next message"
        XCTAssertNil(reopened.currentInsertionOutcome)
        let thirdStore = TerminalDraftStore(defaults: defaults)
        let restoredEdit = thirdStore.draft(for: route)
        XCTAssertNil(restoredEdit.currentInsertionOutcome)
        restoredEdit.text = "first message"
        XCTAssertFalse(restoredEdit.beginInsertion(), "The sent text fingerprint must survive edits and relaunch")
        reopened.text = "first message"
        XCTAssertFalse(reopened.beginInsertion(), "Undoing an edit must not rearm the same message")
        reopened.text = "next message"
        XCTAssertTrue(reopened.beginInsertion())
    }

    func testInterruptedInsertionRequiresConfirmationButKnownLocalFailureCanRetry() {
        let interrupted = TerminalComposerDraft(text: "message", insertionOutcome: .sending)
        XCTAssertFalse(interrupted.beginInsertion())
        XCTAssertTrue(interrupted.beginInsertion(allowRepeat: true))
        interrupted.finishInsertion(error: TerminalComposerError.requiresControl)
        XCTAssertEqual(interrupted.insertionOutcome, .unconfirmed)
        XCTAssertFalse(interrupted.beginInsertion())
        let unsent = TerminalComposerDraft(text: "not sent yet")
        XCTAssertTrue(unsent.beginInsertion())
        unsent.finishInsertion(error: TerminalComposerError.requiresControl)
        XCTAssertEqual(unsent.insertionOutcome, .notInserted)
        XCTAssertTrue(unsent.beginInsertion())
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

    func testLegacyMigrationRestoresScopedDraftsAndInterruptedOutcomeWithoutKeepingWholeBlob() throws {
        let defaults = defaults()
        let first = route()
        let second = route(connection: first.connectionID)
        func key(_ route: TerminalRoute) -> String {
            "\(route.connectionID.storageKey)|\(route.workspaceID)|\(route.sessionID)"
        }
        let legacy = [key(first): ["text": "Interrupted legacy draft", "outcome": "sending"],
                      key(second): ["text": "Other destination"]]
        defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: "companionTerminalDrafts.v1")
        let migrated = TerminalDraftStore(defaults: defaults)
        XCTAssertEqual(migrated.draft(for: first).text, "Interrupted legacy draft")
        XCTAssertEqual(migrated.draft(for: first).insertionOutcome, .unconfirmed)
        XCTAssertEqual(migrated.draft(for: second).text, "Other destination")
        XCTAssertNil(defaults.data(forKey: "companionTerminalDrafts.v1"))
        let reopened = TerminalDraftStore(defaults: defaults)
        XCTAssertEqual(reopened.draft(for: first).insertionOutcome, .unconfirmed)
        XCTAssertFalse(reopened.draft(for: first).isSending)
        XCTAssertEqual(reopened.draft(for: second).text, "Other destination")
    }

    func testTypingOnlyWritesTheChangedEntryAndImmediatelyRestoresLatestTextAndOutcomes() throws {
        let name = "TerminalDraftStoreWrites.\(UUID())"
        let defaults = try XCTUnwrap(DraftRecordingDefaults(suiteName: name))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        let store = TerminalDraftStore(defaults: defaults)
        let edited = route()
        store.draft(for: edited).text = "before"
        for _ in 1..<TerminalDraftStore.maximumEntries {
            store.draft(for: route()).text = String(repeating: "x", count: TerminalComposerDraft.maximumUTF8Bytes)
        }
        _ = defaults.takeWrites()
        let draft = store.draft(for: edited)
        draft.text = "latest keystroke"
        let writes = defaults.takeWrites()
        XCTAssertEqual(writes.count, 1, "Typing must not rewrite the index or any other draft")
        XCTAssertLessThan(try XCTUnwrap(writes.compactMap { $0.1 }.first), 1_024,
                          "A small edit must not encode the other megabytes of saved text")
        XCTAssertEqual(TerminalDraftStore(defaults: defaults).draft(for: edited).text, "latest keystroke")
        draft.text = "latest keystroke"
        XCTAssertTrue(defaults.takeWrites().isEmpty, "Unchanged values should not create persistence work")
        draft.beginInsertion()
        XCTAssertEqual(TerminalDraftStore(defaults: defaults).draft(for: edited).insertionOutcome, .unconfirmed)
        draft.finishInsertion(error: nil)
        XCTAssertEqual(TerminalDraftStore(defaults: defaults).draft(for: edited).insertionOutcome, .transportSent)
    }

    func testEquivalentLineEndingsCannotBypassRepeatProtection() {
        let draft = TerminalComposerDraft(text: "first\r\nsecond\rthird")
        XCTAssertTrue(draft.beginInsertion())
        draft.finishInsertion(error: nil)
        draft.text = "first\nsecond\nthird"
        XCTAssertFalse(draft.beginInsertion(), "These drafts insert identical bytes")
    }

    func testRepeatConfirmationCannotSendTextEditedInAnotherScene() {
        let draft = TerminalComposerDraft(text: "confirmed text")
        let confirmed = draft.text
        draft.text = "changed in another scene"
        XCTAssertFalse(draft.beginInsertion(allowRepeat: true, expectedText: confirmed))
        XCTAssertFalse(draft.isSending)
    }

    func testFailedEditedDraftPreservesSentProtectionAfterUndoAndRelaunch() throws {
        let defaults = defaults()
        let route = route()
        let store = TerminalDraftStore(defaults: defaults)
        let draft = store.draft(for: route)
        draft.text = "already sent"
        XCTAssertTrue(draft.beginInsertion())
        draft.finishInsertion(error: nil)
        draft.text = "invalid\nmultiline"
        XCTAssertTrue(draft.beginInsertion())
        do {
            _ = try TerminalComposerDraft.pasteBytes(draft.text, bracketed: false, appendReturn: true)
            XCTFail("Multiline insertion must fail without writing")
        } catch { draft.finishInsertion(error: error) }
        let reopenedStore = TerminalDraftStore(defaults: defaults)
        let reopened = reopenedStore.draft(for: route)
        reopened.text = "already sent"
        XCTAssertFalse(reopened.beginInsertion(), "Undo must not duplicate the earlier delivered message")
    }

    func testRefusedExplicitRepeatPreservesTheEarlierSentProtection() {
        let draft = TerminalComposerDraft(text: "already sent")
        XCTAssertTrue(draft.beginInsertion())
        draft.finishInsertion(error: nil)
        draft.onChange = { [weak draft] _, _, _ in draft?.persistenceErrorMessage = "Cannot save" }
        XCTAssertFalse(draft.beginInsertion(allowRepeat: true))
        XCTAssertEqual(draft.insertionOutcome, .transportSent)
        XCTAssertTrue(draft.requiresRepeatConfirmation)
        draft.onChange = nil
        draft.persistenceErrorMessage = nil
        XCTAssertFalse(draft.beginInsertion())
    }

    func testFullDraftCatalogBlocksSendingUntilTheProtectionCanBeSaved() {
        let defaults = defaults()
        let store = TerminalDraftStore(defaults: defaults)
        let firstRoute = route()
        store.draft(for: firstRoute).text = "Saved"
        for _ in 1..<TerminalDraftStore.maximumEntries {
            store.draft(for: route()).text = "Saved"
        }
        let overflowRoute = route()
        let overflow = store.draft(for: overflowRoute)
        overflow.text = "Do not send without a durable marker"
        XCTAssertFalse(overflow.beginInsertion())
        XCTAssertFalse(overflow.isSending)
        XCTAssertNotNil(overflow.persistenceErrorMessage)
        XCTAssertNotNil(overflow.errorMessage)
        store.draft(for: firstRoute).text = ""
        overflow.text += " reviewed"
        XCTAssertTrue(overflow.beginInsertion())
        overflow.finishInsertion(error: nil)
        let restored = TerminalDraftStore(defaults: defaults).draft(for: overflowRoute)
        XCTAssertTrue(restored.requiresRepeatConfirmation)
    }

    func testInterruptedMigrationKeepsNewerIndexedEntriesAndRecoversOtherLegacyDestinations() throws {
        let defaults = defaults()
        let current = route()
        let missing = route(connection: current.connectionID)
        let original = TerminalDraftStore(defaults: defaults)
        original.draft(for: current).text = "Newer v2 text"
        func key(_ route: TerminalRoute) -> String {
            "\(route.connectionID.storageKey)|\(route.workspaceID)|\(route.sessionID)"
        }
        let legacy = [key(current): ["text": "Older v1 text"], key(missing): ["text": "Unmigrated legacy text"]]
        defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: "companionTerminalDrafts.v1")
        let recovered = TerminalDraftStore(defaults: defaults)
        XCTAssertEqual(recovered.draft(for: current).text, "Newer v2 text")
        XCTAssertEqual(recovered.draft(for: missing).text, "Unmigrated legacy text")
        XCTAssertNil(defaults.data(forKey: "companionTerminalDrafts.v1"))
    }

}
