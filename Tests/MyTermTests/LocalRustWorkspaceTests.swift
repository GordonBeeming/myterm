#if DEBUG
@testable import MyTerm
@testable import MyTermPlatform
import Darwin
import Foundation
import MyTermContinuity
import MyTermCore
import XCTest

@MainActor
final class LocalRustWorkspaceTests: XCTestCase {
    func testFailedRustStopKeepsThePaneAndItsSavedSelection() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mt-" + String(UUID().uuidString.prefix(8)), isDirectory: true)
        let selectionDirectory = directory.appendingPathComponent("selection", isDirectory: true)
        try FileManager.default.createDirectory(at: selectionDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let engine = LocalRustWorkspaceTerminalEngine(namespace: selectionDirectory) { _ in
            throw LocalRustTerminalError.server("Test registry is unavailable")
        }
        let model = try AppModel(applicationSupportDirectory: directory, terminalEngine: engine,
                                 startsTerminalProcesses: false, confirmClosingActiveProcesses: { _ in true })
        let tab = try XCTUnwrap(model.selectedTab)
        let sessionID = try XCTUnwrap(tab.terminalSession?.id)
        let selectionURL = selectionDirectory.appendingPathComponent(sessionID.rawValue.uuidString + ".json")
        let selection = LocalRustWorkspaceBackend.Selection(sessionID: UUID(), clientID: UUID())
        try JSONEncoder().encode(selection).write(to: selectionURL)

        model.closeTab(tab.id)

        try await until("the failed stop is reported") { model.errorDescription == "Test registry is unavailable" }
        XCTAssertNotNil(model.selectedWorkspace.tab(id: tab.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: selectionURL.path))
    }

