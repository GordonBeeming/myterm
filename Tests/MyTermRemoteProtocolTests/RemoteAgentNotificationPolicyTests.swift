import MyTermCore
import XCTest
@testable import MyTermRemoteProtocol

final class RemoteAgentNotificationPolicyTests: XCTestCase {
    private let tree = RemoteTree(
        revision: 1,
        folders: [],
        workspaces: [
            RemoteWorkspace(
                id: "ws-api",
                title: "api",
                tabs: [
                    RemoteTab(id: "tab-server", kind: .terminal, title: "server", agentActivity: .working),
                    RemoteTab(id: "tab-api", kind: .terminal, title: "api"),
                ]
            ),
        ]
    )

    private func policy(
        isEnabled: Bool = true,
        isApplicationActive: Bool = false,
        visibleTabID: String? = nil
    ) -> RemoteAgentNotificationPolicy {
        RemoteAgentNotificationPolicy(
            isEnabled: isEnabled,
            isApplicationActive: isApplicationActive,
            visibleTabID: visibleTabID
        )
    }

    private func report(_ tabID: String, _ activity: AgentActivity?) -> RemoteAgentActivity {
        RemoteAgentActivity(tabID: tabID, activity: activity)
    }

    func testAFinishedTurnAwayFromTheAppIsPostedWithTheMacsTitleRule() {
        let action = policy().action(for: report("tab-server", .finished), in: tree)

        XCTAssertEqual(action, .post(RemoteAgentNotificationContent(
            tabID: "tab-server",
            workspaceID: "ws-api",
            title: "api — server",
            body: "Agent finished"
        )))
    }

    func testAQuestionIsPostedWithItsOwnWords() {
        let action = policy().action(for: report("tab-server", .awaitingInput), in: tree)

        guard case .post(let content) = action else { return XCTFail("expected a post, got \(action)") }
        XCTAssertEqual(content.body, "Agent is waiting for you")
    }

    func testAOneTabWorkspaceIsNamedOnce() {
        let action = policy().action(for: report("tab-api", .finished), in: tree)

        guard case .post(let content) = action else { return XCTFail("expected a post, got \(action)") }
        XCTAssertEqual(content.title, "api")
    }

    func testTheAppOnAnotherTabStillGetsABanner() {
        let action = policy(isApplicationActive: true, visibleTabID: "tab-api")
            .action(for: report("tab-server", .finished), in: tree)

        guard case .post = action else { return XCTFail("expected a post, got \(action)") }
    }

    func testTheTabInFrontOfThePersonWithdrawsRatherThanPosts() {
        let action = policy(isApplicationActive: true, visibleTabID: "tab-server")
            .action(for: report("tab-server", .awaitingInput), in: tree)

        XCTAssertEqual(action, .withdraw(tabID: "tab-server"))
    }

    func testTheVisibleTabStillPostsOnceTheAppIsAway() {
        let action = policy(isApplicationActive: false, visibleTabID: "tab-server")
            .action(for: report("tab-server", .finished), in: tree)

        guard case .post = action else { return XCTFail("expected a post, got \(action)") }
    }

    func testTheMacReadingTheTabWithdraws() {
        XCTAssertEqual(
            policy().action(for: report("tab-server", nil), in: tree),
            .withdraw(tabID: "tab-server")
        )
    }

    func testTheAgentMovingOnWithdraws() {
        XCTAssertEqual(
            policy().action(for: report("tab-server", .working), in: tree),
            .withdraw(tabID: "tab-server")
        )
    }

    func testARepeatOfTheSameStateIsNotPostedAgain() {
        var waiting = tree
        waiting.workspaces[0].tabs[0].agentActivity = .awaitingInput

        let action = policy().action(for: report("tab-server", .awaitingInput), in: waiting)

        XCTAssertEqual(action, .none)
    }

    func testAQuestionAfterAFinishedTurnIsAChange() {
        var finished = tree
        finished.workspaces[0].tabs[0].agentActivity = .finished

        let action = policy().action(for: report("tab-server", .awaitingInput), in: finished)

        guard case .post = action else { return XCTFail("expected a post, got \(action)") }
    }

    func testSwitchedOffPostsNothingButStillWithdraws() {
        let off = policy(isEnabled: false)

        XCTAssertEqual(off.action(for: report("tab-server", .finished), in: tree), .none)
        XCTAssertEqual(off.action(for: report("tab-server", nil), in: tree), .withdraw(tabID: "tab-server"))
    }

    func testATabTheDeviceDoesNotKnowIsNotPosted() {
        XCTAssertEqual(policy().action(for: report("tab-gone", .finished), in: tree), .none)
        XCTAssertEqual(policy().action(for: report("tab-server", .finished), in: nil), .none)
    }
}
