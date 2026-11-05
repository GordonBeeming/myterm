import Foundation
import Darwin
import XCTest
import MyTermCore
@testable import MyTermUpdating

@MainActor
final class ApplicationUpdateTests: XCTestCase {
    /// LaunchServices success alone cannot commit a build that never acknowledges startup.
    func testMissingStartupAcknowledgementRollsBackAppAndConfiguration() throws {
        let plan = try fixture()
        let workspace = plan.configurationDirectory.appendingPathComponent("workspace-state.json")
        let original = try Data(contentsOf: workspace)
        XCTAssertThrowsError(try ApplicationUpdate.apply(plan, validateBundle: { _, _, _ in }, preflight: { _ in }, launch: { _ in
            try Data("failed beta startup changed state".utf8).write(to: workspace)
            throw ApplicationUpdateError.startupFailed("Injected missing startup acknowledgement")
        }))
        XCTAssertEqual(try String(contentsOf: plan.target.appendingPathComponent("version.txt"), encoding: .utf8), plan.sourceVersion)
        XCTAssertEqual(try Data(contentsOf: workspace), original)
        XCTAssertEqual(UserDefaults.standard.persistentDomain(forName: plan.preferencesDomain)?["updates.selectedChannel"] as? String, "stable")
        XCTAssertNil(UpdateStartupTrial.activeManifest(in: plan.configurationDirectory))
        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.directory.appendingPathComponent("failed-configuration.json").path))
    }

    /// Readiness is bound to this trial nonce, and commit consumes the deferred trial marker.
    func testLoadedStartupAcknowledgementCommitsDeferredTrial() throws {
        let plan = try fixture()
        try UpdateStartupTrial.begin(plan)
        XCTAssertEqual(UpdateStartupTrial.activeManifest(in: plan.configurationDirectory), plan.manifestURL)
        try UpdateStartupTrial.report(.loaded, plan: plan)
        XCTAssertNoThrow(try UpdateStartupTrial.waitForStartup(plan, seconds: 0.1))
        try UpdateStartupTrial.commit(plan)
        XCTAssertNil(UpdateStartupTrial.activeManifest(in: plan.configurationDirectory))
        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.directory.appendingPathComponent("applied").path))
    }

    /// Configuration can change after staging; the final preflight must run before any exchange.
    func testFinalConfigurationPreflightFailureLeavesInstalledAppInPlace() throws {
        let plan = try fixture()
        XCTAssertThrowsError(try ApplicationUpdate.apply(plan, validateBundle: { _, _, _ in }, preflight: { _ in
            throw ApplicationUpdateError.invalid("Configuration changed after preparation")
        }, exchange: { _, _ in XCTFail("Must not exchange an incompatible final configuration") }))
        XCTAssertEqual(try String(contentsOf: plan.target.appendingPathComponent("version.txt"), encoding: .utf8), plan.sourceVersion)
    }

    /// Mach-O architecture checks work on ordinary Macs without lipo or Xcode tools.
    func testArm64HeaderInspectionHandlesThinAndRejectsInvalidData() throws {
        let plan = try fixture()
        let file = plan.directory.appendingPathComponent("macho")
        try Data([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0x00, 0x00, 0x01] + [UInt8](repeating: 0, count: 24)).write(to: file)
        XCTAssertTrue(try ApplicationUpdate.containsArm64(file))
        try Data("invalid".utf8).write(to: file)
        XCTAssertFalse(try ApplicationUpdate.containsArm64(file))
    }
    /// Interrupted downloads are safe to prune only after their creator has exited.
    func testOrphanStagingCleanupKeepsLiveOwnersAndRemovesDeadOwners() throws {
        let plan = try fixture()
        var info = proc_bsdinfo()
        XCTAssertEqual(proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)), Int32(MemoryLayout<proc_bsdinfo>.size))
        let marker = plan.directory.appendingPathComponent("stage-owner.json")
        let live: [String: Any] = ["target": plan.target.absoluteString, "pid": getpid(),
                                   "startSeconds": info.pbi_start_tvsec, "startMicroseconds": info.pbi_start_tvusec]
        try JSONSerialization.data(withJSONObject: live).write(to: marker)
        try FileManager.default.removeItem(at: plan.manifestURL)
        ApplicationUpdate.pruneCompletedUpdates(for: plan.target, preferencesDomain: plan.preferencesDomain)
        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.directory.path))
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run()
        child.waitUntilExit()
        let gone: [String: Any] = ["target": plan.target.absoluteString, "pid": child.processIdentifier,
                                   "startSeconds": 0, "startMicroseconds": 0]
        try JSONSerialization.data(withJSONObject: gone).write(to: marker)
        ApplicationUpdate.pruneCompletedUpdates(for: plan.target, preferencesDomain: plan.preferencesDomain)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.directory.path))
    }

    /// A competing launch that already mapped the old executable must recognize the atomic replacement.
    func testRunningCodeIdentityTracksOriginalInodeAfterReplacement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let product = Bundle(for: ApplicationUpdateTests.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("MyTermUpdateAgent")
        let current = root.appendingPathComponent("current.app")
        let replacement = root.appendingPathComponent("replacement.app")
        let gate = root.appendingPathComponent("gate")
        for (app, version) in [(current, "1"), (replacement, "2")] {
            let binaries = app.appendingPathComponent("Contents/MacOS")
            try FileManager.default.createDirectory(at: binaries, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: product, to: binaries.appendingPathComponent("agent"))
            let info = ["CFBundleIdentifier": "com.gordonbeeming.update.fixture", "CFBundleExecutable": "agent",
                        "CFBundlePackageType": "APPL", "CFBundleVersion": version]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: app.appendingPathComponent("Contents/Info.plist"))
            try ApplicationUpdate.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        }
        let process = Process(), output = Pipe()
        process.executableURL = current.appendingPathComponent("Contents/MacOS/agent")
        process.arguments = ["--test-running-code", current.path, gate.path]
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        output.fileHandleForWriting.closeFile()
        XCTAssertEqual(try output.fileHandleForReading.read(upToCount: 6), Data("ready\n".utf8))
        try ApplicationUpdate.exchange(current, replacement)
        try Data().write(to: gate)
        let result = try output.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: result, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), "replaced")
    }

    /// A hung verification tool must leave the app usable instead of blocking an update forever.
    func testVerificationCommandHasABoundedDeadline() {
        let started = ContinuousClock.now
        XCTAssertThrowsError(try ApplicationUpdate.run("/bin/sh", ["-c", "exec /bin/sleep 20"], timeout: 0.1))
        XCTAssertLessThan(started.duration(to: .now), .seconds(12))
    }

    /// The exit watcher observes the actual process event rather than treating permissions as exit.
    func testExitWatcherObservesChildAndDoesNotAcceptATimeout() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["20"]
        try child.run()
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        XCTAssertThrowsError(try ApplicationUpdate.waitForExit(child.processIdentifier, seconds: 0))
        XCTAssertTrue(child.isRunning)
        child.terminate()
        try ApplicationUpdate.waitForExit(child.processIdentifier, seconds: 2)
        child.waitUntilExit()
        XCTAssertFalse(child.isRunning)
    }

    private func fixture(source: UpdateCheck.Channel = .stable, target: UpdateCheck.Channel = .beta) throws -> ApplicationUpdatePlan {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let directory = root.appendingPathComponent(".myterm-update-\(UUID().uuidString).noindex")
        let installed = root.appendingPathComponent("installed.app")
        let staged = directory.appendingPathComponent("myterm.app")
        let config = root.appendingPathComponent("myterm")
        for url in [directory, installed, staged, config] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let domain = "UpdateTransactionTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: domain) }
        let workspace = Workspace(title: "Original")
        try JSONEncoder().encode(WorkspaceStoreSnapshot(workspaces: [workspace], selectedWorkspaceID: workspace.id))
            .write(to: config.appendingPathComponent("workspace-state.json"))
        let sourceVersion = source == .stable ? "0.68" : "0.0.120"
        let version = target == .stable ? "0.68" : "0.0.121"
        for (url, value, channel) in [(installed, sourceVersion, source), (staged, version, target)] {
            try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": value,
                "MyTermReleaseChannel": channel.rawValue], format: .xml, options: 0)
                .write(to: url.appendingPathComponent("Contents/Info.plist"))
            try Data(value.utf8).write(to: url.appendingPathComponent("version.txt"))
        }
        let plan = ApplicationUpdatePlan(target: installed, staged: staged, directory: directory,
            version: version, sourceVersion: sourceVersion, sourceChannel: source, channel: target,
            configurationDirectory: config, preferencesDomain: domain)
        try plan.save()
        return plan
    }

    /// The real filesystem swap must restore the prior bundle when relaunch fails.
    func testFailedLaunchRollsBackAppPreferencesAndPendingConfiguration() throws {
        var plan = try fixture(source: .beta, target: .stable)
        plan.stableChoice = .tryBeta
        let config = ChannelConfigurationStore(directory: plan.configurationDirectory, preferencesDomain: plan.preferencesDomain)
        try config.captureStable()
        UserDefaults.standard.setPersistentDomain(["kept": "beta", "updates.stagedManifest": plan.manifestURL.path], forName: plan.preferencesDomain)
        XCTAssertThrowsError(try ApplicationUpdate.apply(plan, validateBundle: { _, _, _ in }, preflight: { _ in }, launch: { _ in
            throw ApplicationUpdateError.invalid("Injected launch failure")
        }))
        XCTAssertEqual(try String(contentsOf: plan.target.appendingPathComponent("version.txt"), encoding: .utf8), plan.sourceVersion)
        XCTAssertEqual(UserDefaults.standard.persistentDomain(forName: plan.preferencesDomain)?["kept"] as? String, "beta")
        XCTAssertEqual(UserDefaults.standard.persistentDomain(forName: plan.preferencesDomain)?["updates.stagedManifest"] as? String, plan.manifestURL.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.configurationDirectory.appendingPathComponent("pending-stable-configuration.json").path))
    }

    /// A failed atomic replacement must not arm a config restore for a later unrelated launch.
    func testFailedSwapDoesNotScheduleStableRestore() throws {
        var plan = try fixture(source: .beta, target: .stable)
        plan.stableChoice = .restoreStable
        XCTAssertThrowsError(try ApplicationUpdate.apply(plan, validateBundle: { _, _, _ in }, preflight: { _ in }, exchange: { _, _ in
            throw ApplicationUpdateError.invalid("Injected unsupported volume")
        }, launch: { _ in XCTFail("Must not launch after a failed swap") }))
        XCTAssertEqual(try String(contentsOf: plan.target.appendingPathComponent("version.txt"), encoding: .utf8), plan.sourceVersion)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.configurationDirectory.appendingPathComponent("pending-stable-configuration.json").path))
    }

    /// Normal quit installs without reopening; entering beta captures a usable stable snapshot.
    func testSuccessfulQuietInstallKeepsStableSnapshotAndAppliesTarget() throws {
        var plan = try fixture()
        plan.relaunch = false
        try ApplicationUpdate.apply(plan, validateBundle: { _, _, _ in }, preflight: { _ in }, launch: { _ in XCTFail("Normal quit must stay closed") })
        XCTAssertEqual(try String(contentsOf: plan.target.appendingPathComponent("version.txt"), encoding: .utf8), plan.version)
        XCTAssertTrue(ChannelConfigurationStore(directory: plan.configurationDirectory, preferencesDomain: plan.preferencesDomain).hasStableSnapshot)
        XCTAssertEqual(UserDefaults.standard.persistentDomain(forName: plan.preferencesDomain)?["updates.selectedChannel"] as? String, "beta")
    }

    /// A stale plan must not replace an app another updater has already changed.
    func testChangedSourceAppIsRejectedBeforeSwap() throws {
        let plan = try fixture()
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "0.69", "MyTermReleaseChannel": "stable"], format: .xml, options: 0)
            .write(to: plan.target.appendingPathComponent("Contents/Info.plist"))
        XCTAssertThrowsError(try ApplicationUpdate.apply(plan, validateBundle: { _, _, _ in }, preflight: { _ in }, exchange: { _, _ in
            XCTFail("Source mismatch must be detected before swapping")
        }))
    }

    /// The production trust requirement rejects another publisher even with a valid Apple signature.
    func testAppleSystemBinaryDoesNotMeetMyTermDeveloperIDRequirement() {
        XCTAssertThrowsError(try ApplicationUpdate.verifySignature(URL(fileURLWithPath: "/bin/sh"), identifier: ApplicationUpdate.bundleIdentifier))
    }

    /// Older shells can add completion caches without changing the installed executable's identity.
    func testInstalledProductionIdentityMeetsDeveloperIDRequirementWhenAvailable() throws {
        let app = URL(fileURLWithPath: "/Applications/myterm.app")
        guard FileManager.default.fileExists(atPath: app.path) else { throw XCTSkip("No installed production app on this runner") }
        try ApplicationUpdate.verifyInstalledIdentity(app)
    }

    /// Streaming the archive hash must agree with a known digest, independent of signing validation.
    func testDownloadDigestUsesActualFileBytes() throws {
        let plan = try fixture()
        let file = plan.directory.appendingPathComponent("bytes")
        try Data("abc".utf8).write(to: file)
        XCTAssertEqual(try ApplicationUpdate.digest(file), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
