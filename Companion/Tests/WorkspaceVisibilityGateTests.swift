import Foundation
import XCTest
@testable import MyTermCompanion

final class WorkspaceVisibilityGateTests: XCTestCase {
    func testTheSecondCallerWaitsUntilTheFirstReleases() async throws {
        let gate = WorkspaceVisibilityGate()
        let first = await gate.acquire()
        XCTAssertTrue(first, "An unheld gate is taken straight away")


        let second = Task { await gate.acquire() }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(second.isCancelled)

        await gate.release()
        let acquired = await second.value
        XCTAssertTrue(acquired, "Releasing hands the permit to the waiter")
        await gate.release()
    }

    func testACancelledWaiterNeitherHoldsThePermitNorBlocksTheNextCaller() async throws {
        let gate = WorkspaceVisibilityGate()
        let held = await gate.acquire()
        XCTAssertTrue(held)

        // SwiftUI cancels the visibility task whenever the view's request changes, so a waiter
        // being cancelled mid-queue is routine rather than exceptional.
        let cancelled = Task { await gate.acquire() }
        try await Task.sleep(for: .milliseconds(50))
        cancelled.cancel()
        let acquiredWhileCancelled = await cancelled.value
        XCTAssertFalse(acquiredWhileCancelled,
                       "A cancelled waiter must not believe it holds the permit, or it releases one it never took")

        await gate.release()

        // The gate has to be usable afterwards. It used to strand the permit on the cancelled
        // waiter, which left every later attach waiting forever on a terminal that never appeared.
        let after = Task { await gate.acquire() }
        let reacquired = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { await after.value }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                return false
            }
            let result = try await group.next() ?? false
            group.cancelAll()
            return result
        }
        XCTAssertTrue(reacquired, "The gate is still usable after a waiter is cancelled")
        await gate.release()
    }

    func testTheGateSerialisesConcurrentCallers() async throws {
        let gate = WorkspaceVisibilityGate()
        let counter = ConcurrencyCounter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    guard await gate.acquire() else { return }
                    await counter.enter()
                    try? await Task.sleep(for: .milliseconds(5))
                    await counter.leave()
                    await gate.release()
                }
            }
        }

        let peak = await counter.peak
        XCTAssertEqual(peak, 1, "Only one caller may be inside the gate at a time, saw \(peak)")
    }
}

private actor ConcurrencyCounter {
    private var current = 0
    private(set) var peak = 0

    func enter() {
        current += 1
        peak = max(peak, current)
    }

    func leave() {
        current -= 1
    }
}
