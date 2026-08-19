@testable import MyTerm
import Foundation
import MyTermCore
import XCTest

@MainActor
final class UpdateControllerTests: XCTestCase {
    private func defaults() throws -> UserDefaults {
        let suite = "UpdateControllerTests.\(UUID().uuidString)"
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    private func releaseJSON(tag: String) -> Data {
        Data(
            """
            { "tag_name": "\(tag)", "name": "MyTerm",
              "html_url": "https://github.com/GordonBeeming/myterm/releases/tag/\(tag)" }
            """.utf8
        )
    }

    private func controller(
        currentVersion: String = "0.23",
        latestTag: String = "v0.24",
        route: UpdateController.UpgradeRoute = .homebrew(command: "brew upgrade --cask x"),
        defaults: UserDefaults,
        now: @escaping () -> Date = Date.init,
        fetch: (@Sendable (URL) async throws -> Data)? = nil
    ) -> UpdateController {
        UpdateController(
            channel: .development,
            currentVersion: currentVersion,
            upgradeRoute: route,
            defaults: defaults,
            environment: [:],
            now: now,
            fetch: fetch ?? { [json = releaseJSON(tag: latestTag)] _ in json }
        )
    }

    func testNewerReleaseBecomesAnAvailableStatus() async throws {
        let controller = controller(defaults: try defaults())
        let status = await controller.check()

        XCTAssertEqual(status.release?.version.description, "0.24")
        XCTAssertEqual(controller.status.release?.version.description, "0.24")
    }

    func testMatchingReleaseReportsUpToDate() async throws {
        let controller = controller(latestTag: "v0.23", defaults: try defaults())
        _ = await controller.check()

        XCTAssertEqual(controller.status, .upToDate(AppVersion("0.23")!))
        XCTAssertNil(controller.status.release)
    }

    func testNetworkFailureIsReportedWithoutLosingTheApp() async throws {
        struct Offline: Error, LocalizedError { var errorDescription: String? { "offline" } }
        let controller = controller(defaults: try defaults(), fetch: { _ in throw Offline() })
        _ = await controller.check()

        XCTAssertEqual(controller.status, .failed("offline"))
    }

    func testCheckRecordsTheAttemptEvenWhenItFails() async throws {
        struct Offline: Error {}
        let store = try defaults()
        let stamp = Date(timeIntervalSince1970: 1_000_000)
        let controller = controller(defaults: store, now: { stamp }, fetch: { _ in throw Offline() })
        _ = await controller.check()

        // Without this, an offline app would retry on every single poll.
        XCTAssertEqual(controller.lastCheckedAt, stamp)
        XCTAssertEqual(store.object(forKey: "updates.lastCheckedAt") as? Date, stamp)
    }

    func testAFreshInstallIsDueImmediately() throws {
        XCTAssertTrue(controller(defaults: try defaults()).isDueForCheck)
    }

    func testACheckWithinTheIntervalIsNotDue() async throws {
        let store = try defaults()
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let controller = controller(defaults: store, now: { clock })
        _ = await controller.check()

        clock += UpdateController.checkInterval - 60
        XCTAssertFalse(controller.isDueForCheck)

        clock += 120
        XCTAssertTrue(controller.isDueForCheck)
    }

    func testCheckIfDueDoesNothingWhenAutomaticChecksAreOff() async throws {
        let store = try defaults()
        let calls = Counter()
        let controller = controller(defaults: store, fetch: { [json = releaseJSON(tag: "v0.24")] _ in
            await calls.increment()
            return json
        })
        controller.automaticallyChecks = false
        await controller.checkIfDue()

        let callCount = await calls.value
        XCTAssertEqual(callCount, 0)
        XCTAssertEqual(controller.status, .idle)
    }

    func testAutomaticChecksPreferenceSurvivesARestart() throws {
        let store = try defaults()
        controller(defaults: store).automaticallyChecks = false

        XCTAssertFalse(controller(defaults: store).automaticallyChecks)
        XCTAssertTrue(controller(defaults: try defaults()).automaticallyChecks, "defaults to on")
    }

    func testAKnownUpdateStillShowsAfterARelaunch() async throws {
        let store = try defaults()
        _ = await controller(defaults: store).check()

        // A fresh controller over the same defaults stands in for the next launch.
        let relaunched = controller(defaults: store)
        XCTAssertEqual(relaunched.status.release?.version.description, "0.24")
        XCTAssertFalse(relaunched.isDueForCheck, "the badge must not depend on an immediate re-check")
    }

    func testCatchingUpClearsTheRememberedUpdate() async throws {
        let store = try defaults()
        _ = await controller(defaults: store).check()
        // The upgrade happens, so the next check runs from the new version.
        _ = await controller(currentVersion: "0.24", defaults: store).check()

        XCTAssertNil(controller(currentVersion: "0.24", defaults: store).status.release)
    }

    func testARememberedReleaseOlderThanThisBuildIsIgnored() async throws {
        let store = try defaults()
        _ = await controller(defaults: store).check()

        // Installing 0.25 by hand must not leave a stale 0.24 badge behind.
        XCTAssertNil(controller(currentVersion: "0.25", defaults: store).status.release)
    }

    func testOverlappingChecksRunOnceAndAgreeOnTheResult() async throws {
        let calls = Counter()
        let gate = Gate()
        let controller = controller(defaults: try defaults(), fetch: { [json = releaseJSON(tag: "v0.24")] _ in
            await calls.increment()
            await gate.wait()
            return json
        })

        async let first = controller.check()
        async let second = controller.check()
        await gate.open()
        let results = await [first, second]

        let callCount = await calls.value
        XCTAssertEqual(callCount, 1, "the second caller should join the check already running")
        XCTAssertEqual(results[0], results[1])
        XCTAssertEqual(results[0].release?.version.description, "0.24")
    }

    func testHomebrewCopyOffersTheUpgradeCommand() throws {
        let controller = controller(
            route: .homebrew(command: "brew upgrade --cask gordonbeeming/tap/myterm"),
            defaults: try defaults()
        )

        XCTAssertEqual(controller.upgradeCommand, "brew upgrade --cask gordonbeeming/tap/myterm")
        XCTAssertEqual(controller.upgradeActionTitle, "Update in a New Tab")
    }

    func testNonHomebrewCopyOffersTheReleaseInstead() throws {
        let controller = controller(route: .releasePage, defaults: try defaults())

        XCTAssertNil(controller.upgradeCommand)
        XCTAssertEqual(controller.upgradeActionTitle, "Open the Release")
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

/// Holds a fetch open so both callers are genuinely in flight at the same time.
private actor Gate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        let resuming = waiting
        waiting.removeAll()
        for continuation in resuming { continuation.resume() }
    }
}
