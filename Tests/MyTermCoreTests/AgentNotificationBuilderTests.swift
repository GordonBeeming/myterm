import XCTest
@testable import MyTermCore

final class AgentNotificationBuilderTests: XCTestCase {
    private let workspaceID = WorkspaceID()
    private let tabID = TabID()

    func testAFinishAndAQuestionReadDifferently() throws {
        let finished = try XCTUnwrap(notification(for: .finished))
        XCTAssertEqual(finished.body, "Claude finished its turn.")

        let question = try XCTUnwrap(notification(for: .awaitingInput))
        XCTAssertEqual(question.body, "Claude has a question.")
    }

    func testAWorkingAgentIsNotWorthABanner() {
        XCTAssertNil(notification(for: .working))
    }

    func testTheAgentNamesItself() throws {
        let report = AgentActivityReport(agent: "codex", activity: .finished)
        let built = try XCTUnwrap(notification(for: .finished, report: report))
        XCTAssertEqual(built.body, "Codex finished its turn.")
    }

    func testTheTitleFollowsTheNamingChoice() {
        XCTAssertEqual(
            AgentNotificationBuilder.title(workspaceTitle: "api", tabTitle: "tests", naming: .workspace),
            "api"
        )
        XCTAssertEqual(
            AgentNotificationBuilder.title(workspaceTitle: "api", tabTitle: "tests", naming: .tab),
            "tests"
        )
        XCTAssertEqual(
            AgentNotificationBuilder.title(workspaceTitle: "api", tabTitle: "tests", naming: .workspaceAndTab),
            "api — tests"
        )
    }

    func testANameIsNeverSaidTwice() {
        XCTAssertEqual(
            AgentNotificationBuilder.title(workspaceTitle: "api", tabTitle: "API", naming: .workspaceAndTab),
            "api"
        )
    }

    func testAnEmptyNameFallsBackRatherThanLeavingABlankBanner() {
        XCTAssertEqual(
            AgentNotificationBuilder.title(workspaceTitle: "   ", tabTitle: "tests", naming: .workspace),
            "tests"
        )
        XCTAssertEqual(
            AgentNotificationBuilder.title(workspaceTitle: "", tabTitle: " ", naming: .workspaceAndTab),
            AgentNotificationBuilder.fallbackTitle
        )
    }

    func testTheColourAndTheTabRideAlong() throws {
        let built = try XCTUnwrap(notification(for: .finished, color: .purple))
        XCTAssertEqual(built.color, .purple)
        XCTAssertEqual(built.workspaceID, workspaceID)
        XCTAssertEqual(built.tabID, tabID)
    }

    private func notification(
        for activity: AgentActivity,
        report: AgentActivityReport? = nil,
        color: WorkspaceColor? = nil
    ) -> AgentNotification? {
        AgentNotificationBuilder.notification(
            for: report ?? AgentActivityReport(agent: "claude", activity: activity),
            workspaceID: workspaceID,
            workspaceTitle: "api",
            tabID: tabID,
            tabTitle: "tests",
            color: color,
            naming: .workspaceAndTab
        )
    }
}
