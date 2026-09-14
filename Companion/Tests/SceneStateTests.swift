import Foundation
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
}

private func testConnection(hostID: UUID = UUID()) -> SavedConnectionID {
    SavedConnectionID(relayOrigin: "https://relay.example.test", accountID: UUID(), hostID: hostID)
}
