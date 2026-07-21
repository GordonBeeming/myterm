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
}
