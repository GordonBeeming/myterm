import Foundation
import XCTest
@testable import MyTermCore

/// The workspace state file across builds: what this build makes of a file the previous one wrote,
/// and what an older decoder would make of a file this one writes.
///
/// Fixtures are built from this build's encoder and then reshaped by hand to the other build's
/// schema, read from its decoders, rather than by checking that build out.
final class WorkspaceStoreCompatibilityTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-compat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var stateURL: URL { directory.appendingPathComponent("workspace-state.json") }

    /// The keys this build added after `466ed05` (origin/main), by the object they live in.
    private static let settingsKeysAddedSinceMain = ["restoresAgentSessions", "namesTabsFromAgentSessions"]
    private static let sessionKeysAddedSinceMain = ["agentSession", "agentTitle"]

    private func snapshotWithAnAgentSession() throws -> (WorkspaceStoreSnapshot, [String: Any]) {
        let store = try WorkspaceStore(persistenceURL: stateURL)
        let workspace = store.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)
        try store.updateTerminalAgentSession(
            workspaceID: workspace.id, tabGroupID: group.id, tabID: group.selectedTabID,
            agentSession: AgentSessionHandle(agent: "claude", sessionID: "87d84ef0-4227-42d8-92e3-3dafcf13979f")
        )
        try store.updateTerminalAgentTitle(
            workspaceID: workspace.id, tabGroupID: group.id, tabID: group.selectedTabID, agentTitle: "Fix the build"
        )
        try store.updateGlobalSettings { $0.restoresAgentSessions = false }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        return (store.snapshot, json)
    }

    /// Rewrites the file to the shape `466ed05` wrote: every key added since is removed, wherever
    /// it appears.
    private func reshapedToMain(_ json: [String: Any]) -> [String: Any] {
        func strip(_ value: Any) -> Any {
            if var object = value as? [String: Any] {
                for key in Self.settingsKeysAddedSinceMain + Self.sessionKeysAddedSinceMain {
                    object.removeValue(forKey: key)
                }
                return object.mapValues(strip)
            }
            if let list = value as? [Any] { return list.map(strip) }
            return value
        }
        return strip(json) as! [String: Any]
    }

    /// The first workspace's only group, as the file lays it out: `layout.group.tabs`.
    private func editingTabs(of json: [String: Any], _ edit: (inout [[String: Any]]) throws -> Void) throws -> [String: Any] {
        var json = json
        var workspaces = try XCTUnwrap(json["workspaces"] as? [[String: Any]])
        var layout = try XCTUnwrap(workspaces[0]["layout"] as? [String: Any])
        var group = try XCTUnwrap(layout["group"] as? [String: Any])
        var tabs = try XCTUnwrap(group["tabs"] as? [[String: Any]])
        try edit(&tabs)
        group["tabs"] = tabs
        layout["group"] = group
        workspaces[0]["layout"] = layout
        json["workspaces"] = workspaces
        return json
    }

    // MARK: - A file from origin/main read by this build

    func testAFileFromOriginMainLoadsCleanWithDefaultsAndNoRepairNotice() throws {
        let (_, json) = try snapshotWithAnAgentSession()
        let older = reshapedToMain(json)
        try JSONSerialization.data(withJSONObject: older).write(to: stateURL)

        let store = try WorkspaceStore(persistenceURL: stateURL)
        XCTAssertEqual(store.loadReport.structuralRepairCount, 0)
        XCTAssertEqual(store.loadReport.identifierRepairCount, 0)
        XCTAssertEqual(store.loadReport.droppedElementCount, 0)
        XCTAssertEqual(store.loadReport.backupURLs, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.recoveryBackupURL.path))
        XCTAssertTrue(store.globalSettings.restoresAgentSessions, "a setting the file predates is its default")
        XCTAssertTrue(store.globalSettings.namesTabsFromAgentSessions)
        let session = try XCTUnwrap(store.selectedWorkspace.orderedGroups.first?.tabs.first?.terminalSession)
        XCTAssertNil(session.agentSession)
        XCTAssertNil(session.agentTitle)
    }

    func testAFileFromOriginMainWithScopedOverridesLoadsClean() throws {
        let store = try WorkspaceStore(persistenceURL: stateURL)
        let workspace = store.selectedWorkspace
        try store.updateWorkspaceSettings(workspace.id) { $0.scrollbackLines = 5_000 }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        try JSONSerialization.data(withJSONObject: reshapedToMain(json)).write(to: stateURL)

        let reloaded = try WorkspaceStore(persistenceURL: stateURL)
        XCTAssertEqual(reloaded.loadReport.structuralRepairCount, 0)
        XCTAssertEqual(try reloaded.resolvedSettings(for: workspace.id).scrollbackLines, 5_000)
        XCTAssertNil(reloaded.selectedWorkspace.settingsOverrides?.restoresAgentSessions)
    }

    // MARK: - A file from this build read by origin/main's decoders

    /// `466ed05` decodes a keyed container and ignores what it does not know, so nothing fails.
    /// But it then re-encodes the snapshot and counts every difference from the original as a
    /// structural repair, and a key it does not know is a difference. The same code runs here
    /// against a key from a build newer than this one, so this is the downgrade seen from the
    /// other side: the file this build writes gives the previous build a "state repaired" banner,
    /// a recovery backup, and a rewrite that drops the agent sessions.
    func testAKeyFromANewerBuildIsNotARepair() throws {
        var (_, json) = try snapshotWithAnAgentSession()
        var workspaces = try XCTUnwrap(json["workspaces"] as? [[String: Any]])
        workspaces[0]["colourTheme"] = "aurora"
        json["workspaces"] = workspaces
        var settings = try XCTUnwrap(json["globalSettings"] as? [String: Any])
        settings["ligatures"] = true
        json["globalSettings"] = settings
        try JSONSerialization.data(withJSONObject: json).write(to: stateURL)

        let store = try WorkspaceStore(persistenceURL: stateURL)
        // A key no decoder in this build knows is a newer file, not a broken one: no banner, no
        // backup, and the file loads.
        XCTAssertEqual(store.loadReport.structuralRepairCount, 0)
        XCTAssertEqual(store.loadReport.backupURLs, [])
        XCTAssertEqual(store.workspaces.count, 1)
    }

    func testAnAgentSessionThisBuildRefusesIsDroppedWithoutARepairNotice() throws {
        // An identifier a newer build might accept and this one does not. The handle is decoded
        // with `try?`, so the pane loses its resume and the load stays clean.
        let (_, json) = try snapshotWithAnAgentSession()
        let edited = try editingTabs(of: json) { tabs in
            var content = try XCTUnwrap(tabs[0]["content"] as? [String: Any])
            var terminal = try XCTUnwrap(content["session"] as? [String: Any])
            terminal["agentSession"] = ["agent": "claude", "sessionID": "id with spaces; rm -rf /"]
            content["session"] = terminal
            tabs[0]["content"] = content
        }
        try JSONSerialization.data(withJSONObject: edited).write(to: stateURL)

        let store = try WorkspaceStore(persistenceURL: stateURL)
        let session = try XCTUnwrap(store.selectedWorkspace.orderedGroups.first?.tabs.first?.terminalSession)
        XCTAssertNil(session.agentSession)
        XCTAssertEqual(session.agentTitle, "Fix the build")
    }

    func testAnUnknownTabKindFromANewerBuildIsDroppedAndBackedUp() throws {
        let (_, json) = try snapshotWithAnAgentSession()
        let edited = try editingTabs(of: json) { tabs in
            var notebook = tabs[0]
            notebook["id"] = UUID().uuidString.lowercased()
            notebook["content"] = ["type": "notebook", "session": ["path": "/tmp/a.ipynb"]]
            tabs.append(notebook)
        }
        try JSONSerialization.data(withJSONObject: edited).write(to: stateURL)

        let store = try WorkspaceStore(persistenceURL: stateURL)
        XCTAssertEqual(store.loadReport.droppedElementCount, 1)
        XCTAssertEqual(store.loadReport.backupURLs, [store.recoveryBackupURL])
        XCTAssertEqual(store.selectedWorkspace.orderedGroups.first?.tabs.count, 1)
    }

    func testAVersionNewerThanThisBuildIsRefusedRatherThanRewritten() throws {
        var (_, json) = try snapshotWithAnAgentSession()
        json["version"] = WorkspaceStoreSnapshot.currentVersion + 1
        let bytes = try JSONSerialization.data(withJSONObject: json)
        try bytes.write(to: stateURL)
        XCTAssertThrowsError(try WorkspaceStore(persistenceURL: stateURL))
        XCTAssertEqual(try Data(contentsOf: stateURL), bytes, "a refused file is left exactly as it was")
    }
}
