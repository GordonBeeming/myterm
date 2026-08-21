import Foundation
import XCTest
@testable import MyTermCore

final class WorkspaceStoreTests: XCTestCase {
    private func temporaryURL() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyTermCoreTests", isDirectory: true)
        XCTAssertNoThrow(try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true))
        return directory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
    }

    /// A private directory, for the tests that change directory permissions.
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyTermCoreTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A fixed clock for the backup-name tests.
    ///
    /// Building the date from components in the current calendar keeps `fixedBackupStamp` correct
    /// in whatever time zone the test machine runs in.
    private static let fixedBackupDate = Calendar.current.date(from: DateComponents(
        year: 2026, month: 8, day: 21, hour: 9, minute: 21, second: 5
    )) ?? Date(timeIntervalSince1970: 0)
    private static let fixedBackupStamp = "20260821-092105"

    private func timestampedBackupURL(_ preferredURL: URL, suffix: String = "") -> URL {
        preferredURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(preferredURL.lastPathComponent)-\(Self.fixedBackupStamp)\(suffix)")
    }

    /// A v2 snapshot whose `isPinned` values are numbers, which the loader repairs on read.
    private func snapshotNeedingStructuralRepair() throws -> Data {
        let workspace = Workspace(title: "Repairable", isPinned: false)
        let snapshot = WorkspaceStoreSnapshot(
            workspaces: [workspace],
            selectedWorkspaceID: workspace.id
        )
        let validJSON = try XCTUnwrap(String(data: JSONEncoder().encode(snapshot), encoding: .utf8))
        let malformedJSON = validJSON.replacingOccurrences(
            of: #""isPinned":false"#,
            with: #""isPinned":0"#
        )
        XCTAssertTrue(malformedJSON.contains(#""isPinned":0"#))
        return Data(malformedJSON.utf8)
    }

    private func removeSelectedWorkspace(_ store: WorkspaceStore) throws {
        try store.removeWorkspace(store.selectedWorkspaceID)
    }

    private func closeSelectedWorkspace(_ store: WorkspaceStore) throws -> WorkspaceLifecycleChange {
        let workspace = store.selectedWorkspace
        return try store.closeTab(
            workspaceID: workspace.id,
            tabGroupID: workspace.focusedTabGroupID,
            tabID: try XCTUnwrap(workspace.selectedTabID)
        )
    }

    func testDefaultWorkspaceIsV2AndHasOneNonemptyFocusedGroup() throws {
        let url = temporaryURL()
        let store = try WorkspaceStore(persistenceURL: url)

        XCTAssertEqual(store.snapshot.version, 2)
        XCTAssertEqual(store.workspaces.count, 1)
        XCTAssertEqual(store.selectedWorkspace.orderedGroups.count, 1)
        XCTAssertEqual(store.selectedWorkspace.focusedTabGroup?.tabs.count, 1)
        XCTAssertNotNil(store.selectedWorkspace.selectedTab?.terminalSession)

        let persisted = try JSONDecoder().decode(WorkspaceStoreSnapshot.self, from: Data(contentsOf: url))
        XCTAssertEqual(persisted, store.snapshot)
    }

    func testTextFilePatternsMatchExtensionsExactNamesAndDotfiles() {
        let preferences = TerminalPreferences(
            nativeTextFilePatterns: ["*.json", "*.d.ts", ".env", ".gitignore", "Dockerfile"]
        )
        let emptySuffixPreferences = TerminalPreferences(nativeTextFilePatterns: ["*."])

        XCTAssertTrue(preferences.matchesNativeTextFile(URL(fileURLWithPath: "/tmp/settings.JSON")))
        XCTAssertTrue(preferences.matchesNativeTextFile(URL(fileURLWithPath: "/tmp/settings.D.TS")))
        XCTAssertTrue(preferences.matchesNativeTextFile(URL(fileURLWithPath: "/tmp/.ENV")))
        XCTAssertTrue(preferences.matchesNativeTextFile(URL(fileURLWithPath: "/tmp/.GITIGNORE")))
        XCTAssertTrue(preferences.matchesNativeTextFile(URL(fileURLWithPath: "/tmp/dockerfile")))
        XCTAssertFalse(preferences.matchesNativeTextFile(URL(fileURLWithPath: "/tmp/foo.gitignore")))
        XCTAssertFalse(preferences.matchesNativeTextFile(URL(fileURLWithPath: "/tmp/report.pdf")))
        XCTAssertFalse(preferences.matchesNativeTextFile(URL(fileURLWithPath: "/tmp/json")))
        XCTAssertFalse(emptySuffixPreferences.matchesNativeTextFile(URL(fileURLWithPath: "/tmp/anything")))

        for powerShellExtension in ["ps1", "psm1", "psd1", "ps1xml", "cdxml"] {
            XCTAssertTrue(
                TerminalPreferences.default.matchesNativeTextFile(
                    URL(fileURLWithPath: "/tmp/example.\(powerShellExtension)")
                )
            )
        }
    }

    func testBrowserFilePatternsDefaultAndMatchExtensions() {
        let preferences = TerminalPreferences(browserFilePatterns: [" *.html ", "*.htm", "index"])

        XCTAssertEqual(TerminalPreferences.defaultBrowserFilePatterns, ["*.html", "*.htm"])
        XCTAssertEqual(preferences.browserFilePatterns, ["*.html", "*.htm", "index"])
        XCTAssertTrue(preferences.matchesBrowserFile(URL(fileURLWithPath: "/tmp/report.HTML")))
        XCTAssertTrue(preferences.matchesBrowserFile(URL(fileURLWithPath: "/tmp/report.htm")))
        XCTAssertTrue(preferences.matchesBrowserFile(URL(fileURLWithPath: "/tmp/INDEX")))
        XCTAssertFalse(preferences.matchesBrowserFile(URL(fileURLWithPath: "/tmp/report.xhtml")))
    }

    func testLegacyMarkdownCommandDecodesIntoTextFileCommand() throws {
        let data = Data("{\"markdownOpenCommand\":\"code --goto {file}\",\"cursorShape\":\"beam\"}".utf8)
        let preferences = try JSONDecoder().decode(TerminalPreferences.self, from: data)

        XCTAssertEqual(preferences.textFileOpenCommand, "code --goto {file}")
        XCTAssertEqual(preferences.nativeTextFilePatterns, TerminalPreferences.defaultNativeTextFilePatterns)
        XCTAssertEqual(preferences.browserFilePatterns, TerminalPreferences.defaultBrowserFilePatterns)
        XCTAssertEqual(preferences.cursorShape, .beam)

        let overrides = try JSONDecoder().decode(
            TerminalPreferencesOverrides.self,
            from: Data("{\"markdownOpenCommand\":\"zed {file}\"}".utf8)
        )
        XCTAssertEqual(overrides.textFileOpenCommand, "zed {file}")
    }

    func testBrowserFilePatternsRoundTripAndScopedOverrides() throws {
        let preferences = TerminalPreferences(browserFilePatterns: ["*.svg", "*.html"])
        let restored = try JSONDecoder().decode(
            TerminalPreferences.self,
            from: JSONEncoder().encode(preferences)
        )
        XCTAssertEqual(restored.browserFilePatterns, ["*.svg", "*.html"])

        var overrides = TerminalPreferencesOverrides()
        overrides.browserFilePatterns = ["*.xhtml"]
        XCTAssertEqual(overrides.applying(to: preferences).browserFilePatterns, ["*.xhtml"])

        let url = temporaryURL()
        let store = try WorkspaceStore(persistenceURL: url)
        let folderID = try store.createFolder(title: "Work")
        let workspaceID = store.selectedWorkspaceID
        try store.moveWorkspace(workspaceID, to: folderID)
        let inheritedWorkspaceID = try store.createWorkspace(title: "Inherited", folderID: folderID)
        try store.updateGlobalSettings { $0.browserFilePatterns = ["*.global"] }
        try store.updateFolderSettings(folderID) { $0.browserFilePatterns = ["*.folder"] }
        try store.updateWorkspaceSettings(workspaceID) { $0.browserFilePatterns = ["*.workspace"] }

        XCTAssertEqual(try store.resolvedSettings(for: inheritedWorkspaceID).browserFilePatterns, ["*.folder"])
        XCTAssertEqual(try store.resolvedSettings(for: workspaceID).browserFilePatterns, ["*.workspace"])
    }

    func testLocalFileJavaScriptDefaultsOffAndResolvesAtEveryScope() throws {
        XCTAssertFalse(TerminalPreferences.default.allowsLocalFileJavaScript)

        let enabled = TerminalPreferences(allowsLocalFileJavaScript: true)
        let restored = try JSONDecoder().decode(
            TerminalPreferences.self,
            from: JSONEncoder().encode(enabled)
        )
        XCTAssertTrue(restored.allowsLocalFileJavaScript)

        let url = temporaryURL()
        let store = try WorkspaceStore(persistenceURL: url)
        let folderID = try store.createFolder(title: "Work")
        let workspaceID = store.selectedWorkspaceID
        try store.moveWorkspace(workspaceID, to: folderID)
        let inheritedWorkspaceID = try store.createWorkspace(title: "Inherited", folderID: folderID)

        try store.updateGlobalSettings { $0.allowsLocalFileJavaScript = true }
        XCTAssertTrue(try store.resolvedSettings(for: inheritedWorkspaceID).allowsLocalFileJavaScript)

        try store.updateFolderSettings(folderID) { $0.allowsLocalFileJavaScript = false }
        XCTAssertFalse(try store.resolvedSettings(for: inheritedWorkspaceID).allowsLocalFileJavaScript)

        try store.updateWorkspaceSettings(workspaceID) { $0.allowsLocalFileJavaScript = true }
        XCTAssertTrue(try store.resolvedSettings(for: workspaceID).allowsLocalFileJavaScript)
    }

    func testTextFileCommandPersistsUnderTheLegacyKeyForGlobalAndScopedSettings() throws {
        let url = temporaryURL()
        let store = try WorkspaceStore(persistenceURL: url)
        let folderID = try store.createFolder(title: "Work")
        let workspaceID = store.selectedWorkspaceID
        try store.moveWorkspace(workspaceID, to: folderID)
        let inheritedWorkspaceID = try store.createWorkspace(title: "Inherited", folderID: folderID)
        try store.updateGlobalSettings { $0.textFileOpenCommand = "global-editor {file}" }
        try store.updateFolderSettings(folderID) { $0.textFileOpenCommand = "folder-editor {file}" }
        try store.updateWorkspaceSettings(workspaceID) { $0.textFileOpenCommand = "workspace-editor {file}" }

        let snapshot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let globalSettings = try XCTUnwrap(snapshot["globalSettings"] as? [String: Any])
        XCTAssertEqual(globalSettings["markdownOpenCommand"] as? String, "global-editor {file}")
        XCTAssertNil(globalSettings["textFileOpenCommand"])

        let folder = try XCTUnwrap((snapshot["folders"] as? [[String: Any]])?.first)
        let folderOverrides = try XCTUnwrap(folder["settingsOverrides"] as? [String: Any])
        XCTAssertEqual(folderOverrides["markdownOpenCommand"] as? String, "folder-editor {file}")
        XCTAssertNil(folderOverrides["textFileOpenCommand"])

        let workspace = try XCTUnwrap((snapshot["workspaces"] as? [[String: Any]])?.first)
        let workspaceOverrides = try XCTUnwrap(workspace["settingsOverrides"] as? [String: Any])
        XCTAssertEqual(workspaceOverrides["markdownOpenCommand"] as? String, "workspace-editor {file}")
        XCTAssertNil(workspaceOverrides["textFileOpenCommand"])

        let restored = try WorkspaceStore(persistenceURL: url)
        XCTAssertEqual(restored.globalSettings.textFileOpenCommand, "global-editor {file}")
        XCTAssertEqual(try restored.resolvedSettings(for: inheritedWorkspaceID).textFileOpenCommand, "folder-editor {file}")
        XCTAssertEqual(try restored.resolvedSettings(for: workspaceID).textFileOpenCommand, "workspace-editor {file}")
    }

    func testV1MigrationMirrorsSelectedGeometryAndFlattensInactiveLeavesLosslessly() throws {
        let url = temporaryURL()
        let workspaceID = WorkspaceID()
        let selectedTabID = TabID()
        let inactiveTabID = TabID()
        let firstSessionID = TerminalSessionID()
        let focusedSessionID = TerminalSessionID()
        let inactiveSessionID = TerminalSessionID()
        let firstPaneID = PaneID()
        let focusedPaneID = PaneID()
        let staleFocusedPaneID = PaneID()
        let selectedBrowserPaneID = PaneID()
        let inactiveBrowserPaneID = PaneID()
        let selectedBrowserID = BrowserSessionID()
        let inactiveBrowserID = BrowserSessionID()
        let profileID = UUID()
        let json = """
        {
          "version":1,
          "globalSettings":{"fontSize":17},
          "workspaces":[{
            "id":"\(workspaceID)",
            "title":"Legacy",
            "tabs":[
              {
                "id":"\(selectedTabID)",
                "customTitle":"Selected title",
                "focusedTerminalSessionID":"\(focusedSessionID)",
                "focusedPaneID":"\(staleFocusedPaneID)",
                "content":{"type":"terminal","splitTree":{
                  "type":"horizontal","children":[
                    {"type":"terminal","session":{"id":"\(firstSessionID)","paneID":"\(firstPaneID)","workingDirectory":"file:///selected","recentText":"selected text"}},
                    {"type":"vertical","children":[
                      {"type":"browser","session":{"id":"\(selectedBrowserID)","paneID":"\(selectedBrowserPaneID)","url":"https://selected.example/path","profile":{"scope":"project-directory","persistentStoreID":"\(profileID)","projectDirectory":"file:///project"}}},
                      {"type":"terminal","session":{"id":"\(focusedSessionID)","paneID":"\(focusedPaneID)","workingDirectory":"file:///focused","recentText":"focused text"}}
                    ]}
                  ]}
                }
              },
              {
                "id":"\(inactiveTabID)",
                "customTitle":"Inactive title",
                "focusedPaneID":"\(inactiveBrowserPaneID)",
                "content":{"type":"terminal","splitTree":{
                  "type":"horizontal","children":[
                    {"type":"terminal","session":{"id":"\(inactiveSessionID)","workingDirectory":"file:///inactive","recentText":"inactive text"}},
                    {"type":"browser","session":{"id":"\(inactiveBrowserID)","paneID":"\(inactiveBrowserPaneID)","url":"https://inactive.example"}}
                  ]}
                }
              }
            ],
            "selectedTabID":"\(selectedTabID)"
          }],
          "selectedWorkspaceID":"\(workspaceID)"
        }
        """
        try Data(json.utf8).write(to: url)

        let store = try WorkspaceStore(persistenceURL: url)
        let workspace = store.selectedWorkspace

        XCTAssertEqual(store.snapshot.version, 2)
        XCTAssertEqual(workspace.orderedGroups.count, 3)
        guard case .split(_, .horizontal, let rootChildren, let rootWeights) = workspace.layout else {
            return XCTFail("Expected selected tab's horizontal root geometry")
        }
        XCTAssertEqual(rootChildren.count, 2)
        XCTAssertEqual(rootWeights, [0.5, 0.5])
        guard case .split(_, .vertical, let nestedChildren, let nestedWeights) = rootChildren[1] else {
            return XCTFail("Expected selected tab's nested vertical geometry")
        }
        XCTAssertEqual(nestedChildren.count, 2)
        XCTAssertEqual(nestedWeights, [0.5, 0.5])

        let firstSelectedLeaf = try XCTUnwrap(workspace.orderedGroups.first?.tabs.first)
        XCTAssertNotEqual(firstSelectedLeaf.id, selectedTabID)
        XCTAssertNil(firstSelectedLeaf.customTitle)

        let focusedGroup = try XCTUnwrap(workspace.focusedTabGroup)
        XCTAssertEqual(focusedGroup.selectedTab.id, selectedTabID)
        XCTAssertEqual(focusedGroup.selectedTab.customTitle, "Selected title")
        XCTAssertEqual(focusedGroup.selectedTab.terminalSession?.id, focusedSessionID)
        XCTAssertEqual(focusedGroup.tabs.count, 3)
        XCTAssertNotEqual(focusedGroup.tabs[1].id, inactiveTabID)
        XCTAssertNil(focusedGroup.tabs[1].customTitle)
        XCTAssertEqual(focusedGroup.tabs[1].terminalSession?.workingDirectory, URL(fileURLWithPath: "/inactive"))
        XCTAssertEqual(focusedGroup.tabs[1].terminalSession?.recentText, "inactive text")
        XCTAssertEqual(focusedGroup.tabs[2].id, inactiveTabID)
        XCTAssertEqual(focusedGroup.tabs[2].customTitle, "Inactive title")
        XCTAssertEqual(focusedGroup.tabs[2].browserSession?.id, inactiveBrowserID)
        XCTAssertEqual(focusedGroup.tabs[2].browserSession?.paneID, inactiveBrowserPaneID)

        XCTAssertEqual(workspace.terminalSession(id: firstSessionID)?.workingDirectory, URL(fileURLWithPath: "/selected"))
        XCTAssertEqual(workspace.terminalSession(id: firstSessionID)?.recentText, "selected text")
        XCTAssertEqual(workspace.terminalSession(id: focusedSessionID)?.workingDirectory, URL(fileURLWithPath: "/focused"))
        let migratedBrowser = try XCTUnwrap(workspace.browserSession(id: selectedBrowserID))
        XCTAssertEqual(migratedBrowser.url, try XCTUnwrap(URL(string: "https://selected.example/path")))
        XCTAssertEqual(migratedBrowser.profile?.scope, .projectDirectory)
        XCTAssertEqual(migratedBrowser.profile?.persistentStoreID, profileID)
        XCTAssertEqual(migratedBrowser.profile?.projectDirectory, URL(fileURLWithPath: "/project"))

        let persistedJSON = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertTrue(persistedJSON.contains(#""version" : 2"#))
        XCTAssertFalse(persistedJSON.contains("splitTree"))
        XCTAssertEqual(try WorkspaceStore(persistenceURL: url).snapshot, store.snapshot)

        XCTAssertEqual(try Data(contentsOf: store.migrationBackupURL), Data(json.utf8))
        XCTAssertEqual(store.loadReport.sourceVersion, 1)
        XCTAssertTrue(store.loadReport.didMigrate)
        XCTAssertEqual(store.loadReport.droppedElementCount, 0)
        XCTAssertEqual(store.loadReport.identifierRepairCount, 0)
        XCTAssertEqual(store.loadReport.structuralRepairCount, 0)
        XCTAssertEqual(store.loadReport.backupURLs, [store.migrationBackupURL])
    }

    func testSnapshotRepairsSessionAndLayoutIdentifiersAcrossWorkspaces() throws {
        let terminalID = TerminalSessionID()
        let browserID = BrowserSessionID()
        let paneID = PaneID()
        let groupID = TabGroupID()
        let tabID = TabID()
        let splitID = SplitNodeID()

        func workspace(id: WorkspaceID, title: String) throws -> Workspace {
            let terminal = Tab(
                id: tabID,
                content: .terminal(TerminalSession(id: terminalID, paneID: paneID, recentText: title))
            )
            let browser = Tab(
                id: tabID,
                content: .browser(BrowserSession(
                    id: browserID,
                    paneID: paneID,
                    url: try XCTUnwrap(URL(string: "https://\(title.lowercased()).example"))
                ))
            )
            let first = TabGroup(id: groupID, tab: terminal)
            let second = TabGroup(id: groupID, tab: browser)
            return Workspace(
                id: id,
                title: title,
                layout: .split(
                    id: splitID,
                    orientation: .horizontal,
                    children: [.group(first), .group(second)],
                    weights: [0.5, 0.5]
                ),
                focusedTabGroupID: first.id
            )
        }

        let firstID = WorkspaceID()
        let secondID = WorkspaceID()
        let snapshot = WorkspaceStoreSnapshot(
            workspaces: [
                try workspace(id: firstID, title: "First"),
                try workspace(id: secondID, title: "Second"),
            ],
            selectedWorkspaceID: firstID
        )
        let tabs = snapshot.workspaces.flatMap(\.allTabs)

        XCTAssertEqual(Set(tabs.map(\.id)).count, tabs.count)
        XCTAssertEqual(Set(tabs.map(\.paneID)).count, tabs.count)
        XCTAssertEqual(Set(tabs.compactMap(\.terminalSession?.id)).count, 2)
        XCTAssertEqual(Set(tabs.compactMap(\.browserSession?.id)).count, 2)
        XCTAssertEqual(Set(snapshot.workspaces.flatMap { $0.orderedGroups.map(\.id) }).count, 4)
        XCTAssertEqual(Set(snapshot.workspaces.flatMap { $0.layout.splitNodeIDs }).count, 2)
        XCTAssertEqual(tabs.compactMap(\.terminalSession?.recentText).sorted(), ["First", "Second"])
        XCTAssertEqual(
            tabs.compactMap(\.browserSession?.url.host).sorted(),
            ["first.example", "second.example"]
        )
    }

    func testLossyDecodePreservesOriginalBytesBeforeWritingRepair() throws {
        let url = temporaryURL()
        let valid = Workspace(title: "Retained")
        let validData = try JSONEncoder().encode(valid)
        let validJSON = try XCTUnwrap(String(data: validData, encoding: .utf8))
        let original = Data("""
        {
          "version":2,
          "workspaces":[\(validJSON),{"id":false}],
          "selectedWorkspaceID":"\(valid.id)"
        }
        """.utf8)
        try original.write(to: url)

        let store = try WorkspaceStore(persistenceURL: url)

        XCTAssertEqual(store.workspaces.map(\.title), ["Retained"])
        XCTAssertEqual(store.loadReport.sourceVersion, 2)
        XCTAssertFalse(store.loadReport.didMigrate)
        XCTAssertGreaterThan(store.loadReport.droppedElementCount, 0)
        XCTAssertEqual(store.loadReport.identifierRepairCount, 0)
        XCTAssertGreaterThan(store.loadReport.structuralRepairCount, 0)
        XCTAssertEqual(store.loadReport.backupURLs, [store.recoveryBackupURL])
        XCTAssertEqual(try Data(contentsOf: store.recoveryBackupURL), original)
        XCTAssertNotEqual(try Data(contentsOf: url), original)
    }

    func testDifferentExistingMigrationBackupTakesATimestampedNameAndStillStarts() throws {
        let url = temporaryURL()
        let workspaceID = WorkspaceID()
        let source = Data("""
        {"version":1,"workspaces":[{"id":"\(workspaceID)","title":"Current","tabs":[]}],"selectedWorkspaceID":"\(workspaceID)"}
        """.utf8)
        let differentWorkspaceID = WorkspaceID()
        let existingBackup = Data("""
        {"version":1,"workspaces":[{"id":"\(differentWorkspaceID)","title":"Earlier","tabs":[]}],"selectedWorkspaceID":"\(differentWorkspaceID)"}
        """.utf8)
        let backupURL = url.appendingPathExtension("v1-backup")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try source.write(to: url)
        try existingBackup.write(to: backupURL)

        let store = try WorkspaceStore(persistenceURL: url, now: Self.fixedBackupDate)

        XCTAssertEqual(store.workspaces.map(\.title), ["Current"])
        XCTAssertTrue(store.loadReport.backupFailureDescriptions.isEmpty)
        XCTAssertEqual(store.loadReport.backupURLs, [timestampedBackupURL(backupURL)])
        XCTAssertEqual(try Data(contentsOf: timestampedBackupURL(backupURL)), source)
        XCTAssertEqual(try Data(contentsOf: backupURL), existingBackup)
        XCTAssertNotEqual(try Data(contentsOf: url), source)
    }

    func testDifferentExistingRecoveryBackupTakesATimestampedNameAndStillStarts() throws {
        let url = temporaryURL()
        let source = try snapshotNeedingStructuralRepair()
        try source.write(to: url)
        let backupURL = url.appendingPathExtension("recovery-backup")
        let existingBackup = Data("an earlier repair".utf8)
        try existingBackup.write(to: backupURL)

        let store = try WorkspaceStore(persistenceURL: url, now: Self.fixedBackupDate)

        XCTAssertEqual(store.workspaces.map(\.isPinned), [false])
        XCTAssertTrue(store.loadReport.backupFailureDescriptions.isEmpty)
        XCTAssertEqual(store.loadReport.backupURLs, [timestampedBackupURL(backupURL)])
        XCTAssertEqual(try Data(contentsOf: timestampedBackupURL(backupURL)), source)
        XCTAssertEqual(try Data(contentsOf: backupURL), existingBackup)
    }

    func testAPreExistingDirectoryAtACandidateNameIsSkippedRatherThanTreatedAsAMatch() throws {
        let url = temporaryURL()
        let source = try snapshotNeedingStructuralRepair()
        try source.write(to: url)
        let backupURL = url.appendingPathExtension("recovery-backup")
        // The exclusive create fails with "file exists" for a directory just like it would for a
        // regular file, but a directory holds no bytes to compare, so the candidate must be skipped
        // rather than misread as an identical-content match that reuses a name with no real backup.
        try FileManager.default.createDirectory(at: backupURL, withIntermediateDirectories: true)

        let store = try WorkspaceStore(persistenceURL: url, now: Self.fixedBackupDate)

        let expectedURL = timestampedBackupURL(backupURL)
        XCTAssertTrue(store.loadReport.backupFailureDescriptions.isEmpty)
        XCTAssertEqual(store.loadReport.backupURLs, [expectedURL])
        XCTAssertEqual(try Data(contentsOf: expectedURL), source)
        XCTAssertEqual(store.workspaces.map(\.isPinned), [false])
    }

    func testRepeatedRecoveryBackupOfTheSameBytesReusesTheExistingFile() throws {
        let url = temporaryURL()
        let source = try snapshotNeedingStructuralRepair()
        try source.write(to: url)
        let backupURL = url.appendingPathExtension("recovery-backup")
        try source.write(to: backupURL)

        let store = try WorkspaceStore(persistenceURL: url, now: Self.fixedBackupDate)

        XCTAssertEqual(store.loadReport.backupURLs, [backupURL])
        XCTAssertFalse(FileManager.default.fileExists(atPath: timestampedBackupURL(backupURL).path))
    }

    func testASecondRepairWithinTheSameSecondTakesANumberedName() throws {
        let url = temporaryURL()
        let source = try snapshotNeedingStructuralRepair()
        try source.write(to: url)
        let backupURL = url.appendingPathExtension("recovery-backup")
        try Data("an earlier repair".utf8).write(to: backupURL)
        try Data("a repair from this second".utf8).write(to: timestampedBackupURL(backupURL))

        let store = try WorkspaceStore(persistenceURL: url, now: Self.fixedBackupDate)

        let numberedURL = timestampedBackupURL(backupURL, suffix: "-2")
        XCTAssertEqual(store.loadReport.backupURLs, [numberedURL])
        XCTAssertEqual(try Data(contentsOf: numberedURL), source)
    }

    func testAnUnwritableDirectoryReportsTheBackupFailureAndKeepsTheOriginalBytes() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("workspace-state.json")
        let source = try snapshotNeedingStructuralRepair()
        try source.write(to: url)
        // Read and execute only: the store can still read the state file, and can write nothing
        // beside it, which is the only way a timestamped name runs out of options.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
            try? FileManager.default.removeItem(at: directory)
        }

        let store = try WorkspaceStore(persistenceURL: url, now: Self.fixedBackupDate)

        XCTAssertEqual(store.workspaces.map(\.isPinned), [false])
        XCTAssertTrue(store.loadReport.backupURLs.isEmpty)
        XCTAssertEqual(store.loadReport.backupFailureDescriptions.count, 1)
        // Nothing preserved the original bytes, so the store must not have rewritten over them.
        XCTAssertEqual(try Data(contentsOf: url), source)
    }

    func testPersistenceStaysSuspendedForTheRestOfTheSessionAfterABackupFailure() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("workspace-state.json")
        let source = try snapshotNeedingStructuralRepair()
        try source.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
            try? FileManager.default.removeItem(at: directory)
        }

        let store = try WorkspaceStore(persistenceURL: url, now: Self.fixedBackupDate)

        XCTAssertTrue(store.isPersistenceSuspended)
        // A later write (a migration, a user action) must not throw and must not touch the file
        // the failed backup left as the only copy of the original state.
        XCTAssertNoThrow(try store.createWorkspace(title: "x"))
        XCTAssertEqual(try Data(contentsOf: url), source)
    }

    func testACleanLoadIsNotSuspendedAndWritesNormally() throws {
        let url = temporaryURL()

        let store = try WorkspaceStore(persistenceURL: url, now: Self.fixedBackupDate)

        XCTAssertFalse(store.isPersistenceSuspended)
        try store.createWorkspace(title: "x")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testStorePreservesOriginalBytesBeforeStructuralV2Repair() throws {
        let url = temporaryURL()
        let workspaceID = WorkspaceID()
        let firstGroupID = TabGroupID()
        let secondGroupID = TabGroupID()
        let firstTabID = TabID()
        let secondTabID = TabID()
        let firstSessionID = TerminalSessionID()
        let secondSessionID = TerminalSessionID()
        let firstPaneID = PaneID()
        let secondPaneID = PaneID()
        let splitID = SplitNodeID()
        let firstGroupJSON = """
        {"id":"\(firstGroupID)","tabs":[{"id":"\(firstTabID)","content":{"type":"terminal","session":{"id":"\(firstSessionID)","paneID":"\(firstPaneID)"}}}],"selectedTabID":"\(firstTabID)"}
        """
        let secondGroupJSON = """
        {"id":"\(secondGroupID)","tabs":[{"id":"\(secondTabID)","content":{"type":"terminal","session":{"id":"\(secondSessionID)","paneID":"\(secondPaneID)"}}}],"selectedTabID":"\(secondTabID)"}
        """
        let original = Data("""
        {
          "version":2,
          "workspaces":[{
            "id":"\(workspaceID)","title":"Repair",
            "layout":{"type":"split","id":"\(splitID)","orientation":"horizontal","children":[
              {"type":"group","group":\(firstGroupJSON)},
              {"type":"group","group":\(secondGroupJSON)}
            ],"weights":[-1,0]},
            "focusedTabGroupID":"\(TabGroupID())"
          }],
          "selectedWorkspaceID":"\(workspaceID)"
        }
        """.utf8)
        try original.write(to: url)

        let store = try WorkspaceStore(persistenceURL: url)
        let workspace = store.selectedWorkspace

        XCTAssertEqual(workspace.orderedGroups.count, 2)
        XCTAssertNotNil(workspace.focusedTabGroup)
        guard case .split(_, _, _, let weights) = workspace.layout else {
            return XCTFail("Expected a repaired split")
        }
        XCTAssertEqual(weights, [0.5, 0.5])
        XCTAssertEqual(store.loadReport.droppedElementCount, 0)
        XCTAssertEqual(store.loadReport.identifierRepairCount, 0)
        XCTAssertGreaterThan(store.loadReport.structuralRepairCount, 0)
        XCTAssertEqual(store.loadReport.backupURLs, [store.recoveryBackupURL])
        XCTAssertEqual(try Data(contentsOf: store.recoveryBackupURL), original)
    }

    func testStorePreservesOriginalBytesBeforeRepairingInvalidV2Identifiers() throws {
        let url = temporaryURL()
        let validSnapshot = WorkspaceStoreSnapshot.initial()
        let validJSON = try XCTUnwrap(String(
            data: JSONEncoder().encode(validSnapshot),
            encoding: .utf8
        ))
        let original = Data(validJSON.replacingOccurrences(
            of: validSnapshot.selectedWorkspaceID.description,
            with: "invalid-workspace-id"
        ).utf8)
        try original.write(to: url)

        let store = try WorkspaceStore(persistenceURL: url)

        XCTAssertEqual(store.loadReport.droppedElementCount, 0)
        XCTAssertGreaterThan(store.loadReport.identifierRepairCount, 0)
        XCTAssertEqual(store.loadReport.structuralRepairCount, 0)
        XCTAssertEqual(store.loadReport.backupURLs, [store.recoveryBackupURL])
        XCTAssertEqual(try Data(contentsOf: store.recoveryBackupURL), original)
    }

    func testValidUnchangedV2SnapshotDoesNotCreateRecoveryBackup() throws {
        let url = temporaryURL()
        let snapshot = WorkspaceStoreSnapshot.initial()
        try JSONEncoder().encode(snapshot).write(to: url)

        let store = try WorkspaceStore(persistenceURL: url)

        XCTAssertEqual(store.loadReport.droppedElementCount, 0)
        XCTAssertEqual(store.loadReport.identifierRepairCount, 0)
        XCTAssertEqual(store.loadReport.structuralRepairCount, 0)
        XCTAssertTrue(store.loadReport.backupURLs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.recoveryBackupURL.path))
    }

    func testV2SnapshotMissingBrowserFilePatternsDoesNotCreateRecoveryBackup() throws {
        let url = temporaryURL()
        let snapshot = WorkspaceStoreSnapshot.initial()
        var persisted = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any]
        )
        var globalSettings = try XCTUnwrap(persisted["globalSettings"] as? [String: Any])
        globalSettings.removeValue(forKey: "browserFilePatterns")
        persisted["globalSettings"] = globalSettings
        try JSONSerialization.data(withJSONObject: persisted).write(to: url)

        let store = try WorkspaceStore(persistenceURL: url)

        XCTAssertEqual(store.globalSettings.browserFilePatterns, TerminalPreferences.defaultBrowserFilePatterns)
        XCTAssertEqual(store.loadReport.structuralRepairCount, 0)
        XCTAssertTrue(store.loadReport.backupURLs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.recoveryBackupURL.path))
    }

    func testV2SnapshotMissingLocalFileJavaScriptDoesNotCollideWithExistingRecoveryBackup() throws {
        let url = temporaryURL()
        let snapshot = WorkspaceStoreSnapshot.initial()
        var persisted = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any]
        )
        var globalSettings = try XCTUnwrap(persisted["globalSettings"] as? [String: Any])
        globalSettings.removeValue(forKey: "allowsLocalFileJavaScript")
        persisted["globalSettings"] = globalSettings
        try JSONSerialization.data(withJSONObject: persisted).write(to: url)

        let recoveryBackupURL = url.appendingPathExtension("recovery-backup")
        let existingBackup = Data("earlier recovery".utf8)
        try existingBackup.write(to: recoveryBackupURL)

        let store = try WorkspaceStore(persistenceURL: url)

        XCTAssertFalse(store.globalSettings.allowsLocalFileJavaScript)
        XCTAssertEqual(store.loadReport.structuralRepairCount, 0)
        XCTAssertTrue(store.loadReport.backupURLs.isEmpty)
        XCTAssertEqual(try Data(contentsOf: recoveryBackupURL), existingBackup)
    }

    func testNumericBooleanValuesTriggerStructuralRepairAndExactByteBackup() throws {
        let url = temporaryURL()
        let first = Workspace(title: "Numeric zero", isPinned: false)
        let second = Workspace(title: "Numeric one", isPinned: true)
        let snapshot = WorkspaceStoreSnapshot(
            workspaces: [first, second],
            selectedWorkspaceID: first.id
        )
        let validJSON = try XCTUnwrap(String(
            data: JSONEncoder().encode(snapshot),
            encoding: .utf8
        ))
        let malformedJSON = validJSON
            .replacingOccurrences(of: #""isPinned":false"#, with: #""isPinned":0"#)
            .replacingOccurrences(of: #""isPinned":true"#, with: #""isPinned":1"#)
        XCTAssertTrue(malformedJSON.contains(#""isPinned":0"#))
        XCTAssertTrue(malformedJSON.contains(#""isPinned":1"#))
        let original = Data(malformedJSON.utf8)
        try original.write(to: url)

        let store = try WorkspaceStore(persistenceURL: url)

        XCTAssertGreaterThan(store.loadReport.structuralRepairCount, 0)
        XCTAssertEqual(store.loadReport.backupURLs, [store.recoveryBackupURL])
        XCTAssertEqual(try Data(contentsOf: store.recoveryBackupURL), original)
        XCTAssertEqual(store.workspaces.map(\.isPinned), [false, false])

        let rewritten = try XCTUnwrap(String(
            data: Data(contentsOf: url),
            encoding: .utf8
        ))
        XCTAssertFalse(rewritten.contains(#""isPinned" : 0"#))
        XCTAssertFalse(rewritten.contains(#""isPinned" : 1"#))
        XCTAssertEqual(rewritten.components(separatedBy: #""isPinned" : false"#).count - 1, 2)
    }

    func testAddSelectRenameReorderMoveAndCollapsePersist() throws {
        let url = temporaryURL()
        let store = try WorkspaceStore(persistenceURL: url)
        let workspaceID = store.selectedWorkspaceID
        let firstGroupID = store.selectedWorkspace.focusedTabGroupID
        let originalTabID = try XCTUnwrap(store.selectedWorkspace.selectedTabID)
        let browserTabID = try store.addBrowserTab(
            to: workspaceID,
            tabGroupID: firstGroupID,
            url: try XCTUnwrap(URL(string: "https://example.com"))
        )
        let terminalTabID = try store.addTerminalTab(
            to: workspaceID,
            tabGroupID: firstGroupID,
            workingDirectory: URL(fileURLWithPath: "/tmp/build")
        )

        try store.renameTab(
            workspaceID: workspaceID,
            tabGroupID: firstGroupID,
            tabID: terminalTabID,
            customTitle: "  Build  "
        )
        try store.reorderTab(
            workspaceID: workspaceID,
            tabGroupID: firstGroupID,
            tabID: terminalTabID,
            to: 0
        )
        let newGroupID = try XCTUnwrap(store.moveTabToNewGroup(
            workspaceID: workspaceID,
            sourceTabGroupID: firstGroupID,
            tabID: terminalTabID,
            beside: firstGroupID,
            edge: .right
        ))

        XCTAssertEqual(store.selectedWorkspace.orderedGroups.map(\.id), [firstGroupID, newGroupID])
        XCTAssertEqual(store.selectedWorkspace.focusedTabGroupID, newGroupID)
        XCTAssertEqual(store.selectedWorkspace.focusedTabGroup?.selectedTab.customTitle, "Build")
        XCTAssertTrue(try store.moveTab(
            workspaceID: workspaceID,
            sourceTabGroupID: newGroupID,
            tabID: terminalTabID,
            to: firstGroupID,
            at: 1
        ))
        XCTAssertEqual(store.selectedWorkspace.orderedGroups.map(\.id), [firstGroupID])
        XCTAssertEqual(store.selectedWorkspace.focusedTabGroup?.tabs.map(\.id), [originalTabID, terminalTabID, browserTabID])

        let restored = try WorkspaceStore(persistenceURL: url)
        XCTAssertEqual(restored.selectedWorkspace, store.selectedWorkspace)
    }

    func testInvalidAndNoOpMovesDoNotMutateState() throws {
        let store = try WorkspaceStore(persistenceURL: temporaryURL())
        let workspaceID = store.selectedWorkspaceID
        let groupID = store.selectedWorkspace.focusedTabGroupID
        let tabID = try XCTUnwrap(store.selectedWorkspace.selectedTabID)
        let snapshot = store.snapshot

        XCTAssertFalse(try store.moveTab(
            workspaceID: workspaceID,
            sourceTabGroupID: groupID,
            tabID: tabID,
            to: groupID,
            at: 0
        ))
        XCTAssertNil(try store.moveTabToNewGroup(
            workspaceID: workspaceID,
            sourceTabGroupID: groupID,
            tabID: tabID,
            beside: groupID,
            edge: .left
        ))
        XCTAssertEqual(store.snapshot, snapshot)
        XCTAssertThrowsError(try store.moveTab(
            workspaceID: workspaceID,
            sourceTabGroupID: groupID,
            tabID: TabID(),
            to: groupID
        ))
        XCTAssertThrowsError(try store.moveTab(
            workspaceID: workspaceID,
            sourceTabGroupID: groupID,
            tabID: tabID,
            to: TabGroupID()
        ))
    }

    func testSplitWithNewTerminalAndWeightsPersist() throws {
        let url = temporaryURL()
        let store = try WorkspaceStore(persistenceURL: url)
        let workspaceID = store.selectedWorkspaceID
        let firstGroupID = store.selectedWorkspace.focusedTabGroupID
        let split = try store.splitTabGroup(
            workspaceID: workspaceID,
            tabGroupID: firstGroupID,
            edge: .bottom,
            workingDirectory: URL(fileURLWithPath: "/tmp/new-pane")
        )

        XCTAssertEqual(store.selectedWorkspace.focusedTabGroupID, split.tabGroupID)
        XCTAssertEqual(store.selectedWorkspace.selectedTabID, split.tabID)
        guard case .split(let splitID, .vertical, let children, let weights) = store.selectedWorkspace.layout else {
            return XCTFail("Expected a vertical split")
        }
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(weights, [0.5, 0.5])

        try store.updateSplitWeights(workspaceID: workspaceID, splitID: splitID, weights: [1, 3])
        let restored = try WorkspaceStore(persistenceURL: url)
        guard case .split(let restoredID, .vertical, _, let restoredWeights) = restored.selectedWorkspace.layout else {
            return XCTFail("Expected the split to persist")
        }
        XCTAssertEqual(restoredID, splitID)
        XCTAssertEqual(restoredWeights, [0.25, 0.75])
        XCTAssertThrowsError(
            try restored.updateSplitWeights(workspaceID: workspaceID, splitID: SplitNodeID(), weights: [1, 1])
        )
    }

    func testExplicitSessionAndBrowserUpdatesPersistAndRejectWrongContent() throws {
        let url = temporaryURL()
        let store = try WorkspaceStore(persistenceURL: url)
        let workspaceID = store.selectedWorkspaceID
        let groupID = store.selectedWorkspace.focusedTabGroupID
        let terminalTabID = try XCTUnwrap(store.selectedWorkspace.selectedTabID)
        let browserTabID = try store.addBrowserTab(
            to: workspaceID,
            tabGroupID: groupID,
            url: try XCTUnwrap(URL(string: "https://old.example"))
        )
        let profile = BrowserDataProfile(
            scope: .projectDirectory,
            persistentStoreID: UUID(),
            projectDirectory: URL(fileURLWithPath: "/tmp/project")
        )

        try store.updateTerminalWorkingDirectory(
            workspaceID: workspaceID,
            tabGroupID: groupID,
            tabID: terminalTabID,
            workingDirectory: URL(fileURLWithPath: "/tmp/work")
        )
        try store.updateTerminalRecentText(
            workspaceID: workspaceID,
            tabGroupID: groupID,
            tabID: terminalTabID,
            recentText: String(repeating: "x", count: 10_000)
        )
        try store.updateBrowserURL(
            workspaceID: workspaceID,
            tabGroupID: groupID,
            tabID: browserTabID,
            url: try XCTUnwrap(URL(string: "https://new.example"))
        )
        try store.updateBrowserDataProfile(
            workspaceID: workspaceID,
            tabGroupID: groupID,
            tabID: browserTabID,
            profile: profile
        )

        let restored = try WorkspaceStore(persistenceURL: url)
        let terminal = try XCTUnwrap(restored.selectedWorkspace.tab(groupID: groupID, tabID: terminalTabID)?.terminalSession)
        let browser = try XCTUnwrap(restored.selectedWorkspace.tab(groupID: groupID, tabID: browserTabID)?.browserSession)
        XCTAssertEqual(terminal.workingDirectory, URL(fileURLWithPath: "/tmp/work"))
        XCTAssertLessThanOrEqual(terminal.recentText?.utf8.count ?? 0, TerminalSession.maximumRecentTextBytes)
        XCTAssertEqual(browser.url, try XCTUnwrap(URL(string: "https://new.example")))
        XCTAssertEqual(browser.profile, profile)
        XCTAssertThrowsError(try restored.updateBrowserURL(
            workspaceID: workspaceID,
            tabGroupID: groupID,
            tabID: terminalTabID,
            url: browser.url
        ))
        XCTAssertThrowsError(try restored.updateTerminalRecentText(
            workspaceID: workspaceID,
            tabGroupID: groupID,
            tabID: browserTabID,
            recentText: "wrong"
        ))
    }

    func testBrowserURLBatchUpdatesAreAtomicAndRejectNonBrowserTabs() throws {
        let url = temporaryURL()
        let store = try WorkspaceStore(persistenceURL: url)
        let workspaceID = store.selectedWorkspaceID
        let groupID = store.selectedWorkspace.focusedTabGroupID
        let terminalTabID = try XCTUnwrap(store.selectedWorkspace.selectedTabID)
        let firstBrowserTabID = try store.addBrowserTab(
            to: workspaceID,
            tabGroupID: groupID,
            url: try XCTUnwrap(URL(string: "https://first.example/old"))
        )
        let secondBrowserTabID = try store.addBrowserTab(
            to: workspaceID,
            tabGroupID: groupID,
            url: try XCTUnwrap(URL(string: "https://second.example/old"))
        )

        XCTAssertThrowsError(try store.updateBrowserURLs([
            (workspaceID, groupID, firstBrowserTabID, try XCTUnwrap(URL(string: "https://first.example/new"))),
            (workspaceID, groupID, terminalTabID, try XCTUnwrap(URL(string: "https://wrong.example")))
        ])) { error in
            XCTAssertEqual(error as? WorkspaceStoreError, .browserTabRequired(terminalTabID))
        }
        XCTAssertEqual(
            store.selectedWorkspace.tab(groupID: groupID, tabID: firstBrowserTabID)?.browserSession?.url,
            try XCTUnwrap(URL(string: "https://first.example/old"))
        )

        try store.updateBrowserURLs([
            (workspaceID, groupID, firstBrowserTabID, try XCTUnwrap(URL(string: "https://first.example/new"))),
            (workspaceID, groupID, secondBrowserTabID, try XCTUnwrap(URL(string: "https://second.example/new")))
        ])
        let restored = try WorkspaceStore(persistenceURL: url)
        XCTAssertEqual(
            restored.selectedWorkspace.tab(groupID: groupID, tabID: firstBrowserTabID)?.browserSession?.url,
            try XCTUnwrap(URL(string: "https://first.example/new"))
        )
        XCTAssertEqual(
            restored.selectedWorkspace.tab(groupID: groupID, tabID: secondBrowserTabID)?.browserSession?.url,
            try XCTUnwrap(URL(string: "https://second.example/new"))
        )
    }

    func testClosingFinalTabCollapsesGroupThenAppliesWorkspaceLifecycle() throws {
        let store = try WorkspaceStore(persistenceURL: temporaryURL())
        let workspaceID = store.selectedWorkspaceID
        let firstGroupID = store.selectedWorkspace.focusedTabGroupID
        let firstTabID = try XCTUnwrap(store.selectedWorkspace.selectedTabID)
        let split = try store.splitTabGroup(
            workspaceID: workspaceID,
            tabGroupID: firstGroupID,
            edge: .right
        )

        let groupCollapse = try store.closeTab(
            workspaceID: workspaceID,
            tabGroupID: split.tabGroupID,
            tabID: split.tabID
        )
        XCTAssertNil(groupCollapse.removedWorkspace)
        XCTAssertEqual(store.selectedWorkspace.orderedGroups.map(\.id), [firstGroupID])

        let lifecycle = try store.closeTab(
            workspaceID: workspaceID,
            tabGroupID: firstGroupID,
            tabID: firstTabID
        )
        XCTAssertEqual(lifecycle.removedWorkspace?.id, workspaceID)
        XCTAssertNotNil(lifecycle.replacementWorkspace)
        XCTAssertEqual(store.workspaces.count, 1)
    }

    func testRemovingMiddleSiblingSelectsPreviousSibling() throws {
        let store = try WorkspaceStore(persistenceURL: temporaryURL())
        let folderID = try store.createFolder(title: "Folder")
        let firstID = try store.createWorkspace(title: "First", folderID: folderID)
        let middleID = try store.createWorkspace(title: "Middle", folderID: folderID)
        _ = try store.createWorkspace(title: "Last", folderID: folderID)
        try store.selectWorkspace(middleID)

        try removeSelectedWorkspace(store)

        XCTAssertEqual(store.selectedWorkspaceID, firstID)
    }

    func testRemovingFirstSiblingSelectsFollowingSibling() throws {
        let store = try WorkspaceStore(persistenceURL: temporaryURL())
        let folderID = try store.createFolder(title: "Folder")
        let firstID = try store.createWorkspace(title: "First", folderID: folderID)
        let secondID = try store.createWorkspace(title: "Second", folderID: folderID)
        try store.selectWorkspace(firstID)

        try removeSelectedWorkspace(store)

        XCTAssertEqual(store.selectedWorkspaceID, secondID)
    }

    func testRemovingFinalSiblingSelectsBottomWorkspaceAboveSkippingEmptyFolders() throws {
        let store = try WorkspaceStore(persistenceURL: temporaryURL())
        let aboveID = try store.createFolder(title: "Above")
        _ = try store.createFolder(title: "Empty")
        let removedFolderID = try store.createFolder(title: "Removed")
        _ = try store.createWorkspace(title: "Above first", folderID: aboveID)
        let aboveWorkspaceID = try store.createWorkspace(title: "Above bottom", folderID: aboveID)
        let removedID = try store.createWorkspace(title: "Removed workspace", folderID: removedFolderID)
        try store.selectWorkspace(removedID)

        try removeSelectedWorkspace(store)

        XCTAssertEqual(store.selectedWorkspaceID, aboveWorkspaceID)
    }

    func testSelectingCollapsedDestinationExpandsItsFolder() throws {
        let store = try WorkspaceStore(persistenceURL: temporaryURL())
        let folderID = try store.createFolder(title: "Collapsed")
        let firstID = try store.createWorkspace(title: "First", folderID: folderID)
        let secondID = try store.createWorkspace(title: "Second", folderID: folderID)
        try store.setFolderExpanded(folderID, isExpanded: false)
        try store.selectWorkspace(firstID)

        try removeSelectedWorkspace(store)

        XCTAssertEqual(store.selectedWorkspaceID, secondID)
        XCTAssertTrue(try XCTUnwrap(store.folders.first { $0.id == folderID }).isExpanded)
    }

    func testRemovingFinalTopFolderWorkspaceFallsDownward() throws {
        let store = try WorkspaceStore(persistenceURL: temporaryURL())
        let topFolderID = try store.createFolder(title: "Top")
        let bottomFolderID = try store.createFolder(title: "Bottom")
        let topID = try store.createWorkspace(title: "Top workspace", folderID: topFolderID)
        let bottomID = try store.createWorkspace(title: "Bottom first", folderID: bottomFolderID)
        _ = try store.createWorkspace(title: "Bottom second", folderID: bottomFolderID)
        try store.selectWorkspace(topID)

        try removeSelectedWorkspace(store)

        XCTAssertEqual(store.selectedWorkspaceID, bottomID)
    }

    func testUnfiledIsFinalSectionForDownwardFallback() throws {
        let store = try WorkspaceStore(persistenceURL: temporaryURL())
        let unfiledID = store.selectedWorkspaceID
        let folderID = try store.createFolder(title: "Folder")
        let folderWorkspaceID = try store.createWorkspace(title: "Folder workspace", folderID: folderID)
        try store.selectWorkspace(folderWorkspaceID)

        try removeSelectedWorkspace(store)

        XCTAssertEqual(store.selectedWorkspaceID, unfiledID)
        XCTAssertEqual(store.workspaces.count, 1)
    }

    func testUnfiledFallsBackUpToNearestPopulatedFolder() throws {
        let store = try WorkspaceStore(persistenceURL: temporaryURL())
        let unfiledID = store.selectedWorkspaceID
        let folderID = try store.createFolder(title: "Folder")
        let folderWorkspaceID = try store.createWorkspace(title: "Folder workspace", folderID: folderID)
        try store.selectWorkspace(unfiledID)

        try removeSelectedWorkspace(store)

        XCTAssertEqual(store.selectedWorkspaceID, folderWorkspaceID)
        XCTAssertFalse(store.workspaces.contains { $0.id == unfiledID })
        XCTAssertEqual(store.workspaces.count, 1)
    }

    func testPinnedWorkspaceOrderingChoosesPinnedPredecessor() throws {
        let store = try WorkspaceStore(persistenceURL: temporaryURL())
        let folderID = try store.createFolder(title: "Folder")
        let unpinnedID = try store.createWorkspace(title: "Unpinned", folderID: folderID)
        let pinnedID = try store.createWorkspace(title: "Pinned", folderID: folderID)
        try store.setWorkspacePinned(pinnedID, isPinned: true)
        try store.selectWorkspace(unpinnedID)

        try removeSelectedWorkspace(store)

        XCTAssertEqual(store.selectedWorkspaceID, pinnedID)
    }

    func testRemovingNonSelectedWorkspacePreservesSelectionAndExpansion() throws {
        let store = try WorkspaceStore(persistenceURL: temporaryURL())
        let folderID = try store.createFolder(title: "Collapsed")
        let selectedID = try store.createWorkspace(title: "Selected", folderID: folderID)
        let removedID = try store.createWorkspace(title: "Removed", folderID: folderID)
        try store.setFolderExpanded(folderID, isExpanded: false)
        try store.selectWorkspace(selectedID)

        try store.removeWorkspace(removedID)

        XCTAssertEqual(store.selectedWorkspaceID, selectedID)
        XCTAssertFalse(try XCTUnwrap(store.folders.first { $0.id == folderID }).isExpanded)
    }

    func testFinalTabClosureUsesTheSameWorkspaceSuccessor() throws {
        let store = try WorkspaceStore(persistenceURL: temporaryURL())
        let folderID = try store.createFolder(title: "Folder")
        let firstID = try store.createWorkspace(title: "First", folderID: folderID)
        let secondID = try store.createWorkspace(title: "Second", folderID: folderID)
        try store.selectWorkspace(firstID)

        let lifecycle = try closeSelectedWorkspace(store)

        XCTAssertEqual(lifecycle.removedWorkspace?.id, firstID)
        XCTAssertEqual(lifecycle.selectedWorkspaceID, secondID)
        XCTAssertNil(lifecycle.replacementWorkspace)
    }

    func testRemovingOnlyWorkspaceCreatesReplacement() throws {
        let store = try WorkspaceStore(persistenceURL: temporaryURL())
        let removedID = store.selectedWorkspaceID

        try removeSelectedWorkspace(store)

        XCTAssertEqual(store.workspaces.count, 1)
        XCTAssertNotEqual(store.selectedWorkspaceID, removedID)
    }

    func testFoldersWorkspaceOrderingAndScopedSettingsStillPersist() throws {
        let url = temporaryURL()
        let store = try WorkspaceStore(persistenceURL: url)
        let folderID = try store.createFolder(title: "Work", color: .teal)
        let firstID = try store.createWorkspace(title: "API", folderID: folderID)
        let secondID = try store.createWorkspace(title: "Web", folderID: folderID)
        try store.setWorkspacePinned(firstID, isPinned: true)
        try store.setWorkspacePinned(secondID, isPinned: true)
        try store.moveWorkspace(secondID, to: folderID, before: firstID)
        try store.updateGlobalSettings { $0.fontSize = 12 }
        try store.updateFolderSettings(folderID) { $0.fontSize = 15 }
        try store.updateWorkspaceSettings(firstID) { $0.fontSize = 18 }

        XCTAssertEqual(try store.resolvedSettings(for: firstID).fontSize, 18)
        XCTAssertEqual(try store.resolvedSettings(for: secondID).fontSize, 15)
        let restored = try WorkspaceStore(persistenceURL: url)
        XCTAssertEqual(restored.workspaces.filter { $0.folderID == folderID }.map(\.id), [secondID, firstID])
        XCTAssertEqual(try restored.resolvedSettings(for: firstID).fontSize, 18)
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
        try Data(#"{"version":99,"workspaces":[],"selectedWorkspaceID":"bad"}"#.utf8).write(to: unsupportedURL)
        XCTAssertThrowsError(try WorkspaceStore(persistenceURL: unsupportedURL)) { error in
            XCTAssertEqual(error as? WorkspaceStoreError, .unsupportedVersion(99))
        }
    }
}
