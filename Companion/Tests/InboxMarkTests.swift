import Foundation
import MyTermCore
import MyTermRemote
import XCTest
@testable import MyTermCompanion

/// The read and dismiss marks behind the inbox's blue dot and swipe-to-dismiss.
@MainActor
final class InboxMarkTests: XCTestCase {
    private let connection = SavedConnectionID(relayOrigin: "https://relay.example.test",
                                               accountID: UUID(), hostID: UUID())
    private let tabID = TabID(rawValue: UUID())
    private let start = Date(timeIntervalSince1970: 1_000)

    private func scene() -> SceneModel {
        let scene = SceneModel()
        scene.selectedConnectionID = connection
        return scene
    }

    private func tab(_ activity: AgentActivity?, at date: Date?) -> RemoteTabProjection {
        RemoteTabProjection(id: tabID, title: "agent", kind: .terminal,
                            terminalSessionID: TerminalSessionID(rawValue: UUID()),
                            agentActivity: activity, agentActivityDate: date)
    }

    private func projection(_ tab: RemoteTabProjection) -> RemoteWorkspaceProjection {
        let group = RemoteTabGroupProjection(id: TabGroupID(rawValue: UUID()), selectedTabID: tab.id, tabs: [tab])
        return RemoteWorkspaceProjection(folders: [], workspaces: [
            RemoteWorkspaceItem(id: WorkspaceID(rawValue: UUID()), title: "w", folderID: nil, isPinned: false,
                                color: nil, emoji: nil, focusedGroupID: group.id, groups: [group])
        ])
    }

    func testAReadQuestionStaysReadUntilTheAgentDoesSomethingNew() {
        let scene = scene()
        let question = tab(.awaitingInput, at: start)
        scene.markInboxRowRead(question)
        XCTAssertTrue(scene.isInboxRowRead(question))
        XCTAssertFalse(scene.isInboxRowRead(tab(.awaitingInput, at: start.addingTimeInterval(1))),
                       "A newer question is unread again")
    }

    func testADismissedFinishedRowStaysHiddenWhenTheReadTurnsItReady() {
        let scene = scene()
        scene.dismissInboxRow(tab(.finished, at: start))
        let ready = tab(.ready, at: start)
        scene.pruneInboxMarks(in: projection(ready), connection: connection)
        XCTAssertTrue(scene.isInboxRowDismissed(ready))
    }

    func testADismissedRowComesBackWhenTheAgentStartsWorking() {
        let scene = scene()
        scene.dismissInboxRow(tab(.finished, at: start))
        // Working does not move the activity date, so the state change alone must end the mark.
        let working = tab(.working, at: start)
        XCTAssertFalse(scene.isInboxRowDismissed(working))
    }

    func testWithoutDatesAMarkEndsOnceTheAgentWorksAndDoesNotReturn() {
        let scene = scene()
        scene.markInboxRowRead(tab(.finished, at: nil))
        scene.dismissInboxRow(tab(.finished, at: nil))
        scene.pruneInboxMarks(in: projection(tab(.working, at: nil)), connection: connection)
        let finishedAgain = tab(.finished, at: nil)
        scene.pruneInboxMarks(in: projection(finishedAgain), connection: connection)
        XCTAssertFalse(scene.isInboxRowRead(finishedAgain), "An older host's second finish is unread")
        XCTAssertFalse(scene.isInboxRowDismissed(finishedAgain))
    }

    func testARejectedReadIsUndone() {
        let scene = scene()
        let finished = tab(.finished, at: start)
        scene.markInboxRowRead(finished)
        scene.clearInboxRowRead(finished, connection: connection)
        XCTAssertFalse(scene.isInboxRowRead(finished))
    }
}
