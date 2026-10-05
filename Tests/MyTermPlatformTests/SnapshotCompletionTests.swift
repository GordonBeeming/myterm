import AppKit
import XCTest
@testable import MyTermPlatform

final class SnapshotCompletionTests: XCTestCase {
    /// The P1 this guards. When every snapshot runs over its deadline, each one still arrives
    /// eventually, after its frame has already been failed. Counting those as the view working
    /// reset the timeout run on every miss, so a view that never answered in time was never given
    /// up on either: every frame failed and nothing ever rebuilt the renderer.
    @MainActor
    func testASnapshotArrivingAfterItsDeadlineIsToldItLost() async {
        let completion = SnapshotCompletion()
        var lateSnapshotWon: Bool?

        do {
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NSImage, Error>) in
                completion.continuation = continuation
                XCTAssertTrue(completion.finish(.failure(URLError(.timedOut))),
                              "The deadline is the one that answered this request")
                lateSnapshotWon = completion.finish(.success(NSImage()))
            }
            XCTFail("The frame was failed by its deadline")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }

        XCTAssertEqual(lateSnapshotWon, false,
                       "A discarded snapshot must not read as the view producing frames")
    }

    @MainActor
    func testASnapshotThatBeatsItsDeadlineAnswersAndCancelsIt() async throws {
        let completion = SnapshotCompletion()
        var deadlineRan = false
        var snapshotWon: Bool?

        let image = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NSImage, Error>) in
            completion.continuation = continuation
            completion.deadline = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                deadlineRan = true
            }
            snapshotWon = completion.finish(.success(NSImage()))
        }

        XCTAssertEqual(snapshotWon, true)
        XCTAssertNotNil(image)
        XCTAssertNil(completion.deadline, "Answering the request drops its deadline")
        XCTAssertFalse(deadlineRan)
    }

    /// The other direction. A deadline that expires too late to be cancelled must not record a
    /// miss for a frame that did arrive, or near-deadline successes pile up phantom misses and
    /// close a view that was working.
    @MainActor
    func testADeadlineExpiringAfterTheFrameArrivedIsToldItLost() async throws {
        let completion = SnapshotCompletion()
        var lateDeadlineWon: Bool?

        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NSImage, Error>) in
            completion.continuation = continuation
            XCTAssertTrue(completion.finish(.success(NSImage())),
                          "The snapshot is the one that answered this request")
            lateDeadlineWon = completion.finish(.failure(URLError(.timedOut)))
        }

        XCTAssertEqual(lateDeadlineWon, false,
                       "A deadline that lost its race must not count the frame as missed")
    }

    @MainActor
    func testTheRequestIsOnlyEverAnsweredOnce() async throws {
        let completion = SnapshotCompletion()
        var extraFinishes: [Bool] = []

        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NSImage, Error>) in
            completion.continuation = continuation
            _ = completion.finish(.success(NSImage()))
            extraFinishes = [
                completion.finish(.success(NSImage())),
                completion.finish(.failure(URLError(.timedOut))),
            ]
        }

        XCTAssertEqual(extraFinishes, [false, false],
                       "A checked continuation resumed twice traps, so this is load-bearing")
    }
}
