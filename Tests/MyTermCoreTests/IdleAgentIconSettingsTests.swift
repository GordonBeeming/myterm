import Foundation
import XCTest
@testable import MyTermCore

final class IdleAgentIconSettingsTests: XCTestCase {
    func testMissingKeyDefaultsOff() throws {
        let preferences = try JSONDecoder().decode(TerminalPreferences.self, from: Data("{}".utf8))
        XCTAssertFalse(preferences.showsIdleAgentIcon)
        XCTAssertFalse(TerminalPreferencesOverrides().applying(to: preferences).showsIdleAgentIcon)
    }

    func testExplicitValuesRoundTrip() throws {
        for enabled in [false, true] {
            let preferences = TerminalPreferences(showsIdleAgentIcon: enabled)
            let restored = try JSONDecoder().decode(TerminalPreferences.self, from: JSONEncoder().encode(preferences))
            XCTAssertEqual(restored.showsIdleAgentIcon, enabled)
            XCTAssertEqual(restored.normalized().showsIdleAgentIcon, enabled)
        }
    }

    /// Agent settings are global only, so every folder and workspace resolves to the global value,
    /// including ones whose files still carry an override from before.
    func testAgentSettingsResolveToTheGlobalValueEverywhere() throws {
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
        try store.updateGlobalSettings {
            $0.showsIdleAgentIcon = true
            $0.restoresAgentSessions = false
            $0.namesTabsFromAgentSessions = false
        }
        try store.flush()

        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var folders = try XCTUnwrap(json["folders"] as? [[String: Any]])
        folders[0]["settingsOverrides"] = [
            "showsIdleAgentIcon": false, "restoresAgentSessions": true, "namesTabsFromAgentSessions": true
        ]
        json["folders"] = folders
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        let restored = try WorkspaceStore(persistenceURL: url)
        let resolved = try restored.resolvedSettings(for: workspaceID)
        XCTAssertTrue(resolved.showsIdleAgentIcon)
        XCTAssertFalse(resolved.restoresAgentSessions)
        XCTAssertFalse(resolved.namesTabsFromAgentSessions)
        XCTAssertEqual(restored.loadReport.structuralRepairCount, 0)
    }

    /// Settings decode lossily like their neighbours: one bad value falls back to its default
    /// instead of failing the whole settings object, which would cost every other setting.
    func testInvalidValueFallsBackInsteadOfFailingTheDecode() throws {
        let data = Data("{\"showsIdleAgentIcon\":\"yes\"}".utf8)
        XCTAssertFalse(try JSONDecoder().decode(TerminalPreferences.self, from: data).showsIdleAgentIcon)
    }
}
