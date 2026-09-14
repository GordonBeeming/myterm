import Foundation
import MyTermCore
import MyTermRemote
import XCTest
@testable import MyTermCompanion

private final class TestSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(account: String) throws -> Data? { lock.withLock { values[account] } }
    func write(_ data: Data, account: String) throws { lock.withLock { values[account] = data } }
    func delete(account: String) throws { _ = lock.withLock { values.removeValue(forKey: account) } }
}

@MainActor
final class SceneStateTests: XCTestCase {
    func testTerminalOutputRequiresCheckpointGenerationAndSequence() async throws {
        let route = TerminalRoute(connectionID: testConnection(), workspaceID: UUID(), groupID: UUID(),
                                  tabID: UUID(), sessionID: UUID(), title: "Shell")
        let state = TerminalSurfaceState(route: route)
        let generation = UUID()
        let transferID = UUID()
        let checkpointBytes = Data("checkpoint".utf8)
        let assembler = CheckpointAssembler()
        let metadata = MessageMetadata(hostID: route.hostID, runtimeID: UUID(),
                                       sessionID: route.sessionID)
        let checkpoint = try await assembler.ingest(
            metadata: metadata,
            chunk: CheckpointChunkParameters(
                transferID: transferID, generation: generation, sequence: 10,
                chunkIndex: 0, chunkCount: 1, totalBytes: checkpointBytes.count,
                bytes: checkpointBytes
            )
        )
        state.apply(checkpoint: try XCTUnwrap(checkpoint))
        state.append(output: OutputParameters(generation: UUID(), sequence: 11,
                                              bytes: Data("wrong".utf8)))
        state.append(output: OutputParameters(generation: generation, sequence: 12,
                                              bytes: Data("gap".utf8)))
        XCTAssertTrue(state.outputChunks.isEmpty)
        state.append(output: OutputParameters(generation: generation, sequence: 11,
                                              bytes: Data("accepted".utf8)))
        XCTAssertEqual(state.outputChunks, [Data("accepted".utf8)])
    }

    func testControllerOwnershipUsesConnectionID() {
        let route = TerminalRoute(connectionID: testConnection(), workspaceID: UUID(), groupID: UUID(),
                                  tabID: UUID(), sessionID: UUID(), title: "Shell")
        let state = TerminalSurfaceState(route: route)
        let ownConnection = UUID()
        state.apply(control: ControlStateParameters(controllerConnectionID: ownConnection,
                                                    leaseID: UUID(), expiresAt: .now,
                                                    generation: UUID(), columns: 80, rows: 24),
                    ownConnectionID: ownConnection)
        XCTAssertTrue(state.ownsControl)
        state.apply(control: ControlStateParameters(controllerConnectionID: UUID(),
                                                    leaseID: UUID(), expiresAt: .now,
                                                    generation: UUID(), columns: 80, rows: 24),
                    ownConnectionID: ownConnection)
        XCTAssertFalse(state.ownsControl)
    }

    func testGapInvalidatesSurfaceAndDisablesControlUntilFreshCheckpoint() async throws {
        let route = TerminalRoute(connectionID: testConnection(), workspaceID: UUID(), groupID: UUID(),
                                  tabID: UUID(), sessionID: UUID(), title: "Shell")
        let state = TerminalSurfaceState(route: route)
        let generation = UUID()
        let bytes = Data([1])
        let checkpoint = try await CheckpointAssembler().ingest(
            metadata: MessageMetadata(hostID: route.hostID, runtimeID: UUID(),
                                      sessionID: route.sessionID),
            chunk: CheckpointChunkParameters(transferID: UUID(), generation: generation,
                                             sequence: 3, chunkIndex: 0, chunkCount: 1,
                                             totalBytes: 1, bytes: bytes)
        )
        state.apply(checkpoint: try XCTUnwrap(checkpoint))
        let ownConnection = UUID()
        state.apply(control: ControlStateParameters(controllerConnectionID: ownConnection,
                                                    leaseID: UUID(), expiresAt: .now,
                                                    generation: generation, columns: 80, rows: 24),
                    ownConnectionID: ownConnection)
        XCTAssertFalse(state.append(output: OutputParameters(generation: generation,
                                                             sequence: 5, bytes: bytes)))
        XCTAssertTrue(state.invalidateForCheckpoint())
        XCTAssertFalse(state.ownsControl)
        XCTAssertNil(state.leaseID)
        XCTAssertFalse(state.invalidateForCheckpoint())
    }

