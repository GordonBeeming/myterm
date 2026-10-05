import Foundation

/// How a renderer answers a snapshot that did not arrive in time.
///
/// Closing on the first one is what made a slow page look permanently broken. The host drops a
/// session whose renderer has closed, so the next request built a new renderer and loaded the page
/// again from nothing. On a page slow enough to miss a snapshot, that reload is slower still and
/// misses in the same way, so every frame timed out and the view never recovered on its own.
///
/// A page that is still laying out can miss one window and have the next in hand, so one miss
/// fails that frame and costs nothing else. A view that keeps missing is not slow, it is wedged,
/// and only then is it worth throwing away for a fresh one.
struct RemoteBrowserSnapshotTimeoutPolicy: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        /// Fail this frame and keep the renderer; the page is still coming.
        case failFrame
        /// Nothing is arriving from this view. Close it so the next request starts a working one.
        case giveUp
    }

    /// Enough to outlast a reload of a heavy page rather than a single slow frame.
    static let timeoutsBeforeGivingUp = 3

    private var consecutiveTimeouts = 0

    init() {}

    /// A frame arrived, so whatever the view was busy with has cleared.
    mutating func recordFrame() {
        consecutiveTimeouts = 0
    }

    mutating func recordTimeout() -> Outcome {
        consecutiveTimeouts += 1
        return consecutiveTimeouts >= Self.timeoutsBeforeGivingUp ? .giveUp : .failFrame
    }
}
