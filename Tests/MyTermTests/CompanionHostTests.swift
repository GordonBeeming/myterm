import CryptoKit
import Foundation
import MyTermCore
import MyTermRemote
import XCTest
@testable import MyTerm

@MainActor
final class CompanionHostTests: XCTestCase {
    private final class MemorySecrets: SecretStore, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Data] = [:]
        func read(account: String) throws -> Data? {
            lock.withLock { values[account] }
        }
        func write(_ data: Data, account: String) throws {
            lock.withLock { values[account] = data }
        }
        func delete(account: String) throws {
            _ = lock.withLock { values.removeValue(forKey: account) }
        }
    }
    private func model() throws -> AppModel {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "myterm-companion-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try AppModel(
            applicationSupportDirectory: directory,
            terminalEngine: nil,
            startsTerminalProcesses: false,
            browserLauncherURL: nil
        )
    }

    private func data<Value: Encodable>(_ value: Value) throws -> Data {
        try JSONEncoder().encode(value)
    }

    private func metadata(
        workspaceID: WorkspaceID? = nil,
        folderID: WorkspaceFolderID? = nil,
        groupID: TabGroupID? = nil,
        tabID: TabID? = nil
    ) -> MessageMetadata {
        MessageMetadata(
            requestID: UUID(),
            hostID: UUID(),
            runtimeID: UUID(),
            workspaceID: workspaceID?.rawValue,
            folderID: folderID?.rawValue,
            groupID: groupID?.rawValue,
            tabID: tabID?.rawValue
        )
    }

    func testRemoteWorkspaceAndTabCreationPreserveDesktopSelection() throws {
        let model = try model()
        let desktopWorkspaceID = model.store.selectedWorkspaceID
        let workspaceResult = try XCTUnwrap(model.performCompanionCommand(
            metadata: metadata(),
            command: CommandParameters(
                operation: .workspaceCreate,
                payload: try data(RemoteWorkspaceCreatePayload(title: "Phone workspace"))
            )
        ))
        let remoteID = WorkspaceID(
            rawValue: try JSONDecoder().decode(RemoteIdentifierResult.self, from: workspaceResult).id
        )
        let remoteWorkspace = try XCTUnwrap(model.store.workspaces.first { $0.id == remoteID })
        let group = try XCTUnwrap(remoteWorkspace.focusedTabGroup)
        let selectedTabID = group.selectedTabID

        _ = try model.performCompanionCommand(
            metadata: metadata(workspaceID: remoteID, groupID: group.id),
            command: CommandParameters(
                operation: .tabCreate,
                payload: try data(RemoteTabCreatePayload(kind: .terminal))
            )
        )

        let updated = try XCTUnwrap(model.store.workspaces.first { $0.id == remoteID })
        XCTAssertEqual(model.store.selectedWorkspaceID, desktopWorkspaceID)
        XCTAssertEqual(updated.focusedTabGroupID, group.id)
        XCTAssertEqual(updated.group(id: group.id)?.selectedTabID, selectedTabID)
        XCTAssertEqual(updated.group(id: group.id)?.tabs.count, 2)
    }

    func testWrongWorkspaceGroupAssociationIsRejected() throws {
        let model = try model()
        let first = model.store.selectedWorkspace
        let secondID = try model.store.createWorkspace(
            title: "Second",
            selectsCreatedWorkspace: false
        )
        let second = try XCTUnwrap(model.store.workspaces.first { $0.id == secondID })
        let secondGroup = try XCTUnwrap(second.focusedTabGroup)
        let secondTab = secondGroup.selectedTab

        XCTAssertThrowsError(try model.performCompanionCommand(
            metadata: metadata(
                workspaceID: first.id,
                groupID: secondGroup.id,
                tabID: secondTab.id
            ),
            command: CommandParameters(
                operation: .tabRename,
                payload: try data(RemoteRenamePayload(title: "Wrong target"))
            )
        )) { error in
            XCTAssertEqual(error as? CompanionCommandError, .wrongTarget)
        }
    }

    func testPhoneMarkReadClearsFinishedAttentionWithoutChangingDesktopFocus() throws {
        let model = try model()
        let workspace = model.store.selectedWorkspace
        let group = try XCTUnwrap(workspace.focusedTabGroup)
        let tab = group.selectedTab
        model.agentAttention[tab.id] = .finished

        _ = try model.performCompanionCommand(
            metadata: metadata(workspaceID: workspace.id, groupID: group.id, tabID: tab.id),
            command: CommandParameters(
                operation: .markRead,
                payload: try data(RemoteEmptyPayload())
            )
        )

        XCTAssertNil(model.agentAttention[tab.id])
        XCTAssertEqual(model.store.selectedWorkspaceID, workspace.id)
        XCTAssertEqual(model.store.selectedWorkspace.focusedTabGroupID, group.id)
    }

    func testRemoteSplitPreservesDesktopAndRemoteWorkspaceFocus() throws {
        let model = try model()
        let desktopID = model.store.selectedWorkspaceID
        let remoteID = try model.store.createWorkspace(
            title: "Remote",
            selectsCreatedWorkspace: false
        )
        let remote = try XCTUnwrap(model.store.workspaces.first { $0.id == remoteID })
        let group = try XCTUnwrap(remote.focusedTabGroup)
        let movedTabID = try model.store.addTerminalTab(
            to: remoteID,
            tabGroupID: group.id,
            selectsCreatedTab: false
        )

        _ = try model.performCompanionCommand(
            metadata: metadata(workspaceID: remoteID, groupID: group.id, tabID: movedTabID),
            command: CommandParameters(
                operation: .tabSplit,
                payload: try data(RemoteTabSplitPayload(targetGroupID: group.id, edge: .right))
            )
        )

        let updated = try XCTUnwrap(model.store.workspaces.first { $0.id == remoteID })
        XCTAssertEqual(model.store.selectedWorkspaceID, desktopID)
        XCTAssertEqual(updated.focusedTabGroupID, group.id)
        XCTAssertEqual(updated.orderedGroups.count, 2)
    }

    func testProjectionCarriesRuntimeMetadataWithoutRecentTerminalText() throws {
        let model = try model()
        let workspace = model.store.selectedWorkspace
        let group = try XCTUnwrap(workspace.focusedTabGroup)
        let tab = group.selectedTab
        let secretText = "projection-must-not-contain-this-output"
        try model.store.updateTerminalRecentText(
            workspaceID: workspace.id,
            tabGroupID: group.id,
            tabID: tab.id,
            recentText: secretText
        )
        try model.store.updateTerminalWorkingDirectory(
            workspaceID: workspace.id,
            tabGroupID: group.id,
            tabID: tab.id,
            workingDirectory: FileManager.default.temporaryDirectory
        )
        model.agentAttention[tab.id] = .awaitingInput
        try model.store.updateWorkspaceSettings(workspace.id) { overrides in
            overrides.fontSize = 17
            overrides.terminalTheme = .solarizedDark
        }

        let projection = model.companionWorkspaceProjection()
        XCTAssertEqual(projection.workspaces.first?.preferences?.fontSize, 17)
        XCTAssertEqual(projection.workspaces.first?.preferences?.terminalTheme, .solarizedDark)
        let projectedTab = try XCTUnwrap(projection.workspaces.first?.groups.first?.tabs.first)
        XCTAssertEqual(projectedTab.agentActivity, .awaitingInput)
        XCTAssertEqual(projectedTab.kind, .terminal)
        XCTAssertNotNil(projectedTab.workingDirectory)
        XCTAssertNil(projectedTab.isRunning)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(projection), as: UTF8.self).contains(secretText))
    }

    func testCompanionDefaultsArePartitionedBySupportDirectoryNamespace() {
        let suite = "myterm-companion-defaults-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = CompanionConfigurationStore(
            channel: .development,
            namespace: "test-one",
            defaults: defaults
        )
        let second = CompanionConfigurationStore(
            channel: .development,
            namespace: "test-two",
            defaults: defaults
        )

        first.relayText = "https://one.example"
        first.connectionEnabled = true

        XCTAssertEqual(first.relayText, "https://one.example")
        XCTAssertTrue(first.connectionEnabled)
        XCTAssertEqual(second.relayText, "")
        XCTAssertFalse(second.connectionEnabled)
    }

    func testNotificationGrantPersistenceIsScopedToThePairedDevice() async throws {
        let store = CompanionNotificationGrantStore(secrets: MemorySecrets())
        let firstDevice = UUID()
        let secondDevice = UUID()
        let grant = try NotificationGrantRegistration(
            gatewayOrigin: RelayEndpoint(URL(string: "https://push.example")!),
            recipientID: UUID(),
            grantID: UUID(),
            grantToken: "grant-token",
            recipientEncryptionPublicKey: P256.KeyAgreement.PrivateKey().publicKey.x963Representation
        )

        try await store.save(grant, deviceID: firstDevice)

        let loaded = try await store.load()
        XCTAssertEqual(loaded[firstDevice], grant)
        XCTAssertNil(loaded[secondDevice])
        try await store.remove(deviceID: firstDevice)
        let afterRemoval = try await store.load()
        XCTAssertTrue(afterRemoval.isEmpty)
    }

    func testOldRuntimeAndWrongHelloTargetAreRejected() throws {
        let hostID = UUID()
        let runtimeID = UUID()
        XCTAssertThrowsError(try CompanionHostSecurity.validateApplicationMetadata(
            MessageMetadata(hostID: hostID, runtimeID: UUID()),
            hostID: hostID,
            runtimeID: runtimeID
        )) { error in
            XCTAssertEqual(error as? RemoteError, .wrongPeer)
        }

        let endpoint = try RelayEndpoint(URL(string: "https://relay.example")!)
        XCTAssertThrowsError(try CompanionHostSecurity.validateInitialHelloBinding(
            ChannelBinding(
                relay: endpoint,
                accountID: UUID(),
                hostID: hostID,
                runtimeID: nil,
                epoch: UUID(),
                senderID: UUID(),
                recipientID: UUID(),
                purpose: .hello,
                direction: .clientToHost
            ),
            endpoint: endpoint,
            accountID: UUID(),
            hostID: hostID
        )) { error in
            XCTAssertEqual(error as? RemoteError, .wrongPeer)
        }
    }

    func testPushJournalIsBoundedAndDeduplicatesEventIDs() async throws {
        let store = CompanionPushJournalStore(secrets: MemorySecrets())
        let deviceID = UUID()
        let eventID = UUID()
        let json = """
        {"event_id":"\(eventID.uuidString)","timestamp":1,"ciphertext":"YQ","host_signature":"Yg"}
        """
        let request = try JSONDecoder().decode(
            PushNotificationRequest.self,
            from: Data(json.utf8)
        )
        let entry = CompanionPushJournalEntry(deviceID: deviceID, request: request)

        try await store.append(entry)
        try await store.append(entry)

        let entries = try await store.entries()
        XCTAssertEqual(entries, [entry])

        for index in 0..<65 {
            try await store.append(
                CompanionPushJournalEntry(
                    deviceID: deviceID,
                    request: PushNotificationRequest(
                        eventID: UUID(),
                        timestamp: Int64(index + 2),
                        ciphertext: Data([UInt8(index)]),
                        hostSignature: Data([1])
                    )
                )
            )
        }
        let boundedEntries = try await store.entries()
        XCTAssertEqual(boundedEntries.count, 64)
    }

    func testImageAssemblerRejectsDuplicateMismatchedOversizedAndExpiredTransfers() throws {
        let assembler = CompanionImageAssembler()
        let connectionID = UUID()
        let sessionID = TerminalSessionID()
        let transferID = UUID()
        let leaseID = UUID()
        let generation = UUID()
        let start = Date(timeIntervalSince1970: 1_000)
        let first = try RemoteImageChunkPayload(
            transferID: transferID,
            leaseID: leaseID,
            generation: generation,
            contentType: .png,
            chunkIndex: 0,
            chunkCount: 2,
            totalBytes: 4,
            bytes: Data([1, 2])
        )
        XCTAssertNil(try assembler.ingest(
            first,
            connectionID: connectionID,
            sessionID: sessionID,
            now: start
        ))
        XCTAssertThrowsError(try assembler.ingest(
            first,
            connectionID: connectionID,
            sessionID: sessionID,
            now: start
        )) { error in
            XCTAssertEqual(error as? RemoteError, .replayedMessage)
        }

        let mismatched = try RemoteImageChunkPayload(
            transferID: transferID,
            leaseID: leaseID,
            generation: generation,
            contentType: .jpeg,
            chunkIndex: 1,
            chunkCount: 2,
            totalBytes: 4,
            bytes: Data([3, 4])
        )
        XCTAssertThrowsError(try assembler.ingest(
            mismatched,
            connectionID: connectionID,
            sessionID: sessionID,
            now: start
        )) { error in
            XCTAssertEqual(error as? RemoteError, .invalidMessage)
        }

        let expiringTransfer = UUID()
        let expiring = try RemoteImageChunkPayload(
            transferID: expiringTransfer,
            leaseID: leaseID,
            generation: generation,
            contentType: .png,
            chunkIndex: 0,
            chunkCount: 2,
            totalBytes: 4,
            bytes: Data([1, 2])
        )
        XCTAssertNil(try assembler.ingest(
            expiring,
            connectionID: connectionID,
            sessionID: sessionID,
            now: start
        ))
        XCTAssertEqual(assembler.expire(now: start.addingTimeInterval(31)).count, 1)
        XCTAssertThrowsError(try assembler.ingest(
            expiring,
            connectionID: connectionID,
            sessionID: sessionID,
            now: start.addingTimeInterval(31)
        )) { error in
            XCTAssertEqual(error as? RemoteError, .checkpointExpired)
        }

        XCTAssertThrowsError(try RemoteImageChunkPayload(
            transferID: UUID(),
            leaseID: leaseID,
            generation: generation,
            contentType: .png,
            chunkIndex: 0,
            chunkCount: 1,
            totalBytes: RemoteImageChunkPayload.maximumTotalBytes + 1,
            bytes: Data([1])
        ))
    }

    func testImageAssemblerRestoresOriginalChunkOrder() throws {
        let assembler = CompanionImageAssembler()
        let connectionID = UUID()
        let sessionID = TerminalSessionID()
        let transferID = UUID()
        let leaseID = UUID()
        let generation = UUID()
        let second = try RemoteImageChunkPayload(
            transferID: transferID, leaseID: leaseID, generation: generation,
            contentType: .jpeg, chunkIndex: 1, chunkCount: 2, totalBytes: 5,
            bytes: Data([4, 5])
        )
        let first = try RemoteImageChunkPayload(
            transferID: transferID, leaseID: leaseID, generation: generation,
            contentType: .jpeg, chunkIndex: 0, chunkCount: 2, totalBytes: 5,
            bytes: Data([1, 2, 3])
        )

        XCTAssertNil(try assembler.ingest(
            second,
            connectionID: connectionID,
            sessionID: sessionID
        ))
        let assembled = try XCTUnwrap(assembler.ingest(
            first,
            connectionID: connectionID,
            sessionID: sessionID
        ))

        XCTAssertEqual(assembled.bytes, Data([1, 2, 3, 4, 5]))
        XCTAssertEqual(assembled.leaseID, leaseID)
        XCTAssertEqual(assembled.generation, generation)
    }

    func testReconnectPolicyIsJitteredAndBoundedWithoutGivingUp() {
        let policy = CompanionReconnectPolicy(maximumExponent: 3, maximumDelay: 6)

        XCTAssertEqual(policy.delay(attempt: 0, jitter: 0), 0.8, accuracy: 0.001)
        XCTAssertEqual(policy.delay(attempt: 0, jitter: 1), 1.2, accuracy: 0.001)
        XCTAssertEqual(policy.delay(attempt: 99, jitter: 1), 6, accuracy: 0.001)
        XCTAssertEqual(policy.delay(attempt: 99, jitter: -10), 4.8, accuracy: 0.001)
    }

    func testConnectionFenceRejectsCallbacksFromAnOlderReader() {
        var fence = CompanionConnectionFence()
        let first = fence.begin()
        let second = fence.begin()

        XCTAssertFalse(fence.accepts(first))
        XCTAssertTrue(fence.accepts(second))
        fence.invalidate()
        XCTAssertFalse(fence.accepts(second))
    }

    func testLatePreviousControllerPacketDoesNotRevokeTakeoverLease() throws {
        let firstConnection = UUID()
        let currentConnection = UUID()
        let now = Date(timeIntervalSince1970: 100)
        var state = ControllerLeaseState(duration: 30)
        let old = try state.acquire(connectionID: firstConnection, now: now)
        let current = state.takeover(connectionID: currentConnection, now: now)

        XCTAssertFalse(state.authorizes(
            leaseID: old.leaseID,
            connectionID: firstConnection,
            now: now
        ))
        XCTAssertEqual(state.lease, current)
        XCTAssertTrue(state.authorizes(
            leaseID: current.leaseID,
            connectionID: currentConnection,
            now: now
        ))
    }

    func testSlowPeerQueueDoesNotBlockAnotherPeerAndKeepsItsOwnOrder() async throws {
        let slow = CompanionConnectionWorkQueue()
        let fast = CompanionConnectionWorkQueue()
        let fastRan = expectation(description: "unrelated peer progressed")
        let slowFinished = expectation(description: "slow peer preserved order")
        var releaseSlow: CheckedContinuation<Void, Never>?
        var order: [Int] = []

        try slow.enqueue(cost: 1) {
            order.append(1)
            await withCheckedContinuation { releaseSlow = $0 }
        }
        try slow.enqueue(cost: 1) {
            order.append(2)
            slowFinished.fulfill()
        }
        try fast.enqueue(cost: 1) {
            fastRan.fulfill()
        }

        await fulfillment(of: [fastRan], timeout: 1)
        XCTAssertEqual(order, [1])
        releaseSlow?.resume()
        await fulfillment(of: [slowFinished], timeout: 1)
        XCTAssertEqual(order, [1, 2])
    }

    func testCloseConfirmationIsBoundToConnectionRuntimeTargetProcessesAndExpiry() throws {
        let registry = CompanionCloseConfirmationRegistry(lifetime: 10)
        let start = Date(timeIntervalSince1970: 100)
        let binding = CompanionCloseBinding(
            connectionID: UUID(), runtimeID: UUID(), operation: .tabClose,
            workspaceID: UUID(), groupID: UUID(), tabID: UUID(), sessionID: UUID()
        )
        let issued = registry.issue(
            binding: binding,
            processNames: ["vim", "make"],
            now: start
        )
        XCTAssertEqual(issued.processNames, ["make", "vim"])

        var wrongBinding = binding
        wrongBinding = CompanionCloseBinding(
            connectionID: UUID(), runtimeID: binding.runtimeID, operation: binding.operation,
            workspaceID: binding.workspaceID, groupID: binding.groupID,
            tabID: binding.tabID, sessionID: binding.sessionID
        )
        XCTAssertFalse(registry.consume(
            token: issued.confirmationToken,
            binding: wrongBinding,
            currentProcessNames: ["vim", "make"],
            now: start
        ))

        let changed = registry.issue(binding: binding, processNames: ["vim"], now: start)
        XCTAssertFalse(registry.consume(
            token: changed.confirmationToken,
            binding: binding,
            currentProcessNames: ["vim", "ssh"],
            now: start
        ))

        let expired = registry.issue(binding: binding, processNames: ["vim"], now: start)
        XCTAssertFalse(registry.consume(
            token: expired.confirmationToken,
            binding: binding,
            currentProcessNames: ["vim"],
            now: start.addingTimeInterval(11)
        ))

        let valid = registry.issue(binding: binding, processNames: ["vim"], now: start)
        XCTAssertTrue(registry.consume(
            token: valid.confirmationToken,
            binding: binding,
            currentProcessNames: ["vim"],
            now: start
        ))
    }

    func testRemoteClosePayloadDefaultsToUnconfirmed() throws {
        let payload = try JSONDecoder().decode(RemoteClosePayload.self, from: Data("{}".utf8))
        XCTAssertFalse(payload.confirmedActiveProcesses)
        XCTAssertNil(payload.confirmationToken)
    }

    func testFontSizePatchPreservesOtherWorkspaceOverridesAndResetIsExplicit() throws {
        let model = try model()
        let workspaceID = model.store.selectedWorkspaceID
        try model.store.updateWorkspaceSettings(workspaceID) { overrides in
            overrides.fontSize = 14
            overrides.terminalTheme = .solarizedDark
            overrides.shell = .custom(path: "/bin/bash")
            overrides.scrollbackLines = 4_321
        }
        var fontPatch = TerminalPreferencesOverrides()
        fontPatch.fontSize = 18

        _ = try model.performCompanionCommand(
            metadata: metadata(),
            command: CommandParameters(
                operation: .settingsUpdate,
                payload: try data(RemoteSettingsUpdatePayload(
                    scope: .workspace(workspaceID),
                    patch: fontPatch
                ))
            )
        )

        var updated = try XCTUnwrap(
            model.store.workspaces.first(where: { $0.id == workspaceID })?.settingsOverrides
        )
        XCTAssertEqual(updated.fontSize, 18)
        XCTAssertEqual(updated.terminalTheme, .solarizedDark)
        XCTAssertEqual(updated.shell, .custom(path: "/bin/bash"))
        XCTAssertEqual(updated.scrollbackLines, 4_321)

        var secondPatch = TerminalPreferencesOverrides()
        secondPatch.fontSize = 20
        _ = try model.performCompanionCommand(
            metadata: metadata(),
            command: CommandParameters(
                operation: .settingsUpdate,
                payload: try data(RemoteSettingsUpdatePayload(
                    scope: .workspace(workspaceID),
                    patch: secondPatch,
                    reset: [.shell]
                ))
            )
        )

        updated = try XCTUnwrap(
            model.store.workspaces.first(where: { $0.id == workspaceID })?.settingsOverrides
        )
        XCTAssertEqual(updated.fontSize, 20)
        XCTAssertNil(updated.shell)
        XCTAssertEqual(updated.terminalTheme, .solarizedDark)
        XCTAssertEqual(updated.scrollbackLines, 4_321)
    }

    func testRemoteWorkspaceMoveChangesFolderAndOrderWithoutChangingDesktopSelection() throws {
        let model = try model()
        let selectedID = model.store.selectedWorkspaceID
        let sourceFolderID = try model.store.createFolder(title: "Source")
        let destinationFolderID = try model.store.createFolder(title: "Destination")
        let movedID = try model.store.createWorkspace(
            title: "Moved",
            folderID: sourceFolderID,
            selectsCreatedWorkspace: false
        )
        let beforeID = try model.store.createWorkspace(
            title: "Before",
            folderID: destinationFolderID,
            selectsCreatedWorkspace: false
        )

        _ = try model.performCompanionCommand(
            metadata: metadata(workspaceID: movedID),
            command: CommandParameters(
                operation: .workspaceMove,
                payload: try data(RemoteWorkspaceMovePayload(
                    destinationFolderID: destinationFolderID,
                    beforeWorkspaceID: beforeID
                ))
            )
        )

        XCTAssertEqual(model.store.selectedWorkspaceID, selectedID)
        XCTAssertEqual(
            model.store.workspaces.first(where: { $0.id == movedID })?.folderID,
            destinationFolderID
        )
        let destinationIDs = model.store.workspaces
            .filter { $0.folderID == destinationFolderID }
            .map(\.id)
        XCTAssertEqual(destinationIDs, [movedID, beforeID])

        XCTAssertThrowsError(try model.performCompanionCommand(
            metadata: metadata(workspaceID: movedID),
            command: CommandParameters(
                operation: .workspaceMove,
                payload: try data(RemoteWorkspaceMovePayload(
                    destinationFolderID: nil,
                    beforeWorkspaceID: beforeID
                ))
            )
        )) { error in
            XCTAssertEqual(error as? CompanionCommandError, .wrongTarget)
        }
        XCTAssertEqual(
            model.store.workspaces.first(where: { $0.id == movedID })?.folderID,
            destinationFolderID
        )
    }
}
