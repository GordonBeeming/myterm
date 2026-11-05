import Foundation
import XCTest
@testable import MyTermCore

@MainActor
final class ChannelConfigurationStoreTests: XCTestCase {
    /// Restoring settings in beta repairs configuration without silently opting the app out of beta.
    func testManualRecoveryPreservesRequestedInstalledChannel() throws {
        let (directory, domain, config) = try fixture()
        _ = try workspace("Stable", at: directory)
        try config.captureStable()
        _ = try workspace("Beta", at: directory)
        try config.restoreBackup(from: directory.appendingPathComponent("last-stable-configuration.json"), selectedChannel: .beta)
        XCTAssertEqual(UserDefaults.standard.persistentDomain(forName: domain)?["updates.selectedChannel"] as? String, "beta")
    }

    /// A failed beta-model load must not flush stale state over the stable snapshot on the next turn.
    func testAbandonedStoreCannotOverwriteRestoredConfiguration() async throws {
        let (directory, _, _) = try fixture()
        let stable = try workspace("Stable", at: directory)
        let url = directory.appendingPathComponent("workspace-state.json")
        let abandoned = try WorkspaceStore(persistenceURL: url)
        try abandoned.renameWorkspace(abandoned.selectedWorkspaceID, title: "Failed beta initialization")
        abandoned.abandonPersistence()
        try stable.write(to: url, options: .atomic)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(try Data(contentsOf: url), stable)
    }

    /// Model-level failures after valid JSON still trigger the promised stable fallback once.
    func testBetaModelLoadFailureRetriesWithStableConfiguration() throws {
        let (directory, _, config) = try fixture()
        _ = try workspace("Stable", at: directory)
        try config.captureStable()
        _ = try workspace("Beta", at: directory)
        try config.beginStableReturn(.tryBeta)
        var attempts = 0
        let (name, notice) = try config.loadStable {
            attempts += 1
            let store = try WorkspaceStore(persistenceURL: directory.appendingPathComponent("workspace-state.json"))
            if store.selectedWorkspace.title == "Beta" {
                throw NSError(domain: "InjectedModelLoad", code: 1)
            }
            return store.selectedWorkspace.title
        }
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(name, "Stable")
        XCTAssertTrue(try XCTUnwrap(notice).contains("failed during stable startup"))
        XCTAssertNil(try config.prepareStableLaunch())
    }

