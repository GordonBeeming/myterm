import Foundation
import XCTest
@testable import MyTermCore

final class WorkspaceImportTests: XCTestCase {
    private func temporaryURL() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyTermCoreTests", isDirectory: true)
        XCTAssertNoThrow(try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true))
        return directory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
    }

    private let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

    private func store() throws -> WorkspaceStore {
        try WorkspaceStore(persistenceURL: temporaryURL())
    }

    @discardableResult
    private func importing(
        _ json: String,
        into store: WorkspaceStore
    ) throws -> WorkspaceImportSummary {
        try store.importWorkspaces(fromJSON: Data(json.utf8), homeDirectory: home)
    }

    func testImportAppendsWorkspacesWithoutDisturbingExistingOnes() throws {
        let store = try store()
        let existingID = store.selectedWorkspaceID
        let existingCount = store.workspaces.count

        let summary = try importing(
            """
            {
              "version": 1,
              "folders": [{ "title": "Projects", "color": "purple" }],
              "workspaces": [
                { "title": "API", "folder": "Projects", "tabs": [{ "directory": "~/code/api" }] },
                { "title": "Web", "folder": "Projects", "tabs": [
                  { "directory": "/srv/web" }, { "directory": "/srv/web/assets" }
                ] }
              ]
            }
            """,
            into: store
        )

        XCTAssertEqual(summary.importedWorkspaceCount, 2)
        XCTAssertEqual(summary.createdFolderCount, 1)
        XCTAssertEqual(summary.reusedFolderCount, 0)
        XCTAssertEqual(summary.importedTabCount, 3)
        XCTAssertTrue(summary.warnings.isEmpty)

        XCTAssertEqual(store.workspaces.count, existingCount + 2)
        XCTAssertTrue(store.workspaces.contains { $0.id == existingID })
        XCTAssertEqual(store.workspaces.map(\.title).suffix(2), ["API", "Web"])

        let folder = try XCTUnwrap(store.folders.first { $0.title == "Projects" })
        XCTAssertEqual(folder.color, .purple)
        XCTAssertEqual(store.workspaces.suffix(2).compactMap(\.folderID), [folder.id, folder.id])
    }

    func testTildeAndFileURLDirectoriesResolveAgainstHome() throws {
        let store = try store()
        try importing(
            """
            { "workspaces": [{ "title": "Dirs", "tabs": [
              { "directory": "~/code/api" },
              { "directory": "~" },
              { "directory": "file:///srv/web" }
            ] }] }
            """,
            into: store
        )

        let workspace = try XCTUnwrap(store.workspaces.last)
        let directories = workspace.orderedGroups
            .flatMap(\.tabs)
            .compactMap { $0.terminalSession?.workingDirectory?.path }
        XCTAssertEqual(directories, ["/Users/example/code/api", "/Users/example", "/srv/web"])
    }

    func testExistingFolderIsReusedRatherThanDuplicated() throws {
        let store = try store()
        let existingFolderID = try store.createFolder(title: "Projects")

        let summary = try importing(
            """
            { "workspaces": [{ "title": "API", "folder": "projects", "tabs": [{ "directory": "/tmp" }] }] }
            """,
            into: store
        )

        XCTAssertEqual(summary.createdFolderCount, 0)
        XCTAssertEqual(summary.reusedFolderCount, 1)
        XCTAssertEqual(store.folders.filter { $0.title.lowercased() == "projects" }.count, 1)
        XCTAssertEqual(store.workspaces.last?.folderID, existingFolderID)
    }

    func testFolderReferencedWithoutBeingDeclaredIsCreated() throws {
        let store = try store()
        let summary = try importing(
            """
            { "workspaces": [{ "title": "API", "folder": "Fresh", "tabs": [{ "directory": "/tmp" }] }] }
            """,
            into: store
        )

        XCTAssertEqual(summary.createdFolderCount, 1)
        XCTAssertEqual(store.folders.last?.title, "Fresh")
    }

    func testSplitLayoutIsPreservedWithOrientationAndWeights() throws {
        let store = try store()
        try importing(
            """
            { "workspaces": [{ "title": "Split", "layout": {
              "orientation": "vertical",
              "weights": [0.7, 0.3],
              "children": [
                { "tabs": [{ "directory": "/a" }] },
                { "tabs": [{ "directory": "/b" }, { "directory": "/c" }] }
              ]
            } }] }
            """,
            into: store
        )

        let workspace = try XCTUnwrap(store.workspaces.last)
        guard case .split(_, let orientation, let children, let weights) = workspace.layout else {
            return XCTFail("expected a split layout, got \(workspace.layout)")
        }
        XCTAssertEqual(orientation, .vertical)
        XCTAssertEqual(weights, [0.7, 0.3])
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(workspace.orderedGroups.count, 2)
        XCTAssertEqual(workspace.orderedGroups.map(\.tabs.count), [1, 2])
    }

    func testNestedSplitsSurviveImport() throws {
        let store = try store()
        try importing(
            """
            { "workspaces": [{ "title": "Nested", "layout": { "orientation": "horizontal", "children": [
              { "tabs": [{ "directory": "/a" }] },
              { "orientation": "vertical", "children": [
                { "tabs": [{ "directory": "/b" }] },
                { "tabs": [{ "directory": "/c" }] }
              ] }
            ] } }] }
            """,
            into: store
        )

        let workspace = try XCTUnwrap(store.workspaces.last)
        XCTAssertEqual(workspace.orderedGroups.count, 3)
    }

    func testMismatchedWeightsFallBackToEvenAndWarn() throws {
        let store = try store()
        let summary = try importing(
            """
            { "workspaces": [{ "title": "Split", "layout": { "children": [
              { "tabs": [{ "directory": "/a" }] },
              { "tabs": [{ "directory": "/b" }] }
            ], "weights": [1] } }] }
            """,
            into: store
        )

        XCTAssertEqual(summary.warnings.count, 1)
        guard case .split(_, _, _, let weights) = try XCTUnwrap(store.workspaces.last).layout else {
            return XCTFail("expected a split layout")
        }
        XCTAssertEqual(weights, [0.5, 0.5])
    }

    func testSingleChildSplitCollapsesToGroup() throws {
        let store = try store()
        try importing(
            """
            { "workspaces": [{ "title": "One", "layout": { "children": [
              { "tabs": [{ "directory": "/a" }] }
            ] } }] }
            """,
            into: store
        )

        guard case .group = try XCTUnwrap(store.workspaces.last).layout else {
            return XCTFail("expected a single child split to collapse to a group")
        }
    }

    func testUrlTabBecomesBrowserTab() throws {
        let store = try store()
        try importing(
            """
            { "workspaces": [{ "title": "Docs", "tabs": [{ "url": "https://example.com/docs" }] }] }
            """,
            into: store
        )

        let tab = try XCTUnwrap(store.workspaces.last?.orderedGroups.first?.tabs.first)
        XCTAssertTrue(tab.isBrowser)
        XCTAssertEqual(tab.browserSession?.url.absoluteString, "https://example.com/docs")
    }

    func testUnreadableBrowserAddressIsSkippedWithWarning() throws {
        let store = try store()
        let summary = try importing(
            """
            { "workspaces": [{ "title": "Mixed", "tabs": [
              { "url": "not a url" }, { "directory": "/a" }
            ] }] }
            """,
            into: store
        )

        XCTAssertEqual(summary.importedTabCount, 1)
        XCTAssertEqual(summary.warnings.count, 1)
        XCTAssertEqual(store.workspaces.last?.orderedGroups.first?.tabs.count, 1)
    }

    func testWorkspaceWithoutTitleFallsBackToDirectoryName() throws {
        let store = try store()
        try importing(
            """
            { "workspaces": [{ "tabs": [{ "directory": "~/code/api" }] }] }
            """,
            into: store
        )

        XCTAssertEqual(store.workspaces.last?.title, "api")
    }

    func testWorkspaceWithoutTabsStillGetsATerminal() throws {
        let store = try store()
        try importing(#"{ "workspaces": [{ "title": "Scratch" }] }"#, into: store)

        let workspace = try XCTUnwrap(store.workspaces.last)
        XCTAssertEqual(workspace.title, "Scratch")
        XCTAssertEqual(workspace.orderedGroups.first?.tabs.count, 1)
    }

    func testImportSelectsTheFirstImportedWorkspace() throws {
        let store = try store()
        try importing(
            """
            { "workspaces": [{ "title": "First" }, { "title": "Second" }] }
            """,
            into: store
        )

        XCTAssertEqual(store.selectedWorkspace.title, "First")
    }

    func testImportingTheSameDocumentTwiceCreatesDistinctWorkspaces() throws {
        let store = try store()
        let json = #"{ "workspaces": [{ "title": "API", "tabs": [{ "directory": "/a" }] }] }"#
        try importing(json, into: store)
        let firstID = try XCTUnwrap(store.workspaces.last?.id)
        try importing(json, into: store)
        let secondID = try XCTUnwrap(store.workspaces.last?.id)

        XCTAssertNotEqual(firstID, secondID)
        XCTAssertEqual(store.workspaces.filter { $0.title == "API" }.count, 2)
    }

    func testImportPersistsAcrossReload() throws {
        let url = temporaryURL()
        let store = try WorkspaceStore(persistenceURL: url)
        try store.importWorkspaces(
            fromJSON: Data(#"{ "workspaces": [{ "title": "API", "tabs": [{ "directory": "/a" }] }] }"#.utf8),
            homeDirectory: home
        )

        let reloaded = try WorkspaceStore(persistenceURL: url)
        XCTAssertEqual(reloaded.workspaces.last?.title, "API")
        XCTAssertEqual(reloaded.selectedWorkspace.title, "API")
    }

    func testEmptyDocumentIsRejected() throws {
        let store = try store()
        XCTAssertThrowsError(try importing(#"{ "workspaces": [] }"#, into: store)) { error in
            XCTAssertEqual(
                error as? WorkspaceStoreError,
                .invalidImportDocument(reason: "the document contains no workspaces")
            )
        }
    }

    func testMalformedJSONIsRejected() throws {
        let store = try store()
        XCTAssertThrowsError(try importing("{ not json", into: store)) { error in
            guard case .invalidImportDocument = error as? WorkspaceStoreError else {
                return XCTFail("expected an invalidImportDocument error, got \(error)")
            }
        }
    }

    func testNewerDocumentVersionIsRejected() throws {
        let store = try store()
        XCTAssertThrowsError(
            try importing(#"{ "version": 99, "workspaces": [{ "title": "API" }] }"#, into: store)
        ) { error in
            guard case .invalidImportDocument(let reason) = error as? WorkspaceStoreError else {
                return XCTFail("expected an invalidImportDocument error, got \(error)")
            }
            XCTAssertTrue(reason.contains("99"), reason)
        }
    }

    func testMalformedWorkspaceEntriesAreSkippedRatherThanFailingTheImport() throws {
        let store = try store()
        let summary = try importing(
            """
            { "workspaces": [ "not an object", { "title": "API", "tabs": [{ "directory": "/a" }] } ] }
            """,
            into: store
        )

        XCTAssertEqual(summary.importedWorkspaceCount, 1)
        XCTAssertEqual(store.workspaces.last?.title, "API")
    }
}

extension WorkspaceImportTests {
    func testStartupCommandsAreReportedAgainstTheirSession() throws {
        let store = try WorkspaceStore(persistenceURL: temporaryURL())
        let summary = try store.importWorkspaces(
            fromJSON: Data(
                """
                { "workspaces": [{ "title": "API", "tabs": [
                  { "directory": "/a", "command": "claude --resume abc123" },
                  { "directory": "/b" }
                ] }] }
                """.utf8
            ),
            homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)
        )

        XCTAssertEqual(summary.startupCommands.count, 1)
        let workspace = try XCTUnwrap(store.workspaces.last)
        let firstSession = try XCTUnwrap(workspace.orderedGroups.first?.tabs.first?.terminalSession)
        XCTAssertEqual(summary.startupCommands[firstSession.id], "claude --resume abc123")
    }

    func testStartupCommandsAreNotPersisted() throws {
        let url = temporaryURL()
        let store = try WorkspaceStore(persistenceURL: url)
        try store.importWorkspaces(
            fromJSON: Data(
                #"{ "workspaces": [{ "title": "API", "tabs": [{ "directory": "/a", "command": "echo hi" }] }] }"#.utf8
            ),
            homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)
        )

        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("echo hi"))
    }

    func testCommandOnABrowserTabIsIgnored() throws {
        let store = try WorkspaceStore(persistenceURL: temporaryURL())
        let summary = try store.importWorkspaces(
            fromJSON: Data(
                #"{ "workspaces": [{ "title": "Docs", "tabs": [{ "url": "https://example.com", "command": "echo hi" }] }] }"#.utf8
            ),
            homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)
        )

        XCTAssertTrue(summary.startupCommands.isEmpty)
    }

    func testTabTitlesSurviveImport() throws {
        let store = try WorkspaceStore(persistenceURL: temporaryURL())
        try store.importWorkspaces(
            fromJSON: Data(
                #"{ "workspaces": [{ "title": "API", "tabs": [{ "directory": "/a", "title": "server" }] }] }"#.utf8
            ),
            homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)
        )

        XCTAssertEqual(store.workspaces.last?.orderedGroups.first?.tabs.first?.customTitle, "server")
    }
}