    func testBufferedOutputHasHardMemoryBound() async throws {
        let route = TerminalRoute(connectionID: testConnection(), workspaceID: UUID(), groupID: UUID(),
                                  tabID: UUID(), sessionID: UUID(), title: "Shell")
        let state = TerminalSurfaceState(route: route)
        let generation = UUID()
        let checkpoint = try await CheckpointAssembler().ingest(
            metadata: MessageMetadata(hostID: route.hostID, runtimeID: UUID(),
                                      sessionID: route.sessionID),
            chunk: CheckpointChunkParameters(transferID: UUID(), generation: generation,
                                             sequence: 0, chunkIndex: 0, chunkCount: 1,
                                             totalBytes: 1, bytes: Data([0]))
        )
        state.apply(checkpoint: try XCTUnwrap(checkpoint))
        let full = Data(repeating: 1, count: TerminalSurfaceState.maximumBufferedOutputBytes)
        XCTAssertTrue(state.append(output: OutputParameters(generation: generation,
                                                            sequence: 1, bytes: full)))
        XCTAssertFalse(state.append(output: OutputParameters(generation: generation,
                                                             sequence: 2, bytes: Data([2]))))
    }

    func testMaximumCheckpointSequenceRequestsResyncWithoutOverflow() async throws {
        let route = TerminalRoute(connectionID: testConnection(), workspaceID: UUID(),
                                  groupID: UUID(), tabID: UUID(), sessionID: UUID(),
                                  title: "Shell")
        let state = TerminalSurfaceState(route: route)
        let generation = UUID()
        let checkpoint = try await CheckpointAssembler().ingest(
            metadata: MessageMetadata(hostID: route.hostID, runtimeID: UUID(),
                                      sessionID: route.sessionID),
            chunk: CheckpointChunkParameters(transferID: UUID(), generation: generation,
                                             sequence: UInt64.max, chunkIndex: 0,
                                             chunkCount: 1, totalBytes: 1, bytes: Data([0]))
        )
        state.apply(checkpoint: try XCTUnwrap(checkpoint))
        XCTAssertFalse(state.append(output: OutputParameters(generation: generation,
                                                             sequence: 0, bytes: Data([1]))))
        XCTAssertTrue(state.invalidateForCheckpoint())
    }

    func testAuthoritativeGridChangesAreGenerationBound() async throws {
        let route = TerminalRoute(connectionID: testConnection(), workspaceID: UUID(), groupID: UUID(),
                                  tabID: UUID(), sessionID: UUID(), title: "Shell")
        let state = TerminalSurfaceState(route: route)
        let generation = UUID()
        let checkpoint = try await CheckpointAssembler().ingest(
            metadata: MessageMetadata(hostID: route.hostID, runtimeID: UUID(),
                                      sessionID: route.sessionID),
            chunk: CheckpointChunkParameters(transferID: UUID(), generation: generation,
                                             sequence: 0, chunkIndex: 0, chunkCount: 1,
                                             totalBytes: 1, bytes: Data([0]))
        )
        state.apply(checkpoint: try XCTUnwrap(checkpoint))
        let originalRevision = state.gridRevision
        XCTAssertTrue(state.apply(control: ControlStateParameters(
            controllerConnectionID: nil, leaseID: nil, expiresAt: nil,
            generation: generation, columns: 132, rows: 44
        ), ownConnectionID: UUID()))
        XCTAssertEqual(state.authoritativeColumns, 132)
        XCTAssertEqual(state.authoritativeRows, 44)
        XCTAssertGreaterThan(state.gridRevision, originalRevision)
        XCTAssertFalse(state.apply(control: ControlStateParameters(
            controllerConnectionID: nil, leaseID: nil, expiresAt: nil,
            generation: UUID(), columns: 80, rows: 24
        ), ownConnectionID: UUID()))
        XCTAssertEqual(state.authoritativeColumns, 132)
    }

    func testSavedConnectionsWithSameHostIDRemainDistinct() {
        let hostID = UUID()
        let first = SavedConnectionID(relayOrigin: "https://one.example.test",
                                      accountID: UUID(), hostID: hostID)
        let second = SavedConnectionID(relayOrigin: "https://two.example.test",
                                       accountID: UUID(), hostID: hostID)
        XCTAssertNotEqual(first, second)
        let states = [first: ConnectionPhase.online, second: ConnectionPhase.disconnected]
        XCTAssertEqual(states.count, 2)
    }

