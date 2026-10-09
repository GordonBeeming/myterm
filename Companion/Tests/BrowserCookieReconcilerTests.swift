import MyTermCore
import XCTest

@testable import MyTermCompanion

final class BrowserCookieReconcilerTests: XCTestCase {
    private func cookie(_ name: String, value: String = "v", domain: String = "example.com") throws
        -> RemoteBrowserCookie
    {
        try RemoteBrowserCookie(name: name, value: value, domain: domain, path: "/")
    }

    func testMacDeletionIsFollowedLocallyOnlyWhenBothSidesHadIt() throws {
        let signedOut = try cookie("session")
        let phoneOnly = try cookie("phone-only")

        let plan = BrowserCookieReconciler.plan(
            local: [signedOut, phoneOnly],
            remote: [],
            baseline: [signedOut.sortKey]
        )

        XCTAssertEqual(plan.deleteLocally.map(\.name), ["session"],
                       "A cookie both sides had, now gone from the Mac, was deleted there")
        XCTAssertEqual(plan.push.map(\.name), ["phone-only"],
                       "A cookie the Mac never had is a sign-in made here, not a deletion")
    }

    func testAnIncompletePullIsNotTreatedAsTheWholeJar() {
        // The reconciler decides what to delete from what the Mac did *not* return, so a pull that
        // stopped partway would make every unfetched cookie look deleted. The caller refuses to
        // reconcile unless the pull says it reached the end, and this pins the flag's default: a
        // pull that returns early must never claim completeness.
        XCTAssertFalse(SceneModel.BrowserCookiePull().isComplete)
        XCTAssertTrue(SceneModel.BrowserCookiePull().cookies.isEmpty)

        var finished = SceneModel.BrowserCookiePull()
        finished.isComplete = true
        XCTAssertTrue(finished.isComplete)
    }

    func testFirstSyncWithNoBaselinePushesLocalCookiesRatherThanDeletingThem() throws {
        let local = try cookie("phone")
        let remote = try cookie("mac")

        let plan = BrowserCookieReconciler.plan(local: [local], remote: [remote], baseline: [])

        XCTAssertTrue(plan.deleteLocally.isEmpty, "Nothing may be deleted without a baseline to justify it")
        XCTAssertEqual(plan.push.map(\.name), ["phone"])
        XCTAssertEqual(plan.applyLocally.map(\.name), ["mac"])
        XCTAssertEqual(plan.baseline, Set([local.sortKey, remote.sortKey]))
        XCTAssertEqual(plan.synced, Set([local, remote]))
    }

    func testMacValueWinsForACookieBothSidesHold() throws {
        let mine = try cookie("session", value: "phone")
        let theirs = try cookie("session", value: "mac")

        let plan = BrowserCookieReconciler.plan(
            local: [mine], remote: [theirs], baseline: [mine.sortKey])

        XCTAssertTrue(plan.deleteLocally.isEmpty)
        XCTAssertTrue(plan.push.isEmpty, "The Mac's snapshot is the newer word at session start")
        XCTAssertEqual(plan.applyLocally.map(\.value), ["mac"])
        XCTAssertEqual(plan.synced, Set([theirs]))
    }

    func testPushCarriesChangedCookiesAndDeletionsFromTheBaseline() throws {
        let kept = try cookie("kept")
        let changed = try cookie("changed", value: "new")
        let previouslyChanged = try cookie("changed", value: "old")
        let goneKey = try RemoteBrowserCookieKey(domain: "example.com", path: "/", name: "gone")

        let outcome = BrowserCookieReconciler.push(
            current: [kept, changed],
            synced: Set([kept, previouslyChanged]),
            baseline: Set([kept.sortKey, previouslyChanged.sortKey, goneKey.sortKey])
        )

        XCTAssertEqual(outcome.changed.map(\.name), ["changed"], "Only what the Mac has not seen")
        XCTAssertEqual(outcome.removed.map(\.name), ["gone"], "Signing out here has to reach the Mac")
    }

    func testPushSendsNothingWhenBothJarsAlreadyAgree() throws {
        let settled = try cookie("session")

        let outcome = BrowserCookieReconciler.push(
            current: [settled], synced: Set([settled]), baseline: Set([settled.sortKey]))

        XCTAssertTrue(outcome.changed.isEmpty)
        XCTAssertTrue(outcome.removed.isEmpty)
    }

    func testSortKeyRoundTripsThroughADeletionKeyIncludingAwkwardPaths() throws {
        let awkward = try RemoteBrowserCookie(
            name: "a", value: "v", domain: "sub.example.com", path: "/a/b-c_d/")
        let restored = BrowserCookieReconciler.key(fromSortKey: awkward.sortKey)

        XCTAssertEqual(restored?.domain, "sub.example.com")
        XCTAssertEqual(restored?.path, "/a/b-c_d/")
        XCTAssertEqual(restored?.name, "a")
        XCTAssertEqual(restored?.sortKey, awkward.sortKey)
    }

    func testAMalformedSortKeyIsRejectedRatherThanDeletingTheWrongCookie() {
        XCTAssertNil(BrowserCookieReconciler.key(fromSortKey: "example.com"))
        XCTAssertNil(BrowserCookieReconciler.key(fromSortKey: "a\u{1F}b\u{1F}c\u{1F}d"))
        XCTAssertNil(BrowserCookieReconciler.key(fromSortKey: "\u{1F}\u{1F}"))
    }
}