    func testNormalTabsAndSplitsUseSeparateRustOwnedShellsAndKeepSavedOwnership() async throws {
        guard let executable = ProcessInfo.processInfo.environment["MYTERM_TEST_RUST_WORKSPACE_SERVER"] else {
            throw XCTSkip("Set MYTERM_TEST_RUST_WORKSPACE_SERVER to a private Rust test daemon.")
        }
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mt-" + String(UUID().uuidString.prefix(8)), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }

        let socket = directory.appendingPathComponent("daemon.sock")
        let daemon = Process()
        daemon.executableURL = URL(fileURLWithPath: executable)
        daemon.arguments = [socket.path]
        try daemon.run()
        defer {
            if daemon.isRunning { daemon.terminate() }
            daemon.waitUntilExit()
        }

        try await until("the Rust daemon opens its socket") {
            FileManager.default.fileExists(atPath: socket.path)
        }

        let engine = LocalRustWorkspaceTerminalEngine(namespace: directory.appendingPathComponent("selection")) { _ in
            let descriptor: Int32
            do {
                descriptor = try SessionHostSocket.connect(path: socket.path)
            } catch SessionHostError.system("connect", let code) where code == ENOENT || code == ECONNREFUSED {
                throw LocalRustTerminalError.missingServer
            }
            do {
                let daemonPID = try SessionHostSocket.peerProcessID(descriptor)
                return LocalRustTerminalConnection(descriptor: descriptor, peerPID: UInt32(daemonPID))
            } catch {
                close(descriptor)
                throw error
            }
        }
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
        let browser = resources.appendingPathComponent("myterm-browser")
        let model = try AppModel(applicationSupportDirectory: directory, terminalEngine: engine,
                                 browserLauncherURL: browser, confirmClosingActiveProcesses: { _ in true })
        model.updateGlobalSettings {
            $0.newSessionWorkingDirectory = .custom(directory)
            $0.shell = .custom(path: "/bin/bash")
        }
        model.createTerminalTab()
        let tabID = try XCTUnwrap(model.selectedWorkspace.selectedTab?.terminalSession?.id)
        let tab = try session(in: model, id: tabID)
        model.splitFocusedTerminal(orientation: .horizontal)
        let splitID = try XCTUnwrap(model.selectedWorkspace.selectedTab?.terminalSession?.id)
        let split = try session(in: model, id: splitID)
        XCTAssertNotEqual(tabID, splitID)
        try await until("both workspace connections settle") { !tab.isStarting && !split.isStarting }
        guard tab.isRunning, split.isRunning else {
            return XCTFail("Workspace terminal startup failed: \(String(describing: model.terminalNotices))")
        }

        let originalPID = try await shellIdentity(tab, parent: daemon.processIdentifier)
        let splitPID = try await shellIdentity(split, parent: daemon.processIdentifier)
        XCTAssertNotEqual(originalPID, splitPID)
        try tab.sendRemoteInput(Data((#"printf '\115\124\055\103\117\116\106\111\107=%s/%s/%s\n' "$BASH_VERSION" "$PWD" "$MYTERM_WORKSPACE_ID""# + "\r").utf8),
                                generation: tab.remoteGeneration)
        try await until("configured shell, directory and browser routing variables reach the PTY") {
            let snapshot = tab.contentSnapshot(maximumCharacters: 5_000)
            return snapshot.contains("MT-CONFIG=3.2.") && snapshot.contains(directory.lastPathComponent)
                && snapshot.lowercased().contains(model.selectedWorkspace.id.description.lowercased())
        }

        try split.sendRemoteInput(Data("/bin/sleep 30\r".utf8), generation: split.remoteGeneration)
        try await until("the split has a foreground job") { split.activeForegroundProcessName == "sleep" }

        let workspaceID = model.selectedWorkspace.id
        let splitTab = try XCTUnwrap(model.selectedWorkspace.selectedTab)
        let splitGroupID = try XCTUnwrap(model.selectedWorkspace.groupID(containing: splitTab.id))
        model.createTerminalTab(in: splitGroupID)
        let companionTab = try XCTUnwrap(model.selectedWorkspace.selectedTab)
        let companionID = try XCTUnwrap(companionTab.terminalSession?.id)
        let companion = try session(in: model, id: companionID)
        try await until("the companion close fixture attaches") { companion.isRunning }
        let companionPID = try await shellIdentity(companion, parent: daemon.processIdentifier)
        try companion.sendRemoteInput(Data("/bin/sleep 30\r".utf8), generation: companion.remoteGeneration)
        try await until("the companion close fixture has a foreground job") {
            companion.activeForegroundProcessName == "sleep"
        }
        try split.sendRemoteInput(Data("/bin/sleep 30\r".utf8), generation: split.remoteGeneration)
        try await until("the split has a foreground job") { split.activeForegroundProcessName == "sleep" }
        model.selectTab(splitTab.id, in: splitGroupID, focusContent: false)

        model.persistWorkspaceStore()
        model.detachTerminalSessions()
        let confirmation = CloseConfirmation()
        let reopened = try AppModel(applicationSupportDirectory: directory, terminalEngine: engine,
                                    browserLauncherURL: browser, confirmClosingActiveProcesses: confirmation.confirm)
        let reopenedTab = try session(in: reopened, id: tabID)
        let savedSplit = try session(in: reopened, id: splitID)
        let reopenedCompanion = try session(in: reopened, id: companionID)
        try await until("all saved terminals attempt reattachment automatically") {
            !reopenedTab.isStarting && !savedSplit.isStarting && !reopenedCompanion.isStarting
        }
        let restoresCheckpoints = ProcessInfo.processInfo.environment["MYTERM_TEST_RUST_WORKSPACE_CHECKPOINT"] == "1"
        if restoresCheckpoints {
            XCTAssertTrue(reopenedTab.isRunning, String(describing: reopened.terminalNotices[tabID]))
            XCTAssertNil(reopenedTab.rustRecovery?.action)
            XCTAssertTrue(reopenedTab.contentSnapshot(maximumCharacters: 5_000).contains("MT-CONFIG=3.2."))
            let reattachedPID = try await shellIdentity(reopenedTab, parent: daemon.processIdentifier)
            XCTAssertEqual(reattachedPID, originalPID)
            XCTAssertTrue(savedSplit.isRunning)
            XCTAssertNil(savedSplit.rustRecovery?.action)
            XCTAssertEqual(savedSplit.activeForegroundProcessName, "sleep")
            XCTAssertTrue(reopenedCompanion.isRunning)
            XCTAssertNil(reopenedCompanion.rustRecovery?.action)
        } else {
            XCTAssertFalse(reopenedTab.isRunning)
            XCTAssertEqual(reopenedTab.rustRecovery?.action, .reattach)
            XCTAssertFalse(savedSplit.isRunning)
            XCTAssertEqual(savedSplit.rustRecovery?.action, .reattach)
            XCTAssertEqual(kill(originalPID, 0), 0, "An unavailable checkpoint must preserve the original shell")
        }
        XCTAssertEqual(reopened.selectedWorkspace.selectedTab?.terminalSession?.id, splitID)
        XCTAssertTrue(reopened.shouldTerminateApplication())
        XCTAssertTrue(confirmation.prompts.isEmpty, "Quitting detaches the pane and keeps its shell")
        let unknownForeground = "Saved terminal shell (foreground activity unknown)"
        let companionInfo = try reopened.companionTabProcessInfo(
            workspaceID: workspaceID, groupID: splitGroupID, tabID: companionTab.id
        )
        XCTAssertEqual(companionInfo.sessionID, companionID)
        let foreground = restoresCheckpoints ? "sleep" : unknownForeground
        XCTAssertEqual(companionInfo.processNames, [foreground])
        XCTAssertTrue(try reopened.companionWorkspaceProcessNames(workspaceID).contains(foreground))
        XCTAssertThrowsError(try reopened.closeCompanionTab(
            workspaceID: workspaceID, groupID: splitGroupID, tabID: companionTab.id
        )) { error in
            XCTAssertEqual(error as? CompanionCommandError, .activeProcessRequiresDesktopConfirmation)
        }
        XCTAssertThrowsError(try reopened.closeCompanionWorkspace(workspaceID)) { error in
            XCTAssertEqual(error as? CompanionCommandError, .activeProcessRequiresDesktopConfirmation)
        }
        XCTAssertEqual(kill(companionPID, 0), 0, "An unconfirmed Companion close must preserve the shell")
        guard reopened.selectedWorkspace.tab(id: companionTab.id) != nil else {
            return XCTFail("The saved tab was closed without confirmation")
        }
        try await reopened.closeCompanionTabAwaitingTerminalStop(
            workspaceID: workspaceID, groupID: splitGroupID, tabID: companionTab.id,
            confirmedActiveProcesses: true
        )
        try await until("the explicitly confirmed Companion close stops its saved shell") {
            kill(companionPID, 0) != 0
        }

        let closedSelection = directory.appendingPathComponent("selection")
            .appendingPathComponent(splitID.rawValue.uuidString + ".json")

        reopened.closeFocusedPaneOrTab()
        XCTAssertEqual(confirmation.prompts.last?.confirmButtonTitle, "Close Pane")
        XCTAssertEqual(confirmation.prompts.last?.hasUnverifiedTerminals, !restoresCheckpoints)
        XCTAssertEqual(reopened.selectedWorkspace.selectedTab?.terminalSession?.id, splitID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: closedSelection.path))
        XCTAssertEqual(kill(splitPID, 0), 0, "Cancelling must preserve the saved shell")
        guard confirmation.prompts.count == 1 else { return XCTFail("Expected one close confirmation") }

        confirmation.allowsClose = true
        reopened.closeFocusedPaneOrTab()
        XCTAssertEqual(confirmation.prompts.count, 2)
        try await until("closing the saved pane stops its shell and prunes its ownership record") {
            kill(splitPID, 0) != 0 && !FileManager.default.fileExists(atPath: closedSelection.path)
        }
        XCTAssertEqual(kill(originalPID, 0), 0)

        daemon.terminate()
        try await until("the owner and original shell exit") { !daemon.isRunning && kill(originalPID, 0) != 0 }
        try await until("the lost terminal offers explicit reattachment") {
            !reopenedTab.isRunning && reopenedTab.rustRecovery?.action == .reattach
        }
        reopenedTab.performRustRecoveryAction()
        try await until("the unavailable shell offers a deliberate replacement") {
            reopenedTab.rustRecovery?.action == .startNewShell
        }

        let replacement = Process()
        replacement.executableURL = daemon.executableURL
        replacement.arguments = daemon.arguments
        try replacement.run()
        defer {
            if replacement.isRunning { replacement.terminate() }
            replacement.waitUntilExit()
        }
        try await until("the replacement daemon is listening") {
            FileManager.default.fileExists(atPath: socket.path)
        }
        XCTAssertFalse(reopenedTab.isRunning)
        reopenedTab.performRustRecoveryAction()
        try await until("the explicit new shell is running") { reopenedTab.isRunning }
        let replacementPID = try await shellIdentity(reopenedTab, parent: replacement.processIdentifier)
        XCTAssertNotEqual(replacementPID, originalPID)

        replacement.terminate()
        try await until("the replacement daemon and shell exit") {
            !replacement.isRunning && kill(replacementPID, 0) != 0
                && reopenedTab.rustRecovery?.action == .reattach
        }
        reopenedTab.performRustRecoveryAction()
        try await until("the replacement shell is confirmed absent") {
            reopenedTab.rustRecovery?.action == .startNewShell
        }
        let missingTab = try XCTUnwrap(reopened.selectedWorkspace.allTabs.first {
            $0.terminalSession?.id == tabID
        })
        let missingGroupID = try XCTUnwrap(reopened.selectedWorkspace.groupID(containing: missingTab.id))
        let missingInfo = try reopened.companionTabProcessInfo(
            workspaceID: workspaceID, groupID: missingGroupID, tabID: missingTab.id
        )
        XCTAssertTrue(missingInfo.processNames.isEmpty, "A shell known to be absent needs no Companion token")
        confirmation.allowsClose = false
        reopened.closeTab(missingTab.id)
        XCTAssertEqual(confirmation.prompts.count, 2, "A shell known to be absent needs no warning")
        XCTAssertFalse(reopened.workspaces.flatMap(\.allTabs).contains { $0.id == missingTab.id })
        reopened.detachTerminalSessions()
    }

    @MainActor
    private final class CloseConfirmation {
        var allowsClose = false
        private(set) var prompts = [ActiveProcessClosePrompt]()

        func confirm(_ prompt: ActiveProcessClosePrompt) -> Bool {
            prompts.append(prompt)
            return allowsClose
        }
    }

    private func session(in model: AppModel, id: TerminalSessionID) throws -> SwiftTermTerminalSession {
        try XCTUnwrap(model.terminalSession(for: id) as? SwiftTermTerminalSession)
    }

    private func shellIdentity(_ session: SwiftTermTerminalSession, parent: pid_t) async throws -> pid_t {
        // A unique marker distinguishes this command from output restored by the checkpoint.
        let marker = "MT-PID-" + UUID().uuidString.prefix(8) + "="
        let encoded = marker.utf8.map { String(format: "\\%03o", $0) }.joined()
        let command = "printf '\(encoded)%s/%s\\n' \"$$\" \"$PPID\"\r"
        try session.sendRemoteInput(Data(command.utf8), generation: session.remoteGeneration)
        let suffix = "/\(parent)"
        try await until("the shell reports its Rust parent") {
            let text = session.contentSnapshot(maximumCharacters: 5_000)
            return text.range(of: "\(marker)[0-9]+\(suffix)", options: .regularExpression) != nil
        }
        let text = session.contentSnapshot(maximumCharacters: 5_000)
        let result = try XCTUnwrap(text.components(separatedBy: marker).last?.components(separatedBy: suffix).first)
        return try XCTUnwrap(pid_t(result.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    private func until(_ description: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            if ContinuousClock.now >= deadline {
                throw TerminalSessionFailure(message: "Timed out waiting for \(description).")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }


}
#endif
