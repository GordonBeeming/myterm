import Foundation
import XCTest
@testable import MyTermCore

final class IdleAgentIconSettingsTests: XCTestCase {
    func testMissingKeyDefaultsOffAndOverrideInherits() throws {
        let preferences = try JSONDecoder().decode(TerminalPreferences.self, from: Data("{}".utf8))
        let overrides = try JSONDecoder().decode(TerminalPreferencesOverrides.self, from: Data("{}".utf8))
        XCTAssertFalse(preferences.showsIdleAgentIcon)
        XCTAssertNil(overrides.showsIdleAgentIcon)
        XCTAssertFalse(overrides.applying(to: preferences).showsIdleAgentIcon)
    }

    func testExplicitValuesRoundTripAndOverrideGlobalInBothDirections() throws {
        for enabled in [false, true] {
            let preferences = TerminalPreferences(showsIdleAgentIcon: enabled)
            let restored = try JSONDecoder().decode(TerminalPreferences.self, from: JSONEncoder().encode(preferences))
            XCTAssertEqual(restored.showsIdleAgentIcon, enabled)
            XCTAssertEqual(restored.normalized().showsIdleAgentIcon, enabled)

            var overrides = TerminalPreferencesOverrides()
            overrides.showsIdleAgentIcon = !enabled
            let restoredOverrides = try JSONDecoder().decode(
                TerminalPreferencesOverrides.self, from: JSONEncoder().encode(overrides)
            )
            XCTAssertEqual(restoredOverrides.applying(to: restored).showsIdleAgentIcon, !enabled)
        }
    }

    func testWorkspaceOverridesFolderAndResetRestoresInheritanceAfterReload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Could not remove test directory: \(error)") }
        }
        let url = directory.appendingPathComponent("state.json")
        let store = try WorkspaceStore(persistenceURL: url)
        let folderID = try store.createFolder(title: "Juniper", color: .teal)
        let workspaceID = try store.createWorkspace(title: "Workbench", folderID: folderID)
        try store.updateGlobalSettings { $0.showsIdleAgentIcon = false }
        try store.updateFolderSettings(folderID) { $0.showsIdleAgentIcon = true }
        XCTAssertTrue(try store.resolvedSettings(for: workspaceID).showsIdleAgentIcon)
        try store.updateWorkspaceSettings(workspaceID) { $0.showsIdleAgentIcon = false }
        try store.flush()

        let restored = try WorkspaceStore(persistenceURL: url)
        XCTAssertFalse(try restored.resolvedSettings(for: workspaceID).showsIdleAgentIcon)
        try restored.updateWorkspaceSettings(workspaceID) { $0.showsIdleAgentIcon = nil }
        XCTAssertTrue(try restored.resolvedSettings(for: workspaceID).showsIdleAgentIcon)
        try restored.updateFolderSettings(folderID) { $0.showsIdleAgentIcon = nil }
        XCTAssertFalse(try restored.resolvedSettings(for: workspaceID).showsIdleAgentIcon)
    }

    /// Settings decode lossily like their neighbours: one bad value falls back to its default
    /// instead of failing the whole settings object, which would cost every other setting.
    func testInvalidValueFallsBackInsteadOfFailingTheDecode() throws {
        let data = Data("{\"showsIdleAgentIcon\":\"yes\"}".utf8)
        XCTAssertFalse(try JSONDecoder().decode(TerminalPreferences.self, from: data).showsIdleAgentIcon)
        XCTAssertNil(try JSONDecoder().decode(TerminalPreferencesOverrides.self, from: data).showsIdleAgentIcon)
    }
}