    func testScenesShareOneTokenManagerForPartition() throws {
        let services = CompanionServices(secrets: TestSecretStore())
        let relay = try RelayEndpoint(XCTUnwrap(URL(string: "https://relay.example.test")))
        let record = TokenRecord(relay: relay, accountID: UUID(), deviceID: UUID(),
                                 accessToken: "access", refreshToken: "refresh",
                                 expiresAt: .distantFuture)
        let first = try services.tokenManager(for: record)
        let second = try services.tokenManager(for: record)
        XCTAssertTrue(first === second)
    }

    func testNotificationDestinationIsClaimedByOnlyOneScene() {
        let destination = NotificationDestination(connectionID: testConnection(),
                                                  workspaceID: UUID(), tabID: UUID(),
                                                  sessionID: UUID())
        NotificationRouteBroker.shared.publish(destination)
        XCTAssertNotNil(NotificationRouteBroker.shared.claim())
        XCTAssertNil(NotificationRouteBroker.shared.claim())
    }

    func testHostSwitchClearsNavigationWhileSameHostReconnectPreservesIt() {
        let scene = SceneModel()
        let first = testConnection()
        let route = testTerminalRoute(connectionID: first)
        scene.selectedWorkspaceID = route.workspaceID
        scene.path = [.terminal(route)]
        scene.secondaryTerminal = route

        scene.prepareNavigation(replacing: first, with: first)
        XCTAssertEqual(scene.path, [.terminal(route)])
        XCTAssertEqual(scene.selectedWorkspaceID, route.workspaceID)
        XCTAssertEqual(scene.secondaryTerminal, route)

        scene.prepareNavigation(replacing: first, with: testConnection())
        XCTAssertTrue(scene.path.isEmpty)
        XCTAssertNil(scene.selectedWorkspaceID)
        XCTAssertNil(scene.secondaryTerminal)
    }

    func testExplicitDisconnectClearsSelectionNavigationAndSurfaces() async {
        let scene = SceneModel()
        let connectionID = testConnection()
        let route = testTerminalRoute(connectionID: connectionID)
        scene.selectedConnectionID = connectionID
        scene.selectedWorkspaceID = route.workspaceID
        scene.path = [.terminal(route)]
        scene.secondaryTerminal = route
        scene.terminalStates[route.id] = TerminalSurfaceState(route: route)

        await scene.disconnect()

        XCTAssertNil(scene.selectedConnectionID)
        XCTAssertNil(scene.selectedWorkspaceID)
        XCTAssertTrue(scene.path.isEmpty)
        XCTAssertNil(scene.secondaryTerminal)
        XCTAssertTrue(scene.terminalStates.isEmpty)
    }

    func testWorkspaceSelectionPreservesNotificationTerminalAndBrowserRoutes() {
        let scene = SceneModel()
        let connectionID = testConnection()
        let terminal = testTerminalRoute(connectionID: connectionID)
        scene.path = [.terminal(terminal)]
        scene.navigateToWorkspace(terminal.workspaceID)
        XCTAssertEqual(scene.path, [.terminal(terminal)])

        let browser = BrowserRoute(connectionID: connectionID,
                                   workspaceID: terminal.workspaceID,
                                   groupID: UUID(), tabID: UUID(),
                                   title: "Docs", url: nil)
        scene.path = [.browser(browser)]
        scene.navigateToWorkspace(browser.workspaceID)
        XCTAssertEqual(scene.path, [.browser(browser)])

        let otherWorkspace = UUID()
        scene.navigateToWorkspace(otherWorkspace)
        XCTAssertEqual(scene.path, [.workspace(otherWorkspace)])
    }

    func testAttachmentRegistryDeduplicatesImplicitAttachAndAllowsExplicitRefresh() {
        var registry = AttachedRouteRegistry()
        let route = testTerminalRoute(connectionID: testConnection())
        XCTAssertTrue(registry.register(route))
        XCTAssertFalse(registry.register(route))
        XCTAssertTrue(registry.register(route, requestingFreshCheckpoint: true))

        let moved = TerminalRoute(connectionID: route.connectionID,
                                  workspaceID: UUID(), groupID: UUID(), tabID: UUID(),
                                  sessionID: route.sessionID, title: "Moved")
        XCTAssertFalse(registry.register(moved))
        XCTAssertEqual(registry.route(sessionID: route.sessionID), moved)

        registry.remove(sessionID: route.sessionID)
        XCTAssertTrue(registry.register(moved),
                      "A failed refresh must make the next normal attach send again")
    }

