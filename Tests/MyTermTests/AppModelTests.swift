@testable import MyTerm
import Foundation
import XCTest

@MainActor
final class AppModelTests: XCTestCase {
    func testChannelsUseSeparateNamesBundleIdentifiersAndPersistencePaths() {
        let supportDirectory = URL(fileURLWithPath: "/tmp/myterm-tests", isDirectory: true)

        XCTAssertEqual(MyTermChannel.development.displayName, "myterm-dev")
        XCTAssertEqual(MyTermChannel.development.bundleIdentifier, "com.gordonbeeming.myterm.dev")
        XCTAssertEqual(MyTermChannel.production.displayName, "myterm")
        XCTAssertEqual(MyTermChannel.production.bundleIdentifier, "com.gordonbeeming.myterm")
        XCTAssertNotEqual(
            MyTermChannel.development.persistenceURL(applicationSupportDirectory: supportDirectory),
            MyTermChannel.production.persistenceURL(applicationSupportDirectory: supportDirectory)
        )
    }

    func testModelCreatesTabsAndSplitsWithoutStartingAProcess() throws {
        let directory = try makeTemporaryDirectory()
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                XCTFail("Could not remove temporary directory: \(error.localizedDescription)")
            }
        }

        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: nil,
            startsTerminalProcesses: false
        )

        let initialWorkspaceID = model.store.selectedWorkspaceID
        let initialTab = try XCTUnwrap(model.selectedTab)
        model.splitFocusedTerminal(orientation: .horizontal)

        let splitTab = try XCTUnwrap(model.selectedTab)
        XCTAssertEqual(splitTab.terminalTree?.terminalSessions.count, 2)

        model.createWorkspace()
        XCTAssertEqual(model.workspaces.count, 2)
        XCTAssertNotEqual(model.store.selectedWorkspaceID, initialWorkspaceID)

        model.selectWorkspace(initialWorkspaceID)
        model.selectTab(initialTab.id)
        model.closeFocusedPaneOrTab()
        XCTAssertEqual(model.workspaces.first(where: { $0.id == initialWorkspaceID })?.tabs.count, 1)
    }

    func testCloseTabRemovesAnEntireSplitTerminalTabWithoutStartingProcesses() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }

        let model = try makeModel(applicationSupportDirectory: directory)
        let workspaceID = model.store.selectedWorkspaceID
        let tab = try XCTUnwrap(model.selectedTab)
        model.splitFocusedTerminal(orientation: .horizontal)

        let splitSessionIDs = try XCTUnwrap(model.selectedTab?.terminalTree?.terminalSessionIDs)
        XCTAssertEqual(splitSessionIDs.count, 2)
        XCTAssertTrue(splitSessionIDs.allSatisfy { model.terminalSession(for: $0) == nil })

        model.closeTab(tab.id)

        let workspace = try XCTUnwrap(model.workspaces.first(where: { $0.id == workspaceID }))
        XCTAssertFalse(workspace.tabs.contains(where: { $0.id == tab.id }))
        XCTAssertTrue(splitSessionIDs.allSatisfy { model.terminalSession(for: $0) == nil })
        XCTAssertNil(model.errorDescription)
    }

    func testCloseFocusedPaneCollapsesOnlyOnePaneInSplitTerminalTab() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }

        let model = try makeModel(applicationSupportDirectory: directory)
        let tab = try XCTUnwrap(model.selectedTab)
        model.splitFocusedTerminal(orientation: .vertical)

        model.closeFocusedPaneOrTab()

        let remainingTab = try XCTUnwrap(model.selectedTab)
        XCTAssertEqual(remainingTab.id, tab.id)
        XCTAssertEqual(remainingTab.terminalTree?.terminalSessions.count, 1)
        XCTAssertNil(model.errorDescription)
    }

    private func makeModel(applicationSupportDirectory: URL) throws -> AppModel {
        try AppModel(
            channel: .development,
            applicationSupportDirectory: applicationSupportDirectory,
            terminalEngine: nil,
            startsTerminalProcesses: false
        )
    }

    private func removeTemporaryDirectory(_ directory: URL) {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            XCTFail("Could not remove temporary directory: \(error.localizedDescription)")
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
