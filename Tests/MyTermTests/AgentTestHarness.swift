import MyTermCore
import XCTest

@testable import MyTerm

// The shared fixture for every agent test. It lives in its own file rather than at the foot of one
// test case, because more than one suite builds an `AppModel` this way and a harness that belongs
// to one file goes missing the moment that file is rewritten.

/// An `AppModel` with the two things agent attention depends on under the test's control: whether
/// MyTerm is the app in front, and where notifications go.
@MainActor
final class AgentTestHarness {
    let model: AppModel
    let poster: RecordingNotificationPoster
    let notifications: AgentNotificationSettings

    var isApplicationActive: Bool {
        get { activeFlag.isActive }
        set { activeFlag.isActive = newValue }
    }

    private let activeFlag: ActiveFlag

    init(registerTeardown: (URL) -> Void) throws {
        let poster = RecordingNotificationPoster()
        let activeFlag = ActiveFlag()
        self.poster = poster
        self.activeFlag = activeFlag

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "myterm-agent-attention-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        registerTeardown(directory)

        let defaults = try XCTUnwrap(UserDefaults(suiteName: "myterm-agent-tests-\(UUID().uuidString)"))
        notifications = AgentNotificationSettings(channel: .development, defaults: defaults)
        model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: nil,
            startsTerminalProcesses: false,
            agentNotifications: notifications,
            makeAgentNotificationPoster: { poster },
            isApplicationActive: { activeFlag.isActive }
        )
    }

    func record(
        _ activity: AgentActivity,
        agent: String = "claude",
        workspaceID: WorkspaceID,
        tabGroupID: TabGroupID,
        tabID: TabID
    ) {
        model.recordAgentActivity(
            AgentActivityReport(agent: agent, activity: activity),
            workspaceID: workspaceID,
            tabGroupID: tabGroupID,
            tabID: tabID
        )
    }
}

@MainActor
final class ActiveFlag {
    var isActive = true
}

@MainActor
final class RecordingNotificationPoster: AgentNotificationPosting {
    var openTab: ((WorkspaceID, TabID) -> Void)?
    private(set) var authorizationRequests = 0
    private(set) var posted: [AgentNotification] = []

    func requestAuthorization() {
        authorizationRequests += 1
    }

    func post(_ notification: AgentNotification) {
        posted.append(notification)
    }
}
