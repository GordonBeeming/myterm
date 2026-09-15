import Foundation
import MyTermRemote
import XCTest
@testable import MyTerm

@MainActor
final class CompanionPairingRotationTests: XCTestCase {
    private final class MemorySecrets: SecretStore, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Data] = [:]

        func read(account: String) throws -> Data? { lock.withLock { values[account] } }
        func write(_ data: Data, account: String) throws {
            lock.withLock { values[account] = data }
        }
        func delete(account: String) throws {
            _ = lock.withLock { values.removeValue(forKey: account) }
        }
    }

    private actor SleepProbe {
        private(set) var delays: [TimeInterval] = []

        func sleep(_ delay: TimeInterval) {
            delays.append(delay)
        }
    }

    private actor SleepGate {
        private struct Waiter {
            let delay: TimeInterval
            let continuation: CheckedContinuation<Void, Error>
        }

        private var waiters: [UUID: Waiter] = [:]

        func sleep(_ delay: TimeInterval) async throws {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    waiters[id] = Waiter(delay: delay, continuation: continuation)
                }
            } onCancel: {
                Task { await self.cancel(id) }
            }
        }

        var pendingCount: Int { waiters.count }

        func fireNext() -> TimeInterval? {
            guard let id = waiters.keys.first,
                  let waiter = waiters.removeValue(forKey: id) else { return nil }
            waiter.continuation.resume()
            return waiter.delay
        }

        private func cancel(_ id: UUID) {
            waiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
        }
    }

    func testOnlyLatestScheduledTicketRotatesAndCancellationStopsPairMode() async throws {
        let probe = SleepProbe()
        let rotation = CompanionPairingRotation { delay in
            await probe.sleep(delay)
        }
        let replacedTicketID = UUID()
        let currentTicketID = UUID()
        var rotatedTicketIDs: [UUID] = []

        rotation.schedule(ticketID: replacedTicketID, delay: 30) {
            rotatedTicketIDs.append($0)
        }
        rotation.schedule(ticketID: currentTicketID, delay: 30) {
            rotatedTicketIDs.append($0)
        }

        try await waitUntil { rotatedTicketIDs == [currentTicketID] }
        XCTAssertFalse(rotation.isScheduled)
        let delays = await probe.delays
        XCTAssertTrue(delays.allSatisfy { $0 == 30 })

        rotation.schedule(ticketID: UUID(), delay: 30) {
            rotatedTicketIDs.append($0)
        }
        rotation.cancel()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(rotatedTicketIDs, [currentTicketID])
        XCTAssertFalse(rotation.isScheduled)
    }

    func testHostRotatesEveryThirtySecondsSuspendsForApprovalAndCancelStopsTheCycle() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("myterm-pairing-rotation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaultsSuite = "myterm-pairing-rotation-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let model = try AppModel(
            applicationSupportDirectory: directory,
            terminalEngine: nil,
            startsTerminalProcesses: false,
            browserLauncherURL: nil
        )
        let gate = SleepGate()
        let now = Date(timeIntervalSince1970: 1_000)
        let host = CompanionHostModel(
            appModel: model,
            channel: .development,
            storageNamespace: "pairing-rotation-test",
            now: { now },
            pairingSleep: { delay in try await gate.sleep(delay) },
            secrets: MemorySecrets(),
            defaults: defaults
        )
        try await host.configurePairingForTesting(
            endpoint: RelayEndpoint(try XCTUnwrap(URL(string: "https://relay.example.test")))
        )

        host.beginPairing()
        try await waitUntil { host.activePairingTicketForTesting != nil }
        try await waitUntilAsync { await gate.pendingCount == 1 }
        let first = try XCTUnwrap(host.activePairingTicketForTesting)
        XCTAssertEqual(host.pairingRefreshesAt, now.addingTimeInterval(30))
        XCTAssertEqual(first.expiresAt, now.addingTimeInterval(60))
        let firstDelay = await gate.fireNext()
        XCTAssertEqual(firstDelay, 30)

        try await waitUntil {
            host.activePairingTicketForTesting?.ticketID != first.ticketID
        }
        try await waitUntilAsync { await gate.pendingCount == 1 }
        let replacement = try XCTUnwrap(host.activePairingTicketForTesting)
        XCTAssertNotEqual(replacement.ticketID, first.ticketID)
        XCTAssertEqual(host.pairingRefreshesAt, now.addingTimeInterval(30))
        XCTAssertEqual(replacement.expiresAt, now.addingTimeInterval(60))

        host.suspendPairingForApprovalTesting()
        try await waitUntilAsync { await gate.pendingCount == 0 }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(host.activePairingTicketForTesting)
        XCTAssertNil(host.pairingQRCode)
        XCTAssertNil(host.pairingRefreshesAt)
        XCTAssertFalse(host.isPairingRotationScheduledForTesting)

        await host.resumePairingAfterAttemptForTesting()
        try await waitUntil { host.activePairingTicketForTesting != nil }
        try await waitUntilAsync { await gate.pendingCount == 1 }
        let afterApprovalAttempt = try XCTUnwrap(host.activePairingTicketForTesting)
        XCTAssertNotEqual(afterApprovalAttempt.ticketID, replacement.ticketID)

        host.cancelPairing()
        try await waitUntilAsync { await gate.pendingCount == 0 }
        XCTAssertNil(host.activePairingTicketForTesting)
        XCTAssertNil(host.pairingQRCode)
        XCTAssertNil(host.pairingRefreshesAt)
        XCTAssertNil(host.pairingExpiresAt)
        XCTAssertFalse(host.isPairingRotationScheduledForTesting)
    }

    private func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for pairing rotation")
    }

    private func waitUntilAsync(
        _ predicate: @escaping @MainActor () async -> Bool
    ) async throws {
        for _ in 0..<100 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for asynchronous pairing state")
    }
}