    func testMovedTerminalRecreationDoesNotDetachStableSession() async {
        let scene = SceneModel()
        let original = testTerminalRoute(connectionID: testConnection())
        let moved = TerminalRoute(connectionID: original.connectionID,
                                  workspaceID: UUID(), groupID: UUID(), tabID: UUID(),
                                  sessionID: original.sessionID, title: "Moved")
        let state = TerminalSurfaceState(route: original)
        state.route = moved
        scene.terminalStates[original.id] = state
        scene.path = [.terminal(moved)]

        await scene.terminalScreenDidDisappear(original, secondary: nil)
        XCTAssertTrue(scene.terminalStates[original.id] === state)

        scene.path.removeAll()
        await scene.terminalScreenDidDisappear(moved, secondary: nil)
        XCTAssertNil(scene.terminalStates[original.id])
    }

    func testBrowserRouteReconcilesAfterMovingGroups() throws {
        let scene = SceneModel()
        let connectionID = testConnection()
        let tabID = UUID()
        let old = BrowserRoute(connectionID: connectionID, workspaceID: UUID(),
                               groupID: UUID(), tabID: tabID, title: "Old", url: nil)
        scene.selectedConnectionID = connectionID
        scene.path = [.browser(old)]
        let workspaceID = UUID()
        let groupID = UUID()
        let url = try XCTUnwrap(URL(string: "https://example.test/new"))
        let projection = RemoteWorkspaceProjection(folders: [], workspaces: [
            RemoteWorkspaceItem(
                id: WorkspaceID(rawValue: workspaceID), title: "Web", folderID: nil,
                isPinned: false, color: nil, emoji: nil,
                groups: [RemoteTabGroupProjection(
                    id: TabGroupID(rawValue: groupID),
                    tabs: [RemoteTabProjection(
                        id: TabID(rawValue: tabID), title: "New", kind: .browser,
                        terminalSessionID: nil, browserURL: url
                    )]
                )]
            )
        ])

        scene.reconcileRoutes(in: projection)

        guard case .browser(let updated) = try XCTUnwrap(scene.path.last) else {
            return XCTFail("Expected the browser route to remain selected")
        }
        XCTAssertEqual(updated.workspaceID, workspaceID)
        XCTAssertEqual(updated.groupID, groupID)
        XCTAssertEqual(updated.title, "New")
        XCTAssertEqual(updated.url, url)
    }

    func testClearingSecondaryDetachesItsSurfaceBeforeDroppingSelection() async {
        let scene = SceneModel()
        let route = testTerminalRoute(connectionID: testConnection())
        scene.secondaryTerminal = route
        scene.terminalStates[route.id] = TerminalSurfaceState(route: route)

        await scene.setSecondaryTerminal(nil)

        XCTAssertNil(scene.secondaryTerminal)
        XCTAssertNil(scene.terminalStates[route.id])
    }

    func testSelectingPrimaryDetachesSecondaryBeforeReplacingNavigation() async {
        let scene = SceneModel()
        let connectionID = testConnection()
        let current = testTerminalRoute(connectionID: connectionID)
        let secondary = testTerminalRoute(connectionID: connectionID)
        let replacement = testTerminalRoute(connectionID: connectionID)
        scene.selectedConnectionID = connectionID
        scene.path = [.terminal(current)]
        scene.secondaryTerminal = secondary
        scene.terminalStates[secondary.id] = TerminalSurfaceState(route: secondary)

        await scene.selectPrimaryTerminal(replacement, replacing: current)

        XCTAssertNil(scene.secondaryTerminal)
        XCTAssertNil(scene.terminalStates[secondary.id])
        XCTAssertEqual(scene.path, [.terminal(replacement)])
    }

    func testPrimarySelectionDoesNotAppendAfterNavigationChanges() async {
        let scene = SceneModel()
        let connectionID = testConnection()
        let current = testTerminalRoute(connectionID: connectionID)
        let replacement = testTerminalRoute(connectionID: connectionID)
        scene.selectedConnectionID = connectionID
        scene.path = [.settings]

        await scene.selectPrimaryTerminal(replacement, replacing: current)

        XCTAssertEqual(scene.path, [.settings])
    }
}

private func testConnection(hostID: UUID = UUID()) -> SavedConnectionID {
    SavedConnectionID(relayOrigin: "https://relay.example.test", accountID: UUID(), hostID: hostID)
}

private func testTerminalRoute(connectionID: SavedConnectionID) -> TerminalRoute {
    TerminalRoute(connectionID: connectionID, workspaceID: UUID(), groupID: UUID(),
                  tabID: UUID(), sessionID: UUID(), title: "Shell")
}
