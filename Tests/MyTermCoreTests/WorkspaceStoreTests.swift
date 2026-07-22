import Foundation
import XCTest
@testable import MyTermCore

final class WorkspaceStoreTests: XCTestCase {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MyTermCoreTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
    }

    func testDefaultWorkspaceIsCreatedAndPersisted() throws {
        let url = temporaryURL()
        let store = try WorkspaceStore(persistenceURL: url)

        XCTAssertEqual(store.workspaces.count, 1)
        XCTAssertEqual(store.selectedWorkspace.tabs.count, 1)
        XCTAssertEqual(store.selectedWorkspace.tabs.first?.isBrowser, false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let persisted = try JSONDecoder().decode(WorkspaceStoreSnapshot.self, from: Data(contentsOf: url))
        XCTAssertEqual(persisted.version, WorkspaceStoreSnapshot.currentVersion)
        XCTAssertEqual(store.globalSettings.cursorShape, .beam)
        XCTAssertEqual(persisted, store.snapshot)
    }

    func testWorkspaceAndTabSelectionIsRepairedAfterRemoval() throws {
        let store = try WorkspaceStore(persistenceURL: temporaryURL())
        let firstWorkspace = store.selectedWorkspaceID
        let secondWorkspace = try store.createWorkspace(title: "Second")
        XCTAssertEqual(store.selectedWorkspaceID, secondWorkspace)

        let secondTab = try store.addBrowserTab(
            to: secondWorkspace,
            url: try XCTUnwrap(URL(string: "https://example.com"))
        )
        let firstTab = try XCTUnwrap(store.workspaces[1].tabs.first?.id)
        try store.selectTab(workspaceID: secondWorkspace, tabID: firstTab)
        try store.closeTab(workspaceID: secondWorkspace, tabID: firstTab)

        XCTAssertEqual(store.workspaces[1].selectedTabID, secondTab)
        try store.removeWorkspace(secondWorkspace)
        XCTAssertEqual(store.selectedWorkspaceID, firstWorkspace)
    }

    func testFoldersPinningAndWorkspaceOrderingPersist() throws {
        let url = temporaryURL()
        let store = try WorkspaceStore(persistenceURL: url)
        let unfiledWorkspaceID = store.selectedWorkspaceID
        let workFolderID = try store.createFolder(title: "Work", color: .teal)
        let firstWorkID = try store.createWorkspace(title: "API", folderID: workFolderID)
        let secondWorkID = try store.createWorkspace(title: "Web", folderID: workFolderID)

        try store.setWorkspacePinned(firstWorkID, isPinned: true)
        try store.setWorkspacePinned(secondWorkID, isPinned: true)
        try store.setWorkspaceEmoji(firstWorkID, emoji: "  🚨  ")
        try store.setWorkspaceColor(firstWorkID, color: .orange)
        try store.moveWorkspace(secondWorkID, to: workFolderID, before: firstWorkID)
        try store.setFolderExpanded(workFolderID, isExpanded: false)

        let restored = try WorkspaceStore(persistenceURL: url)
        XCTAssertEqual(restored.folders, [
            WorkspaceFolder(id: workFolderID, title: "Work", color: .teal, isExpanded: false),
        ])
        XCTAssertEqual(restored.workspaces.map(\.id), [unfiledWorkspaceID, secondWorkID, firstWorkID])
        XCTAssertTrue(try XCTUnwrap(restored.workspaces.first { $0.id == secondWorkID }).isPinned)
        XCTAssertEqual(restored.workspaces.first { $0.id == firstWorkID }?.folderID, workFolderID)
        XCTAssertEqual(restored.workspaces.first { $0.id == firstWorkID }?.emoji, "🚨")
        XCTAssertEqual(restored.workspaces.first { $0.id == firstWorkID }?.color, .orange)

        try restored.setWorkspaceEmoji(firstWorkID, emoji: "  ")
        try restored.setWorkspaceColor(firstWorkID, color: nil)
        let cleared = try WorkspaceStore(persistenceURL: url)
        XCTAssertNil(cleared.workspaces.first { $0.id == firstWorkID }?.emoji)
        XCTAssertNil(cleared.workspaces.first { $0.id == firstWorkID }?.color)
    }

    func testFolderMovesBeforeAndToEndPersistAfterReload() throws {
        let url = temporaryURL()
        let store = try WorkspaceStore(persistenceURL: url)
        let firstID = try store.createFolder(title: "First")
        let secondID = try store.createFolder(title: "Second")
        let thirdID = try store.createFolder(title: "Third")

        try store.moveFolder(thirdID, before: firstID)
        XCTAssertEqual(store.folders.map(\.id), [thirdID, firstID, secondID])

        try store.moveFolder(thirdID, before: nil)
        XCTAssertEqual(store.folders.map(\.id), [firstID, secondID, thirdID])

        let restored = try WorkspaceStore(persistenceURL: url)
        XCTAssertEqual(restored.folders.map(\.id), [firstID, secondID, thirdID])
    }

    func testFolderMoveSelfIsNoOpAndInvalidIDsAreRejected() throws {
        let store = try WorkspaceStore(persistenceURL: temporaryURL())
        let folderID = try store.createFolder(title: "Work")
        let snapshot = store.snapshot
        let missingID = WorkspaceFolderID()

        try store.moveFolder(folderID, before: folderID)
        XCTAssertEqual(store.snapshot, snapshot)
        XCTAssertThrowsError(try store.moveFolder(missingID, before: folderID))
        XCTAssertThrowsError(try store.moveFolder(folderID, before: missingID))
    }

    func testWorkspaceMovesUseDestinationFolderAndPinnedBands() throws {
        let url = temporaryURL()
        let store = try WorkspaceStore(persistenceURL: url)
        let folderID = try store.createFolder(title: "Work")
        let pinnedFirstID = try store.createWorkspace(title: "Pinned First", folderID: folderID)
        let pinnedSecondID = try store.createWorkspace(title: "Pinned Second", folderID: folderID)
        let unpinnedFirstID = try store.createWorkspace(title: "Unpinned First", folderID: folderID)
        let unpinnedSecondID = try store.createWorkspace(title: "Unpinned Second", folderID: folderID)
        try store.setWorkspacePinned(pinnedFirstID, isPinned: true)
        try store.setWorkspacePinned(pinnedSecondID, isPinned: true)

        try store.moveWorkspace(unpinnedSecondID, to: folderID, before: unpinnedFirstID)
        XCTAssertEqual(
            store.workspaces.filter { $0.folderID == folderID && !$0.isPinned }.map(\.id),
            [unpinnedSecondID, unpinnedFirstID]
        )

        try store.moveWorkspace(pinnedSecondID, to: folderID, before: pinnedFirstID)
        XCTAssertEqual(
            store.workspaces.filter { $0.folderID == folderID && $0.isPinned }.map(\.id),
            [pinnedSecondID, pinnedFirstID]
        )

        try store.moveWorkspace(pinnedSecondID, to: folderID, before: nil)
        XCTAssertEqual(
            store.workspaces.filter { $0.folderID == folderID && $0.isPinned }.map(\.id),
            [pinnedFirstID, pinnedSecondID]
        )

        try store.moveWorkspace(unpinnedSecondID, to: folderID, before: nil)
        XCTAssertEqual(
            store.workspaces.filter { $0.folderID == folderID && !$0.isPinned }.map(\.id),
            [unpinnedFirstID, unpinnedSecondID]
        )
        XCTAssertTrue(try XCTUnwrap(store.workspaces.first { $0.id == pinnedFirstID }).isPinned)

        let restored = try WorkspaceStore(persistenceURL: url)
        XCTAssertEqual(
            restored.workspaces.filter { $0.folderID == folderID && $0.isPinned }.map(\.id),
            [pinnedFirstID, pinnedSecondID]
        )
        XCTAssertEqual(
            restored.workspaces.filter { $0.folderID == folderID && !$0.isPinned }.map(\.id),
            [unpinnedFirstID, unpinnedSecondID]
        )
    }

    func testExplicitWorkspaceMoveAppendsWithinCurrentUnfiledBand() throws {
        let store = try WorkspaceStore(persistenceURL: temporaryURL())
        let firstID = store.selectedWorkspaceID
        let secondID = try store.createWorkspace(title: "Second")

        try store.moveWorkspace(firstID, to: nil, before: nil)

        XCTAssertEqual(
            store.workspaces.filter { $0.folderID == nil }.map(\.id),
            [secondID, firstID]
        )
    }

    func testWorkspaceMoveToCurrentFolderWithoutPositionIsNoOp() throws {
        let store = try WorkspaceStore(persistenceURL: temporaryURL())
        let folderID = try store.createFolder(title: "Work")
        let firstID = try store.createWorkspace(title: "First", folderID: folderID)
        let secondID = try store.createWorkspace(title: "Second", folderID: folderID)
        let snapshot = store.snapshot

        try store.moveWorkspace(secondID, to: folderID)

        XCTAssertEqual(store.snapshot, snapshot)
        XCTAssertEqual(store.workspaces.filter { $0.folderID == folderID }.map(\.id), [firstID, secondID])
    }

    func testWorkspaceMovesAcrossFoldersAndIntoEmptyOrUnfiledDestinations() throws {
        let store = try WorkspaceStore(persistenceURL: temporaryURL())
        let initialUnfiledWorkspaceID = store.selectedWorkspaceID
        let firstFolderID = try store.createFolder(title: "First")
        let secondFolderID = try store.createFolder(title: "Second")
        let workspaceID = try store.createWorkspace(title: "Workspace", folderID: firstFolderID)
        let targetID = try store.createWorkspace(title: "Target", folderID: secondFolderID)

        try store.moveWorkspace(workspaceID, to: secondFolderID, before: targetID)
        XCTAssertEqual(store.workspaces.first { $0.id == workspaceID }?.folderID, secondFolderID)
        XCTAssertEqual(
            store.workspaces.filter { $0.folderID == secondFolderID }.map(\.id),
            [workspaceID, targetID]
        )

        try store.moveWorkspace(workspaceID, to: nil, before: nil)
        XCTAssertNil(store.workspaces.first { $0.id == workspaceID }?.folderID)
        XCTAssertEqual(
            store.workspaces.filter { $0.folderID == nil }.map(\.id),
            [initialUnfiledWorkspaceID, workspaceID]
        )

        let emptyFolderID = try store.createFolder(title: "Empty")
        try store.moveWorkspace(workspaceID, to: emptyFolderID, before: nil)
        XCTAssertEqual(store.workspaces.first { $0.id == workspaceID }?.folderID, emptyFolderID)
    }

    func testWorkspaceMoveRejectsInvalidDestinationAndTargetIDs() throws {
        let store = try WorkspaceStore(persistenceURL: temporaryURL())
        let firstFolderID = try store.createFolder(title: "First")
        let secondFolderID = try store.createFolder(title: "Second")
        let workspaceID = try store.createWorkspace(title: "Workspace", folderID: firstFolderID)
        let targetID = try store.createWorkspace(title: "Target", folderID: secondFolderID)
        let pinnedTargetID = try store.createWorkspace(title: "Pinned Target", folderID: firstFolderID)
        try store.setWorkspacePinned(pinnedTargetID, isPinned: true)
        let missingWorkspaceID = WorkspaceID()
        let missingFolderID = WorkspaceFolderID()

        XCTAssertThrowsError(try store.moveWorkspace(workspaceID, to: missingFolderID, before: nil))
        XCTAssertThrowsError(try store.moveWorkspace(missingWorkspaceID, to: firstFolderID, before: nil))
        XCTAssertThrowsError(try store.moveWorkspace(workspaceID, to: firstFolderID, before: missingWorkspaceID))
        XCTAssertThrowsError(try store.moveWorkspace(workspaceID, to: firstFolderID, before: targetID)) { error in
            guard case .invariantViolation(let reason) = error as? WorkspaceStoreError else {
                return XCTFail("Expected an invariant violation, got \(error)")
            }
            XCTAssertTrue(reason.contains("requested destination and pinned band"))
        }
        XCTAssertThrowsError(try store.moveWorkspace(workspaceID, before: pinnedTargetID)) { error in
            guard case .invariantViolation(let reason) = error as? WorkspaceStoreError else {
                return XCTFail("Expected an invariant violation, got \(error)")
            }
            XCTAssertTrue(reason.contains("requested destination and pinned band"))
        }
        try store.moveWorkspace(workspaceID, to: firstFolderID, before: workspaceID)
    }

    func testWorkspaceOffsetMovesUseSiblingPositionsInBothDirectionsAndStayInBand() throws {
        let store = try WorkspaceStore(persistenceURL: temporaryURL())
        let unfiledWorkspaceID = store.selectedWorkspaceID
        let folderID = try store.createFolder(title: "Work")
        let firstID = try store.createWorkspace(title: "First", folderID: folderID)
        let secondID = try store.createWorkspace(title: "Second", folderID: folderID)
        let thirdID = try store.createWorkspace(title: "Third", folderID: folderID)
        let pinnedID = try store.createWorkspace(title: "Pinned", folderID: folderID)
        try store.setWorkspacePinned(pinnedID, isPinned: true)

        try store.moveWorkspace(firstID, offset: 1)
        XCTAssertEqual(
            store.workspaces.map(\.id),
            [unfiledWorkspaceID, secondID, firstID, thirdID, pinnedID]
        )

        try store.moveWorkspace(thirdID, offset: -1)
        XCTAssertEqual(
            store.workspaces.map(\.id),
            [unfiledWorkspaceID, secondID, thirdID, firstID, pinnedID]
        )

        let snapshot = store.snapshot
        try store.moveWorkspace(pinnedID, offset: -1)
        XCTAssertEqual(store.snapshot, snapshot)
    }

    func testRemovingFolderKeepsItsWorkspacesAndMovesThemToUnfiled() throws {
        let store = try WorkspaceStore(persistenceURL: temporaryURL())
        let folderID = try store.createFolder(title: "Personal")
        let workspaceID = try store.createWorkspace(title: "Xylem", folderID: folderID)

        try store.removeFolder(folderID)

        XCTAssertTrue(store.folders.isEmpty)
        XCTAssertNil(store.workspaces.first { $0.id == workspaceID }?.folderID)
    }

    func testLegacySnapshotDefaultsNewWorkspaceOrganizationFields() throws {
        let url = temporaryURL()
        let workspaceID = UUID().uuidString
        let tabID = UUID().uuidString
        let sessionID = UUID().uuidString
        let paneID = UUID().uuidString
        let json = """
        {
          "version": 1,
          "workspaces": [{
            "id": "\(workspaceID)",
            "title": "Legacy",
            "tabs": [{
              "id": "\(tabID)",
              "content": {"type": "terminal", "splitTree": {"type": "terminal", "session": {"id": "\(sessionID)", "paneID": "\(paneID)"}}},
              "focusedTerminalSessionID": "\(sessionID)"
            }],
            "selectedTabID": "\(tabID)"
          }],
          "selectedWorkspaceID": "\(workspaceID)"
        }
        """
        try Data(json.utf8).write(to: url)

        let store = try WorkspaceStore(persistenceURL: url)

        XCTAssertTrue(store.folders.isEmpty)
        XCTAssertNil(store.selectedWorkspace.folderID)
        XCTAssertFalse(store.selectedWorkspace.isPinned)
        XCTAssertNil(store.selectedWorkspace.emoji)
        XCTAssertNil(store.selectedWorkspace.color)
    }

    func testTerminalSplittingClosingAndFocusPersist() throws {
        let url = temporaryURL()
        let store = try WorkspaceStore(persistenceURL: url)
        let workspaceID = store.selectedWorkspaceID
        let tabID = try XCTUnwrap(store.selectedWorkspace.selectedTabID)
        let firstSessionID = try XCTUnwrap(store.selectedWorkspace.selectedTab?.focusedTerminalSessionID)

        let secondSessionID = try store.splitTerminalPane(
            workspaceID: workspaceID,
            tabID: tabID,
            sessionID: firstSessionID,
            orientation: .vertical,
            workingDirectory: URL(fileURLWithPath: "/tmp/myterm")
        )
        try store.focusTerminalPane(workspaceID: workspaceID, tabID: tabID, sessionID: firstSessionID)
        try store.closeTerminalPane(workspaceID: workspaceID, tabID: tabID, sessionID: secondSessionID)

        let restored = try WorkspaceStore(persistenceURL: url)
        let restoredTab = try XCTUnwrap(restored.selectedWorkspace.selectedTab)
        XCTAssertEqual(restoredTab.terminalTree?.terminalSessionIDs, [firstSessionID])
        XCTAssertEqual(restoredTab.focusedTerminalSessionID, firstSessionID)
    }

    func testTerminalWorkingDirectoryUpdatePersistsBySessionAndPane() throws {
        let url = temporaryURL()
        let store = try WorkspaceStore(persistenceURL: url)
        let workspaceID = store.selectedWorkspaceID
        let tabID = try XCTUnwrap(store.selectedWorkspace.selectedTabID)
        let initialSession = try XCTUnwrap(store.selectedWorkspace.selectedTab?.terminalTree?.terminalSessions.first)
        let firstDirectory = URL(fileURLWithPath: "/tmp/myterm-first")
        let secondDirectory = URL(fileURLWithPath: "/tmp/myterm-second")

        try store.updateTerminalWorkingDirectory(
            workspaceID: workspaceID,
            tabID: tabID,
            sessionID: initialSession.id,
            workingDirectory: firstDirectory
        )
        try store.updateTerminalWorkingDirectory(
            workspaceID: workspaceID,
            tabID: tabID,
            paneID: initialSession.paneID,
            workingDirectory: secondDirectory
        )

        let restored = try WorkspaceStore(persistenceURL: url)
        let restoredSession = try XCTUnwrap(
            restored.selectedWorkspace.selectedTab?.terminalTree?.terminalSessions.first
        )
        XCTAssertEqual(restoredSession.id, initialSession.id)
        XCTAssertEqual(restoredSession.paneID, initialSession.paneID)
        XCTAssertEqual(restoredSession.workingDirectory, secondDirectory)
    }

    func testBrowserURLUpdatePersistsAndTerminalTabsRejectIt() throws {
        let url = temporaryURL()
        let store = try WorkspaceStore(persistenceURL: url)
        let workspaceID = store.selectedWorkspaceID
        let browserTabID = try store.addBrowserTab(
            to: workspaceID,
            url: try XCTUnwrap(URL(string: "https://example.com/old"))
        )
        let newURL = try XCTUnwrap(URL(string: "https://example.com/new"))

        try store.updateBrowserURL(workspaceID: workspaceID, tabID: browserTabID, url: newURL)
        let restored = try WorkspaceStore(persistenceURL: url)
        let browserTab = try XCTUnwrap(restored.workspaces[0].tabs.first { $0.id == browserTabID })
        guard case .browser(let session) = browserTab.content else {
            return XCTFail("Expected a browser tab")
        }
        XCTAssertEqual(session.url, newURL)

        let terminalTabID = try XCTUnwrap(restored.workspaces[0].tabs.first { !$0.isBrowser }?.id)
        XCTAssertThrowsError(
            try restored.updateBrowserURL(
                workspaceID: workspaceID,
                tabID: terminalTabID,
                url: newURL
            )
        ) { error in
            XCTAssertEqual(error as? WorkspaceStoreError, .browserTabRequired(terminalTabID))
        }
    }

    func testBrowserDataProfilePersistsAndTerminalTabsRejectUpdates() throws {
        let url = temporaryURL()
        let store = try WorkspaceStore(persistenceURL: url)
        let workspaceID = store.selectedWorkspaceID
        let profile = BrowserDataProfile(
            scope: .projectDirectory,
            persistentStoreID: UUID(),
            projectDirectory: URL(fileURLWithPath: "/tmp/myterm-project")
        )
        let browserTabID = try store.addBrowserTab(
            to: workspaceID,
            url: try XCTUnwrap(URL(string: "https://example.com"))
        )

        try store.updateBrowserDataProfile(
            workspaceID: workspaceID,
            tabID: browserTabID,
            profile: profile
        )

        let restored = try WorkspaceStore(persistenceURL: url)
        let browserTab = try XCTUnwrap(restored.workspaces[0].tabs.first { $0.id == browserTabID })
        guard case .browser(let session) = browserTab.content else {
            return XCTFail("Expected a browser tab")
        }
        XCTAssertEqual(session.profile, profile)

        let terminalTabID = try XCTUnwrap(restored.workspaces[0].tabs.first { !$0.isBrowser }?.id)
        XCTAssertThrowsError(
            try restored.updateBrowserDataProfile(
                workspaceID: workspaceID,
                tabID: terminalTabID,
                profile: profile
            )
        ) { error in
            XCTAssertEqual(error as? WorkspaceStoreError, .browserTabRequired(terminalTabID))
        }
    }

    func testCorruptAndUnsupportedPersistenceIsSurfaced() throws {
        let corruptURL = temporaryURL()
        try Data("not json".utf8).write(to: corruptURL)
        XCTAssertThrowsError(try WorkspaceStore(persistenceURL: corruptURL)) { error in
            guard case .invalidPersistence = error as? WorkspaceStoreError else {
                return XCTFail("Expected invalid persistence, got \(error)")
            }
        }

        let unsupportedURL = temporaryURL()
        let unsupportedJSON = """
        {"version":99,"workspaces":[],"selectedWorkspaceID":"\(UUID().uuidString)"}
        """
        try Data(unsupportedJSON.utf8).write(to: unsupportedURL)
        XCTAssertThrowsError(try WorkspaceStore(persistenceURL: unsupportedURL)) { error in
            XCTAssertEqual(error as? WorkspaceStoreError, .unsupportedVersion(99))
        }
    }

    func testPartiallyCorruptButDecodableStateIsRepaired() throws {
        let url = temporaryURL()
        let workspaceID = UUID().uuidString
        let invalidTabID = UUID().uuidString
        let json = """
        {
          "version": 1,
          "workspaces": [
            {
              "id": "\(workspaceID)",
              "title": "Recovered",
              "tabs": [
                {"id": "\(invalidTabID)", "content": {"type": "unknown"}},
                {"id": "\(UUID().uuidString)", "content": {"type": "browser", "session": {"id": "\(UUID().uuidString)", "url": "https://example.com"}}}
              ],
              "selectedTabID": "\(UUID().uuidString)"
            }
          ],
          "selectedWorkspaceID": "\(UUID().uuidString)"
        }
        """
        try Data(json.utf8).write(to: url)

        let store = try WorkspaceStore(persistenceURL: url)
        XCTAssertEqual(store.workspaces.count, 1)
        XCTAssertEqual(store.workspaces[0].title, "Recovered")
        XCTAssertEqual(store.workspaces[0].tabs.count, 1)
        XCTAssertEqual(store.workspaces[0].selectedTabID, store.workspaces[0].tabs[0].id)
        XCTAssertEqual(store.selectedWorkspaceID, store.workspaces[0].id)
    }

    func testSettingsOverridesClearOnlyTheRequestedFieldAndPersist() throws {
        let url = temporaryURL()
        let store = try WorkspaceStore(persistenceURL: url)
        let workspaceID = store.selectedWorkspaceID
        try store.updateGlobalSettings { $0.fontSize = 13 }
        try store.updateWorkspaceSettings(workspaceID) { $0.fontSize = 18; $0.optionAsMeta = false }
        try store.clearWorkspaceSettingsOverride(workspaceID, \.fontSize)

        XCTAssertEqual(try store.resolvedSettings(for: workspaceID).fontSize, 13)
        XCTAssertFalse(try store.resolvedSettings(for: workspaceID).optionAsMeta)
        XCTAssertEqual(try WorkspaceStore(persistenceURL: url).resolvedSettings(for: workspaceID).fontSize, 13)
    }

    func testFolderAndWorkspaceSettingsOverrideGlobalSettingsInOrder() throws {
        let store = try WorkspaceStore(persistenceURL: temporaryURL())
        let folderID = try store.createFolder(title: "Work")
        let workspaceID = try store.createWorkspace(title: "API", folderID: folderID)
        try store.updateGlobalSettings { $0.fontSize = 11; $0.optionAsMeta = true }
        try store.updateFolderSettings(folderID) { $0.fontSize = 14; $0.optionAsMeta = false }
        try store.updateWorkspaceSettings(workspaceID) { $0.fontSize = 18 }

        let resolved = try store.resolvedSettings(for: workspaceID)
        XCTAssertEqual(resolved.fontSize, 18)
        XCTAssertFalse(resolved.optionAsMeta)
    }

    func testMovingWorkspaceBetweenFoldersChangesResolvedOverrides() throws {
        let store = try WorkspaceStore(persistenceURL: temporaryURL())
        let firstFolderID = try store.createFolder(title: "First")
        let secondFolderID = try store.createFolder(title: "Second")
        let workspaceID = try store.createWorkspace(title: "Workspace", folderID: firstFolderID)
        try store.updateFolderSettings(firstFolderID) { $0.compactSidebar = false }
        try store.updateFolderSettings(secondFolderID) { $0.compactSidebar = true }

        XCTAssertFalse(try store.resolvedSettings(for: workspaceID).compactSidebar)
        try store.moveWorkspace(workspaceID, to: secondFolderID)
        XCTAssertTrue(try store.resolvedSettings(for: workspaceID).compactSidebar)
    }

    func testInvalidGlobalSettingsValuesAreClampedOrDefaulted() throws {
        let workspaceID = UUID().uuidString
        let json = """
        {"version":1,"globalSettings":{"fontSize":999,"scrollbackLines":-1,"terminalTheme":"invalid","terminalAppearance":"invalid","shell":{"type":"custom","path":"   "}},"workspaces":[{"id":"\(workspaceID)","title":"Legacy","tabs":[]}],"selectedWorkspaceID":"\(workspaceID)"}
        """

        let snapshot = try JSONDecoder().decode(WorkspaceStoreSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.globalSettings.fontSize, TerminalPreferences.fontSizeRange.upperBound)
        XCTAssertEqual(snapshot.globalSettings.scrollbackLines, TerminalPreferences.scrollbackLinesRange.lowerBound)
        XCTAssertEqual(snapshot.globalSettings.terminalTheme, .system)
        XCTAssertEqual(snapshot.globalSettings.terminalAppearance, .system)
        XCTAssertEqual(snapshot.globalSettings.shell, .loginShell)
        XCTAssertEqual(snapshot.globalSettings.markdownOpenCommand, TerminalPreferences.defaultMarkdownOpenCommand)
    }

    func testLegacySnapshotDefaultsSettingsOverridesTitlesAndRecentText() throws {
        let url = temporaryURL()
        let workspaceID = UUID().uuidString
        let tabID = UUID().uuidString
        let sessionID = UUID().uuidString
        let paneID = UUID().uuidString
        let json = """
        {"version":1,"workspaces":[{"id":"\(workspaceID)","title":"Legacy","tabs":[{"id":"\(tabID)","content":{"type":"terminal","splitTree":{"type":"terminal","session":{"id":"\(sessionID)","paneID":"\(paneID)"}}},"focusedTerminalSessionID":"\(sessionID)"}],"selectedTabID":"\(tabID)"}],"selectedWorkspaceID":"\(workspaceID)"}
        """
        try Data(json.utf8).write(to: url)

        let store = try WorkspaceStore(persistenceURL: url)
        XCTAssertEqual(store.globalSettings, .default)
        XCTAssertNil(store.selectedWorkspace.settingsOverrides)
        XCTAssertNil(store.selectedWorkspace.selectedTab?.customTitle)
        XCTAssertNil(store.selectedWorkspace.selectedTab?.terminalTree?.terminalSessions.first?.recentText)
    }

    func testClosingFinalTabRemovesWorkspaceAndReturnsReplacement() throws {
        let store = try WorkspaceStore(persistenceURL: temporaryURL())
        let workspaceID = store.selectedWorkspaceID
        let tabID = try XCTUnwrap(store.selectedWorkspace.selectedTabID)
        let change = try store.closeTab(workspaceID: workspaceID, tabID: tabID)

        XCTAssertEqual(change.removedWorkspace?.id, workspaceID)
        XCTAssertNotNil(change.replacementWorkspace)
        XCTAssertEqual(store.workspaces.count, 1)
        XCTAssertEqual(store.selectedWorkspaceID, change.selectedWorkspaceID)
    }

    func testClosingFinalTerminalPaneRemovesWorkspaceAndCreatesReplacement() throws {
        let store = try WorkspaceStore(persistenceURL: temporaryURL())
        let workspaceID = store.selectedWorkspaceID
        let tabID = try XCTUnwrap(store.selectedWorkspace.selectedTabID)
        let sessionID = try XCTUnwrap(store.selectedWorkspace.selectedTab?.focusedTerminalSessionID)

        let change = try store.closeTerminalPane(
            workspaceID: workspaceID,
            tabID: tabID,
            sessionID: sessionID
        )

        XCTAssertEqual(change.removedWorkspace?.id, workspaceID)
        XCTAssertNotNil(change.replacementWorkspace)
        XCTAssertEqual(store.workspaces.count, 1)
    }

    func testClosingLastTabFromOneOfSeveralWorkspacesRepairsSelectionAndPersists() throws {
        let url = temporaryURL()
        let firstTab = Tab.browser(url: try XCTUnwrap(URL(string: "https://first.example")))
        let secondTab = Tab.browser(url: try XCTUnwrap(URL(string: "https://second.example")))
        let firstWorkspace = Workspace(title: "First", tabs: [firstTab], selectedTabID: firstTab.id)
        let secondWorkspace = Workspace(title: "Second", tabs: [secondTab], selectedTabID: secondTab.id)
        let snapshot = WorkspaceStoreSnapshot(
            workspaces: [firstWorkspace, secondWorkspace],
            selectedWorkspaceID: secondWorkspace.id
        )
        try JSONEncoder().encode(snapshot).write(to: url)
        let store = try WorkspaceStore(persistenceURL: url)
        let firstWorkspaceID = firstWorkspace.id
        let secondWorkspaceID = secondWorkspace.id
        let secondTabID = secondTab.id

        let change = try store.closeTab(workspaceID: secondWorkspaceID, tabID: secondTabID)
        XCTAssertEqual(change.removedWorkspace?.id, secondWorkspaceID)
        XCTAssertNil(change.replacementWorkspace)
        XCTAssertEqual(store.selectedWorkspaceID, firstWorkspaceID)

        let restored = try WorkspaceStore(persistenceURL: url)
        XCTAssertEqual(restored.workspaces.map(\.id), [firstWorkspaceID])
        XCTAssertEqual(restored.selectedWorkspaceID, firstWorkspaceID)
    }

    func testTabRenameAndRecentTextPersist() throws {
        let url = temporaryURL()
        let store = try WorkspaceStore(persistenceURL: url)
        let workspaceID = store.selectedWorkspaceID
        let tabID = try XCTUnwrap(store.selectedWorkspace.selectedTabID)
        let sessionID = try XCTUnwrap(store.selectedWorkspace.selectedTab?.focusedTerminalSessionID)
        try store.renameTab(workspaceID: workspaceID, tabID: tabID, customTitle: "Build")
        try store.updateTerminalRecentText(workspaceID: workspaceID, tabID: tabID, sessionID: sessionID, recentText: String(repeating: "x", count: 10_000))

        let restored = try WorkspaceStore(persistenceURL: url)
        XCTAssertEqual(restored.selectedWorkspace.selectedTab?.customTitle, "Build")
        XCTAssertLessThanOrEqual(restored.selectedWorkspace.selectedTab?.terminalTree?.terminalSessions.first?.recentText?.utf8.count ?? 0, TerminalSession.maximumRecentTextBytes)
    }

    func testWhitespaceTabRenameClearsCustomTitle() throws {
        let store = try WorkspaceStore(persistenceURL: temporaryURL())
        let workspaceID = store.selectedWorkspaceID
        let tabID = try XCTUnwrap(store.selectedWorkspace.selectedTabID)
        try store.renameTab(workspaceID: workspaceID, tabID: tabID, customTitle: "Build")
        try store.renameTab(workspaceID: workspaceID, tabID: tabID, customTitle: "  \n ")

        XCTAssertNil(store.selectedWorkspace.selectedTab?.customTitle)
    }

    func testBrowserAndTerminalPanesShareOnePersistentSplitTree() throws {
        let url = temporaryURL()
        let store = try WorkspaceStore(persistenceURL: url)
        let workspaceID = store.selectedWorkspaceID
        let tabID = try XCTUnwrap(store.selectedWorkspace.selectedTabID)
        let terminalPaneID = try XCTUnwrap(store.selectedWorkspace.selectedTab?.focusedPaneID)
        let browserURL = try XCTUnwrap(URL(string: "https://example.com/first"))

        let browserID = try store.insertBrowserPane(
            workspaceID: workspaceID,
            tabID: tabID,
            beside: terminalPaneID,
            url: browserURL
        )
        let browserPaneID = try XCTUnwrap(store.selectedWorkspace.selectedTab?.splitTree.browser(id: browserID)?.paneID)
        XCTAssertEqual(store.selectedWorkspace.tabs.count, 1)
        XCTAssertEqual(store.selectedWorkspace.selectedTab?.splitTree.paneIDs.count, 2)
        XCTAssertEqual(store.selectedWorkspace.selectedTab?.focusedPaneID, browserPaneID)

        let newTerminalPaneID = try store.splitTerminalPane(
            workspaceID: workspaceID,
            tabID: tabID,
            paneID: browserPaneID,
            orientation: .vertical
        )
        XCTAssertEqual(store.selectedWorkspace.selectedTab?.splitTree.paneIDs.count, 3)
        XCTAssertNotNil(store.selectedWorkspace.selectedTab?.splitTree.session(for: newTerminalPaneID))

        let updatedURL = try XCTUnwrap(URL(string: "https://example.com/updated"))
        try store.updateBrowserURL(
            workspaceID: workspaceID,
            tabID: tabID,
            browserID: browserID,
            url: updatedURL
        )
        XCTAssertEqual(store.selectedWorkspace.selectedTab?.splitTree.browser(id: browserID)?.url, updatedURL)

        _ = try store.closePane(workspaceID: workspaceID, tabID: tabID, paneID: browserPaneID)
        XCTAssertEqual(store.selectedWorkspace.selectedTab?.splitTree.paneIDs.count, 2)
        XCTAssertNil(store.selectedWorkspace.selectedTab?.splitTree.browser(id: browserID))

        let restored = try WorkspaceStore(persistenceURL: url)
        XCTAssertEqual(restored.selectedWorkspace.selectedTab?.splitTree.paneIDs.count, 2)
        XCTAssertTrue(restored.selectedWorkspace.selectedTab?.splitTree.browserSessions.isEmpty == true)
    }
}
