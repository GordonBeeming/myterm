import Foundation
import XCTest
@testable import MyTermCore

/// The store at the sizes and values a busy user, an agent, or a hostile terminal can push it to.
final class WorkspaceStoreStressTests: XCTestCase {
    private func temporaryURL() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyTermCoreStressTests", isDirectory: true)
        XCTAssertNoThrow(try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true))
        return directory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
    }

    /// 500 workspaces spread over 50 folders, every workspace holding one terminal tab.
    private func makeLargeStore(allPinned: Bool = false) throws -> WorkspaceStore {
        let folders = (0..<50).map { WorkspaceFolder(title: "Folder \($0)") }
        let workspaces = (0..<500).map { index in
            Workspace(
                title: "Workspace \(index)",
                folderID: folders[index % folders.count].id,
                isPinned: allPinned
            )
        }
        let snapshot = WorkspaceStoreSnapshot(
            folders: folders,
            workspaces: workspaces,
            selectedWorkspaceID: workspaces[0].id
        )
        let url = temporaryURL()
        try JSONEncoder().encode(snapshot).write(to: url)
        return try WorkspaceStore(persistenceURL: url)
    }

    private func firstTerminal(in store: WorkspaceStore) throws -> (WorkspaceID, TabGroupID, TabID) {
        let workspace = store.selectedWorkspace
        let group = try XCTUnwrap(workspace.focusedTabGroup)
        let tab = try XCTUnwrap(group.tabs.first)
        return (workspace.id, group.id, tab.id)
    }

    // MARK: - Counts

    func testFiveHundredWorkspacesLoadAndRoundTrip() throws {
        let store = try makeLargeStore()
        XCTAssertEqual(store.workspaces.count, 500)
        XCTAssertEqual(store.folders.count, 50)

        try store.flush()
        let reloaded = try WorkspaceStore(persistenceURL: store.persistenceURL)
        XCTAssertEqual(reloaded.workspaces.map(\.id), store.workspaces.map(\.id))
        XCTAssertEqual(reloaded.folders.map(\.id), store.folders.map(\.id))
    }

    /// A burst of mutations costs one encode of the whole snapshot, not one per change. An agent
    /// that retitles its conversation is the fastest writer the store has, so it is the burst
    /// that matters. The proof is what the file holds, not a stopwatch: nothing during the burst,
    /// the last title after the flush.
    func testABurstOfTitleWritesReachesTheFileOnceAtTheFlush() throws {
        let store = try makeLargeStore()
        let (workspaceID, groupID, tabID) = try firstTerminal(in: store)
        try store.updateTerminalAgentTitle(
            workspaceID: workspaceID, tabGroupID: groupID, tabID: tabID, agentTitle: "Before the burst"
        )
        try store.flush()
        XCTAssertFalse(store.hasUnsavedChanges)

        let iterations = 20
        let clock = ContinuousClock()
        let elapsed = try clock.measure {
            for index in 0..<iterations {
                try store.updateTerminalAgentTitle(
                    workspaceID: workspaceID,
                    tabGroupID: groupID,
                    tabID: tabID,
                    agentTitle: "Title \(index)"
                )
            }
        }
        // No write happened during the burst: the file still holds the title from before it.
        XCTAssertTrue(store.hasUnsavedChanges)
        XCTAssertEqual(titleOnDisk(store), "Before the burst")
        // A blocking detector only. Per write the burst costs a copy and a repair of the
        // snapshot, well under a millisecond, but a shared debug CI runner is noisy, so the bound
        // is loose enough that only a write per mutation (about 7 ms each) could trip it.
        XCTAssertLessThan(
            elapsed / iterations,
            .milliseconds(100),
            "One agent-title mutation on a 500-workspace store took \(elapsed / iterations); is it writing the file again?"
        )

        // The one write the run loop would make after the burst.
        try store.flush()
        XCTAssertFalse(store.hasUnsavedChanges)
        XCTAssertEqual(titleOnDisk(store), "Title \(iterations - 1)")
    }

    private func titleOnDisk(_ store: WorkspaceStore) -> String? {
        (try? WorkspaceStore(persistenceURL: store.persistenceURL))?.selectedWorkspace.selectedTab?.terminalSession?.agentTitle
    }

    func testOneHundredTabsInOnePaneGroupMoveAndPersist() throws {
        let url = temporaryURL()
        let store = try WorkspaceStore(persistenceURL: url)
        let workspaceID = store.selectedWorkspaceID
        let groupID = store.selectedWorkspace.focusedTabGroupID
        for _ in 0..<99 {
            _ = try store.addTerminalTab(to: workspaceID, tabGroupID: groupID, workingDirectory: nil)
        }
        let group = try XCTUnwrap(store.selectedWorkspace.group(id: groupID))
        XCTAssertEqual(group.tabs.count, 100)

        let last = try XCTUnwrap(group.tabs.last)
        try store.moveTab(
            workspaceID: workspaceID,
            sourceTabGroupID: groupID,
            tabID: last.id,
            to: groupID,
            at: 0
        )
        XCTAssertEqual(store.selectedWorkspace.group(id: groupID)?.tabs.first?.id, last.id)

        try store.flush()
        let reloaded = try WorkspaceStore(persistenceURL: url)
        XCTAssertEqual(reloaded.selectedWorkspace.group(id: groupID)?.tabs.count, 100)
        XCTAssertEqual(reloaded.selectedWorkspace.group(id: groupID)?.tabs.first?.id, last.id)
    }

    func testTwentyPaneGroupsSplitAndPersist() throws {
        let url = temporaryURL()
        let store = try WorkspaceStore(persistenceURL: url)
        let workspaceID = store.selectedWorkspaceID
        var groupID = store.selectedWorkspace.focusedTabGroupID
        for index in 0..<19 {
            let result = try store.splitTabGroup(
                workspaceID: workspaceID,
                tabGroupID: groupID,
                edge: index.isMultiple(of: 2) ? .right : .bottom
            )
            groupID = result.tabGroupID
        }
        XCTAssertEqual(store.selectedWorkspace.orderedGroups.count, 20)

        try store.flush()
        let reloaded = try WorkspaceStore(persistenceURL: url)
        XCTAssertEqual(reloaded.selectedWorkspace.orderedGroups.count, 20)
        XCTAssertEqual(
            reloaded.selectedWorkspace.orderedGroups.map(\.id),
            store.selectedWorkspace.orderedGroups.map(\.id)
        )
    }

    func testEveryWorkspacePinnedStillReordersWithinTheBand() throws {
        let store = try makeLargeStore(allPinned: true)
        XCTAssertTrue(store.workspaces.allSatisfy(\.isPinned))

        let folderID = try XCTUnwrap(store.folders.first?.id)
        let band = store.workspaces.filter { $0.folderID == folderID }
        XCTAssertEqual(band.count, 10)
        let first = try XCTUnwrap(band.first)
        try store.moveWorkspace(first.id, to: folderID, before: nil, isPinned: true)
        XCTAssertEqual(store.workspaces.filter { $0.folderID == folderID }.last?.id, first.id)
    }

    // MARK: - Titles

    func testTenThousandCharacterTitleRoundTripsThroughTheStore() throws {
        let url = temporaryURL()
        let store = try WorkspaceStore(persistenceURL: url)
        let title = String(repeating: "x", count: 10_000)
        try store.renameWorkspace(store.selectedWorkspaceID, title: title)
        try store.flush()
        let reloaded = try WorkspaceStore(persistenceURL: url)
        XCTAssertEqual(reloaded.selectedWorkspace.title.count, 10_000)
    }

    func testEmojiOnlyAndNewlineOnlyWorkspaceTitlesArePersistedVerbatimByTheStore() throws {
        // The store is a dumb persistence layer; trimming is the app's job. Pin that division so a
        // future "helpful" trim in the store cannot silently change what a device or import wrote.
        let url = temporaryURL()
        let store = try WorkspaceStore(persistenceURL: url)
        // Each title is read back through a fresh load, so the round trip through JSON is what
        // is asserted, not the in-memory value the rename just wrote.
        try store.renameWorkspace(store.selectedWorkspaceID, title: "🚀🎉")
        try store.flush()
        XCTAssertEqual(try WorkspaceStore(persistenceURL: url).selectedWorkspace.title, "🚀🎉")
        try store.renameWorkspace(store.selectedWorkspaceID, title: "\n\n")
        try store.flush()
        XCTAssertEqual(try WorkspaceStore(persistenceURL: url).selectedWorkspace.title, "\n\n")
        try store.renameWorkspace(store.selectedWorkspaceID, title: "")
        try store.flush()
        XCTAssertEqual(try WorkspaceStore(persistenceURL: url).selectedWorkspace.title, "")
    }

    // MARK: - Settings round trips

    func testExtremeFontSizesClampOnTheWayIntoGlobalSettings() throws {
        let url = temporaryURL()
        let store = try WorkspaceStore(persistenceURL: url)
        for (input, expected) in [
            (0.0, TerminalPreferences.fontSizeRange.lowerBound),
            (-5.0, TerminalPreferences.fontSizeRange.lowerBound),
            (1_000.0, TerminalPreferences.fontSizeRange.upperBound),
            (Double.nan, TerminalPreferences.defaultFontSize),
            (Double.infinity, TerminalPreferences.defaultFontSize),
        ] {
            try store.updateGlobalSettings { $0.fontSize = input }
            XCTAssertEqual(store.globalSettings.fontSize, expected, "fontSize \(input)")
            try store.flush()
            let reloaded = try WorkspaceStore(persistenceURL: url)
            XCTAssertEqual(reloaded.globalSettings.fontSize, expected, "fontSize \(input) after reload")
        }
    }

    func testExtremeScrollbackClampsOnTheWayIntoGlobalSettings() throws {
        let url = temporaryURL()
        let store = try WorkspaceStore(persistenceURL: url)
        for (input, expected) in [
            (0, TerminalPreferences.scrollbackLinesRange.lowerBound),
            (-1, TerminalPreferences.scrollbackLinesRange.lowerBound),
            (10_000_000, TerminalPreferences.scrollbackLinesRange.upperBound),
            (Int.max, TerminalPreferences.scrollbackLinesRange.upperBound),
            (Int.min, TerminalPreferences.scrollbackLinesRange.lowerBound),
        ] {
            try store.updateGlobalSettings { $0.scrollbackLines = input }
            XCTAssertEqual(store.globalSettings.scrollbackLines, expected, "scrollback \(input)")
            try store.flush()
            let reloaded = try WorkspaceStore(persistenceURL: url)
            XCTAssertEqual(reloaded.globalSettings.scrollbackLines, expected, "scrollback \(input) after reload")
        }
    }

    func testWorkspaceOverridesStoreTheRawValueAndResolveClamped() throws {
        let url = temporaryURL()
        let store = try WorkspaceStore(persistenceURL: url)
        let workspaceID = store.selectedWorkspaceID
        try store.updateWorkspaceSettings(workspaceID) {
            $0.fontSize = 1_000
            $0.scrollbackLines = 10_000_000
        }
        let resolved = try store.resolvedSettings(for: workspaceID)
        XCTAssertEqual(resolved.fontSize, TerminalPreferences.fontSizeRange.upperBound)
        XCTAssertEqual(resolved.scrollbackLines, TerminalPreferences.scrollbackLinesRange.upperBound)

        try store.flush()
        let reloaded = try WorkspaceStore(persistenceURL: url)
        XCTAssertEqual(reloaded.selectedWorkspace.settingsOverrides?.fontSize, 1_000)
        XCTAssertEqual(reloaded.selectedWorkspace.settingsOverrides?.scrollbackLines, 10_000_000)
    }

    /// A non-finite override cannot be written as JSON. The mutation lands in memory and the
    /// flush fails, leaving the store dirty; putting a finite value back lets the next flush
    /// through, and the file is never left half-written.
    func testNonFiniteFontSizeOverrideFailsTheFlushWithoutLosingTheStore() throws {
        let url = temporaryURL()
        let store = try WorkspaceStore(persistenceURL: url)
        let workspaceID = store.selectedWorkspaceID
        try store.updateWorkspaceSettings(workspaceID) { $0.fontSize = 20 }
        try store.flush()

        try store.updateWorkspaceSettings(workspaceID) { $0.fontSize = .nan }
        XCTAssertThrowsError(try store.flush())
        XCTAssertTrue(store.hasUnsavedChanges)
        XCTAssertEqual(try WorkspaceStore(persistenceURL: url).selectedWorkspace.settingsOverrides?.fontSize, 20)

        try store.updateWorkspaceSettings(workspaceID) { $0.fontSize = 21 }
        try store.flush()
        XCTAssertFalse(store.hasUnsavedChanges)
        XCTAssertEqual(try WorkspaceStore(persistenceURL: url).selectedWorkspace.settingsOverrides?.fontSize, 21)
    }

    func testMissingShellPathRoundTripsAndResolvesAsCustom() throws {
        let url = temporaryURL()
        let store = try WorkspaceStore(persistenceURL: url)
        let path = "/nonexistent/\(UUID().uuidString)/zsh"
        try store.updateGlobalSettings { $0.shell = .custom(path: path) }
        try store.flush()
        let reloaded = try WorkspaceStore(persistenceURL: url)
        XCTAssertEqual(reloaded.globalSettings.shell, .custom(path: path))
    }

    func testWhitespaceOnlyShellPathDecodesBackToTheLoginShell() throws {
        let url = temporaryURL()
        let store = try WorkspaceStore(persistenceURL: url)
        try store.updateGlobalSettings { $0.shell = .custom(path: "   ") }
        // In memory the store holds what it was given...
        XCTAssertEqual(store.globalSettings.shell, .custom(path: "   "))
        // ...and the decoder normalises it away on the next launch. The two disagree until then.
        try store.flush()
        let reloaded = try WorkspaceStore(persistenceURL: url)
        XCTAssertEqual(reloaded.globalSettings.shell, .loginShell)
    }

    func testTenThousandCharacterFontNameAndCommandRoundTrip() throws {
        let url = temporaryURL()
        let store = try WorkspaceStore(persistenceURL: url)
        let long = String(repeating: "f", count: 10_000)
        try store.updateGlobalSettings {
            $0.fontPostScriptName = long
            $0.textFileOpenCommand = long
        }
        try store.flush()
        let reloaded = try WorkspaceStore(persistenceURL: url)
        XCTAssertEqual(reloaded.globalSettings.fontPostScriptName, long)
        XCTAssertEqual(reloaded.globalSettings.textFileOpenCommand, long)
    }

    func testEveryOverrideFieldRoundTripsThroughJSON() throws {
        var overrides = TerminalPreferencesOverrides()
        overrides.browserDataScope = .appWide
        overrides.webLinkDestination = .application(bundleIdentifier: "com.example.browser")
        overrides.textFileOpenCommand = "code {file}"
        overrides.nativeTextFilePatterns = ["*.md"]
        overrides.browserFilePatterns = ["*.html"]
        overrides.allowsLocalFileJavaScript = true
        overrides.compactSidebar = false
        overrides.fontPostScriptName = "Menlo-Bold"
        overrides.fontSize = 1_000
        overrides.terminalAppearance = .dark
        overrides.terminalTheme = .solarizedDark
        overrides.shell = .custom(path: "/nonexistent/sh")
        overrides.newSessionWorkingDirectory = .custom(URL(fileURLWithPath: "/tmp", isDirectory: true))
        overrides.scrollbackLines = 10_000_000
        overrides.cursorShape = .underline
        overrides.cursorBlink = false
        overrides.optionAsMeta = false
        overrides.lineEditingMode = .vi

        let data = try JSONEncoder().encode(overrides)
        let decoded = try JSONDecoder().decode(TerminalPreferencesOverrides.self, from: data)
        XCTAssertEqual(decoded, overrides)
    }

    // MARK: - Import and layout interplay

    func testImportingTwoHundredWorkspacesIntoOneFolderThenDraggingOneToTheBottom() throws {
        let url = temporaryURL()
        let store = try WorkspaceStore(persistenceURL: url)
        let document = WorkspaceImportDocument(
            folders: [.init(title: "Big")],
            workspaces: (0..<200).map { .init(title: "W\($0)", folder: "Big") }
        )
        let summary = try store.importWorkspaces(document)
        XCTAssertEqual(summary.importedWorkspaceCount, 200)
        XCTAssertEqual(summary.createdFolderCount, 1)

        let folderID = try XCTUnwrap(store.folders.first { $0.title == "Big" }?.id)
        let members = store.workspaces.filter { $0.folderID == folderID }
        XCTAssertEqual(members.count, 200)
        let first = try XCTUnwrap(members.first)

        try store.moveWorkspace(first.id, to: folderID, before: nil, isPinned: false)
        let after = store.workspaces.filter { $0.folderID == folderID }
        XCTAssertEqual(after.last?.id, first.id)
        XCTAssertEqual(after.count, 200)
    }

    func testFoldersWithTheSameTitleReorderByIdentityNotTitle() throws {
        let url = temporaryURL()
        let store = try WorkspaceStore(persistenceURL: url)
        let a = try store.createFolder(title: "Same")
        let b = try store.createFolder(title: "Same")
        let c = try store.createFolder(title: "Same")
        XCTAssertEqual(store.folders.map(\.id), [a, b, c])

        try store.moveFolder(c, before: a)
        XCTAssertEqual(store.folders.map(\.id), [c, a, b])

        try store.moveFolder(a, before: nil)
        XCTAssertEqual(store.folders.map(\.id), [c, b, a])
    }

    func testImportMatchesAnExistingFolderByTitleWhenTwoShareIt() throws {
        // Two existing folders called "Dup": an import naming "Dup" has to pick one, and must pick
        // the same one every time so repeat imports do not scatter across both. Today the importer
        // builds a title-keyed dictionary in sidebar order, so the last matching folder wins.
        let url = temporaryURL()
        let store = try WorkspaceStore(persistenceURL: url)
        _ = try store.createFolder(title: "Dup")
        let last = try store.createFolder(title: "Dup")
        for round in 0..<2 {
            let document = WorkspaceImportDocument(
                workspaces: [.init(title: "Imported \(round)", folder: "Dup")]
            )
            let summary = try store.importWorkspaces(document)
            XCTAssertEqual(summary.createdFolderCount, 0)
            XCTAssertEqual(summary.reusedFolderCount, 1)
            let imported = try XCTUnwrap(store.workspaces.first { $0.title == "Imported \(round)" })
            XCTAssertEqual(imported.folderID, last, "round \(round)")
        }
    }
}