    private func fixture() throws -> (URL, String, ChannelConfigurationStore) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let domain = "ChannelConfigurationTests.\(UUID().uuidString)"
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: domain)
            try FileManager.default.removeItem(at: directory)
        }
        return (directory, domain, ChannelConfigurationStore(directory: directory, preferencesDomain: domain))
    }

    private func workspace(_ title: String, at directory: URL) throws -> Data {
        let workspace = Workspace(title: title)
        let data = try JSONEncoder().encode(WorkspaceStoreSnapshot(workspaces: [workspace], selectedWorkspaceID: workspace.id))
        try data.write(to: directory.appendingPathComponent("workspace-state.json"), options: .atomic)
        return data
    }

    /// Restoring stable must preserve the rejected beta bytes and restore preferences as well.
    func testRestoreStableReplacesBetaWorkspaceAndPreferences() throws {
        let (directory, domain, config) = try fixture()
        let stable = try workspace("Stable", at: directory)
        UserDefaults.standard.setPersistentDomain(["theme": "stable"], forName: domain)
        try config.captureStable()
        _ = try workspace("Beta", at: directory)
        UserDefaults.standard.setPersistentDomain(["theme": "beta", "betaOnly": true], forName: domain)
        try config.beginStableReturn(.restoreStable)
        XCTAssertNotNil(try config.prepareStableLaunch())
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("workspace-state.json")), stable)
        let preferences = UserDefaults.standard.persistentDomain(forName: domain)
        XCTAssertEqual(preferences?["theme"] as? String, "stable")
        XCTAssertNil(preferences?["betaOnly"])
        XCTAssertEqual(preferences?["updates.selectedChannel"] as? String, "stable")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("beta-configuration-before-stable.json").path))
        try config.completeStableLaunch()
        XCTAssertNil(try config.prepareStableLaunch(), "The pending switch is consumed only after success")
    }

    /// A compatible beta configuration is retained byte-for-byte when the user chooses it.
    func testTryCompatibleBetaDoesNotRestoreStable() throws {
        let (directory, _, config) = try fixture()
        _ = try workspace("Stable", at: directory)
        try config.captureStable()
        let beta = try workspace("Beta", at: directory)
        try config.beginStableReturn(.tryBeta)
        XCTAssertNil(try config.prepareStableLaunch())
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("workspace-state.json")), beta)
    }

    /// Unsupported future schemas must fall back before WorkspaceStore can repair or overwrite them.
    func testTryUnsupportedBetaRestoresStableAndExplainsFallback() throws {
        let (directory, _, config) = try fixture()
        let stable = try workspace("Stable", at: directory)
        try config.captureStable()
        let incompatible = Data(#"{"version":9999,"workspaces":[]}"#.utf8)
        try incompatible.write(to: directory.appendingPathComponent("workspace-state.json"))
        try config.beginStableReturn(.tryBeta)
        let message = try XCTUnwrap(config.prepareStableLaunch())
        XCTAssertTrue(message.contains("beta configuration could not be loaded"))
        XCTAssertTrue(message.contains("last stable configuration"))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("workspace-state.json")), stable)
        let preserved = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("beta-configuration-before-stable.json"))) as? [String: Any]
        XCTAssertEqual((preserved?["workspace"] as? String).flatMap { Data(base64Encoded: $0) }, incompatible)
    }

    /// A damaged fallback must never replace the only remaining beta configuration.
    func testCorruptStableSnapshotKeepsCompatibleBetaAndQuarantinesMarker() throws {
        let (directory, _, config) = try fixture()
        _ = try workspace("Stable", at: directory)
        try config.captureStable()
        let beta = try workspace("Beta", at: directory)
        try Data("broken".utf8).write(to: directory.appendingPathComponent("last-stable-configuration.json"))
        try config.beginStableReturn(.restoreStable)
        XCTAssertTrue(try XCTUnwrap(config.prepareStableLaunch()).contains("Kept your compatible current configuration"))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("workspace-state.json")), beta)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("pending-stable-configuration.json").path))
    }

    /// If neither configuration can be decoded, manual recovery remains available without data loss.
    func testManualRecoveryCanEscapeAnInvalidBetaAndInvalidStableSnapshot() throws {
        let (directory, _, config) = try fixture()
        let stable = try workspace("Stable", at: directory)
        try config.captureStable()
        let saved = directory.appendingPathComponent("known-good-backup.json")
        try FileManager.default.copyItem(at: directory.appendingPathComponent("last-stable-configuration.json"), to: saved)
        try Data("bad snapshot".utf8).write(to: directory.appendingPathComponent("last-stable-configuration.json"))
        try Data("bad beta".utf8).write(to: directory.appendingPathComponent("workspace-state.json"))
        try config.beginStableReturn(.tryBeta)
        XCTAssertThrowsError(try config.prepareStableLaunch())
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("pending-stable-configuration.json").path))
        try config.restoreBackup(from: saved)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("workspace-state.json")), stable)
        XCTAssertNil(try config.prepareStableLaunch())
    }

    /// A missing beta state is an incompatible configuration, not permission to start empty.
    func testMissingBetaWorkspaceFallsBackToStable() throws {
        let (directory, _, config) = try fixture()
        let stable = try workspace("Stable", at: directory)
        try config.captureStable()
        try FileManager.default.removeItem(at: directory.appendingPathComponent("workspace-state.json"))
        try config.beginStableReturn(.tryBeta)
        XCTAssertNotNil(try config.prepareStableLaunch())
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("workspace-state.json")), stable)
    }
}
