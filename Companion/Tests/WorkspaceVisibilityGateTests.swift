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
        // Polled rather than awaited: if the gate strands its permit this has to fail, and
        // awaiting a task that never returns would hang the suite instead.
        let reacquiredFlag = AcquisitionFlag()
        let after = Task {
            if await gate.acquire() { await reacquiredFlag.record() }
        }
        defer { after.cancel() }
        var reacquired = false
        for _ in 0..<40 where !reacquired {
            try await Task.sleep(for: .milliseconds(50))
            reacquired = await reacquiredFlag.value
        }
        XCTAssertTrue(reacquired, "The gate is still usable after a waiter is cancelled")
        if reacquired { await gate.release() }
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

private actor AcquisitionFlag {
    private(set) var value = false
    func record() { value = true }
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
