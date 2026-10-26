import Foundation
import XCTest
@testable import MyTermCore

final class SessionNavigationTests: XCTestCase {
    private let folderID = WorkspaceFolderID()
    private let workspaceID = WorkspaceID()
    private let groupID = TabGroupID()

    private func projection(_ tabs: [RemoteTabProjection]) -> RemoteWorkspaceProjection {
        RemoteWorkspaceProjection(folders: [RemoteFolderProjection(id: folderID, title: "Client", color: .blue)],
            workspaces: [RemoteWorkspaceItem(id: workspaceID, title: "API work", folderID: folderID,
                isPinned: false, color: nil, emoji: nil, preferences: nil,
                groups: [RemoteTabGroupProjection(id: groupID, selectedTabID: tabs[0].id, tabs: tabs)])])
    }

    private func tab(_ title: String, activity: AgentActivity? = nil, time: Double = 0) -> RemoteTabProjection {
        RemoteTabProjection(id: TabID(), title: title, kind: .terminal,
            terminalSessionID: TerminalSessionID(), workingDirectory: URL(fileURLWithPath: "/src/service"),
            agentActivity: activity, agentActivityDate: Date(timeIntervalSince1970: time))
    }

    func testSearchIncludesFolderWorkspaceTitleAndPathWithoutDuplicatingDestinations() {
        let a = tab("Codex review"), b = tab("Claude implementation")
        let source = projection([a, b])
        let results = SessionNavigationItem.items(in: source, query: "client API codex service")
        XCTAssertEqual(results.map(\.id), [a.id])
        XCTAssertEqual(results.first?.workspaceID, workspaceID)
        XCTAssertEqual(results.first?.groupID, groupID)
        XCTAssertTrue(SessionNavigationItem.items(in: source, query: "missing").isEmpty)
    }

    func testInboxKeepsReadQuestionsAndSortsRecentAttentionAheadOfWorkingTabs() {
        let question = tab("Question", activity: .awaitingInput, time: 20)
        let finished = tab("Finished", activity: .finished, time: 10)
        let working = tab("Working", activity: .working, time: 30)
        let source = projection([working, finished, question])
        XCTAssertEqual(SessionNavigationItem.items(in: source, attentionOnly: true).map(\.id),
                       [question.id, finished.id])
        XCTAssertEqual(SessionNavigationItem.items(in: source).map(\.id),
                       [question.id, finished.id, working.id])
        let readQuestion = tab("Read question", activity: AgentActivity.awaitingInput.afterReading, time: 40)
        XCTAssertEqual(SessionNavigationItem.items(in: projection([readQuestion]), attentionOnly: true).count, 1)
        let answered = tab("Read question", activity: .working, time: 50)
        XCTAssertTrue(SessionNavigationItem.items(in: projection([answered]), attentionOnly: true).isEmpty)
    }

    func testEmptyQuickJumpUsesActualRecencyButInboxUsesEventTime() {
        let first = tab("Terminal first", time: 10)
        let recent = tab("Terminal recent", time: 20)
        let question = tab("Question", activity: .awaitingInput, time: 30)
        let newerQuestion = tab("New question", activity: .awaitingInput, time: 40)
        let source = projection([first, question, recent, newerQuestion])
        XCTAssertEqual(SessionNavigationItem.items(in: source, prioritizeAttention: false,
            recentTabIDs: [recent.id, first.id]).map(\.id),
            [question.id, newerQuestion.id, recent.id, first.id])
        XCTAssertEqual(SessionNavigationItem.items(in: source, query: "Terminal", prioritizeAttention: false,
            recentTabIDs: [recent.id]).map(\.id), [first.id, recent.id],
            "Searching uses existing tab order, not unrelated focus history")
        XCTAssertEqual(SessionNavigationItem.items(in: source, recentTabIDs: [question.id]).prefix(2).map(\.id),
            [newerQuestion.id, question.id], "Inbox ordering uses host attention dates, not local recency")
    }

    func testMailInboxRetainsReadSessionsBelowNewAttention() {
        let read = tab("Read", activity: nil, time: 5)
        let newQuestion = tab("New question", activity: .awaitingInput, time: 40)
        let working = tab("Working", activity: .working, time: 30)
        let rows = SessionNavigationItem.items(in: projection([read, working, newQuestion]))
        XCTAssertEqual(rows.map(\.id), [newQuestion.id, working.id, read.id])
        XCTAssertEqual(rows.count, 3, "Reading clears attention, not the session's inbox row")
    }

    func testOlderHostProjectionWithoutDateStillDecodes() throws {
        let source = tab("Old host", activity: .awaitingInput)
        let data = try JSONEncoder().encode(source)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "agentActivityDate")
        let decoded = try JSONDecoder().decode(RemoteTabProjection.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.agentActivityDate)
        XCTAssertEqual(decoded.agentActivity, .awaitingInput)
    }
}
