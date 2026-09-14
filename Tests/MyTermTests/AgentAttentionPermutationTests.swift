import Foundation
import XCTest
import MyTermCore
@testable import MyTerm

/// The cook, the bell, and the banner across every order three hook events can arrive in, with
/// the tab in front of the user and not, and MyTerm in front and not.
///
/// The one order left out is a Stop straight after an unread Notification, which round one
/// filed as an open finding (`AgentNotificationInbox.record` drops the finish and the bell keeps
/// saying the agent is asking). Its red test lives on that branch and is not repeated here.
@MainActor
final class AgentAttentionPermutationTests: XCTestCase {
    private let states: [AgentActivity] = [.working, .awaitingInput, .finished, .ready]

    private var permutations: [[AgentActivity]] {
        var result: [[AgentActivity]] = []
        for a in states {
            for b in states where b != a {
                for c in states where c != a && c != b {
                    result.append([a, b, c])
                }
            }
        }
        return result.filter { !$0.hasFinishStraightAfterQuestion }
    }

    func testAHiddenTabsCookAndBellNeverDisagree() throws {
        for sequence in permutations {
            let harness = try makeHarness()
            let model = harness.model
            let workspace = model.selectedWorkspace
            let group = try XCTUnwrap(workspace.orderedGroups.first)
            let tabID = group.selectedTabID
            model.createWorkspace()

            for (index, activity) in sequence.enumerated() {
                harness.record(activity, workspaceID: workspace.id, tabGroupID: group.id, tabID: tabID)
                let cook = model.agentAttention(forTab: tabID)
                let bell = model.agentActivity(forTab: tabID)
                let context = "\(sequence.map(\.rawValue)) after \(index + 1)"
                XCTAssertEqual(cook, activity.showsCook ? activity : nil, context)
                XCTAssertEqual(bell, activity.needsAttention ? activity : nil, context)
                XCTAssertEqual(model.needsAgentAttention(workspaceID: workspace.id), bell != nil, context)
                XCTAssertEqual(model.agentAttention(forWorkspace: workspace.id), cook, context)
            }
            XCTAssertTrue(harness.poster.posted.isEmpty, "MyTerm is in front, so nothing is posted")

            model.selectWorkspace(workspace.id)
            XCTAssertNil(model.agentActivity(forTab: tabID), "reaching the tab empties the bell: \(sequence)")
            XCTAssertEqual(model.agentAttention(forTab: tabID), sequence.last?.afterReadingCook, "\(sequence)")
        }
    }

    func testTheTabInFrontNeverRingsTheBellOrPostsABanner() throws {
        for sequence in permutations {
            let harness = try makeHarness()
            let model = harness.model
            let workspace = model.selectedWorkspace
            let group = try XCTUnwrap(workspace.orderedGroups.first)
            let tabID = group.selectedTabID

            for activity in sequence {
                harness.record(activity, workspaceID: workspace.id, tabGroupID: group.id, tabID: tabID)
                XCTAssertNil(model.agentActivity(forTab: tabID), "\(sequence)")
                XCTAssertEqual(model.agentAttention(forTab: tabID), activity.afterReadingCook, "\(sequence)")
            }
            XCTAssertTrue(harness.poster.posted.isEmpty)
            XCTAssertEqual(
                model.remoteNotifications()?.entries.filter { !$0.isRead }.count, 0,
                "a device learns what happened, marked read: \(sequence)"
            )
        }
    }

    func testTheSelectedTabBehindAnotherAppIsFiledAndPostedThenReadOnReturn() throws {
        // Hidden with ⌘H, behind another app, or on a Space without MyTerm: all are "not active".
        for sequence in permutations {
            let harness = try makeHarness()
            harness.notifications.isEnabled = true
            harness.isApplicationActive = false
            let model = harness.model
            let workspace = model.selectedWorkspace
            let group = try XCTUnwrap(workspace.orderedGroups.first)
            let tabID = group.selectedTabID

            var expectedBanners = 0
            for activity in sequence {
                harness.record(activity, workspaceID: workspace.id, tabGroupID: group.id, tabID: tabID)
                if activity.needsAttention { expectedBanners += 1 }
                XCTAssertEqual(model.agentAttention(forTab: tabID), activity.showsCook ? activity : nil, "\(sequence)")
                XCTAssertEqual(model.agentActivity(forTab: tabID), activity.needsAttention ? activity : nil, "\(sequence)")
            }
            XCTAssertEqual(harness.poster.posted.count, expectedBanners, "\(sequence)")

            harness.isApplicationActive = true
            model.markVisibleTabsAsRead()
            XCTAssertNil(model.agentActivity(forTab: tabID), "\(sequence)")
            XCTAssertEqual(model.agentAttention(forTab: tabID), sequence.last?.afterReadingCook, "\(sequence)")
        }
    }

    func testAHiddenTabWithADeviceAttachedStillFilesTheEntryForTheMac() throws {
        // A device attached to the tab changes nothing about what the Mac shows: the Mac is the
        // only place that reads its own backlog.
        let harness = try makeHarness()
        let model = harness.model
        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)
        let tabID = group.selectedTabID
        model.createWorkspace()
        harness.record(.awaitingInput, workspaceID: workspace.id, tabGroupID: group.id, tabID: tabID)
        XCTAssertEqual(model.agentNotificationCount, 1)
        XCTAssertEqual(model.remoteNotifications()?.entries.first?.isRead, false)
    }

    private func makeHarness() throws -> AgentTestHarness {
        try AgentTestHarness { directory in
            addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        }
    }
}

private extension AgentActivity {
    /// What the cook shows once the tab has been looked at.
    var afterReadingCook: AgentActivity? {
        showsCook ? afterReading : nil
    }
}

private extension Array where Element == AgentActivity {
    var hasFinishStraightAfterQuestion: Bool {
        for (index, activity) in enumerated() where activity == .finished && index > 0 {
            if self[index - 1] == .awaitingInput { return true }
        }
        return false
    }
}
