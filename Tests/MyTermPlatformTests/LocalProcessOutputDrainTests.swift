import Darwin
import Foundation
import XCTest
@preconcurrency @testable import SwiftTerm

@MainActor
final class LocalProcessOutputDrainTests: XCTestCase {
    func testExitNotificationFollowsAlreadyBufferedPTYOutput() async throws {
        let exited = expectation(description: "child exit after output")
        let delegate = OutputDrainDelegate(exited: exited)
        let process = LocalProcess(delegate: delegate, deliversTerminationAfterOutput: true)
        process.startProcess(executable: "/bin/sh", args: ["-c", "dd if=/dev/zero bs=65536 count=16 2>/dev/null"])
        defer { if process.running { process.terminate() } }
        // Hold only the consumer queue: DispatchIO can collect the child's output
        // and the OS can report its exit before queued delivery is allowed to run.
        usleep(300_000)
        await fulfillment(of: [exited], timeout: 8)
        XCTAssertEqual(delegate.bytesAtExit, 1_048_576,
                       "the process exit callback must follow all buffered PTY bytes")
    }

    func testEOFBeforeProcessExitRetainsOutputAndExitStatus() async {
        let exited = expectation(description: "EOF then shell exit")
        let delegate = OutputDrainDelegate(exited: exited)
        let process = LocalProcess(delegate: delegate, deliversTerminationAfterOutput: true)
        process.startProcess(executable: "/bin/sh", args: ["-c",
            "printf eof-first; exec 0<&- 1>&- 2>&-; sleep 0.2; exit 7"])
        defer { if process.running { process.terminate() } }
        await fulfillment(of: [exited], timeout: 8)
        XCTAssertEqual(delegate.bytesAtExit, 9)
        XCTAssertEqual(delegate.exitStatus, 7 << 8)
    }

    func testBackpressuredReadResumesAndDeliversEveryByteBeforeExit() async {
        let exited = expectation(description: "output beyond the PTY delivery high water mark")
        let delegate = OutputDrainDelegate(exited: exited)
        let process = LocalProcess(delegate: delegate, deliversTerminationAfterOutput: true)
        process.startProcess(executable: "/bin/sh", args: ["-c", "dd if=/dev/zero bs=1048576 count=6 2>/dev/null"])
        defer { if process.running { process.terminate() } }
        holdConsumerUntilPTYReadPauses(process)
        await fulfillment(of: [exited], timeout: 12)
        XCTAssertEqual(delegate.bytesAtExit, 6 * 1_024 * 1_024, delegate.progressDescription(process: process))
    }

    func testObservedExitWithOpenPTYUsesActualByteProgressThenInactivityDeadline() async {
        let exited = expectation(description: "descendant PTY activity then idle deadline")
        let delegate = OutputDrainDelegate(exited: exited)
        let process = LocalProcess(delegate: delegate, deliversTerminationAfterOutput: true)
        process.startProcess(executable: "/bin/sh", args: ["-c", "printf a; sleep 2; printf b; sleep 2; printf c; sleep 20"])
        defer {
            if process.shellPid > 1 {
                _ = kill(-process.shellPid, SIGKILL)
                var status: Int32 = 0
                _ = waitpid(process.shellPid, &status, 0)
            }
        }
        // Darwin revokes the controlling PTY when its session leader exits. Inject
        // only the monitor observation so a real owned PTY stays open and emits
        // actual bytes at two-second intervals, then stalls. This isolates the
        // drain deadline from platform-specific terminal hangup behavior.
        process.observedProcessExit(status: 0)
        await fulfillment(of: [exited], timeout: 12)
        XCTAssertEqual(delegate.bytesAtExit, 3, "each real PTY byte must extend the inactivity deadline")
        XCTAssertEqual(delegate.exitStatus, 0)
    }

    func testObservedExitDoesNotExpireWhileConsumerBackpressurePausesPTYRead() async {
        let exited = expectation(description: "slow consumer retains paused PTY output")
        let delegate = OutputDrainDelegate(exited: exited)
        let process = LocalProcess(delegate: delegate, deliversTerminationAfterOutput: true)
        process.startProcess(executable: "/bin/sh", args: ["-c", "dd if=/dev/zero bs=1048576 count=6 2>/dev/null"])
        defer {
            if process.shellPid > 1 {
                _ = kill(-process.shellPid, SIGKILL)
                var status: Int32 = 0
                _ = waitpid(process.shellPid, &status, 0)
            }
        }
        // Fill the four-MiB delivery backlog while the consumer cannot run, then
        // inject the exit observation and stall beyond the inactivity interval.
        // The timer must distinguish its own read pause from a quiet open PTY.
        holdConsumerUntilPTYReadPauses(process)
        process.observedProcessExit(status: 0)
        usleep(3_200_000)
        await fulfillment(of: [exited], timeout: 15)
        XCTAssertEqual(delegate.bytesAtExit, 6 * 1_024 * 1_024, delegate.progressDescription(process: process))
    }

    private func holdConsumerUntilPTYReadPauses(_ process: LocalProcess) {
        let deadline = Date().addingTimeInterval(5)
        var status = process.outputDeliveryStatus()
        while !status.isBackpressured, Date() < deadline {
            usleep(1_000)
            status = process.outputDeliveryStatus()
        }
        XCTAssertTrue(status.isBackpressured, "the real producer must pause its PTY read before the consumer is released; pending=\(status.pendingByteCount)")
    }
}

@MainActor
private final class OutputDrainDelegate: @preconcurrency LocalProcessDelegate {
    private let exited: XCTestExpectation
    private var bytes = 0
    private var callbackCount = 0
    private var lastReceivedAt = DispatchTime.now().uptimeNanoseconds
    var bytesAtExit: Int?
    var exitStatus: Int32?

    init(exited: XCTestExpectation) { self.exited = exited }
    func getWindowSize() -> winsize { winsize(ws_row: 25, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0) }
    func dataReceived(slice: ArraySlice<UInt8>) {
        callbackCount += 1
        lastReceivedAt = DispatchTime.now().uptimeNanoseconds
        bytes += slice.count
        // One callback must cross the delivery time slice, allowing an already
        // queued exit observation to overtake the remaining buffered chunks.
        if bytes == slice.count { usleep(5_000) }
    }
    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        bytesAtExit = bytes
        exitStatus = exitCode
        exited.fulfill()
    }
    func progressDescription(process: LocalProcess) -> String {
        "bytes=\(bytes), callbacks=\(callbackCount), bytesAtExit=\(String(describing: bytesAtExit)), gapSinceData=\(Double(DispatchTime.now().uptimeNanoseconds - lastReceivedAt) / 1_000_000_000)s, running=\(process.running), childfd=\(process.childfd)"
    }
}
