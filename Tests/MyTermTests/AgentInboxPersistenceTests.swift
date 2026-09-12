import Foundation
import MyTermCore
import XCTest

@testable import MyTerm

/// `agent-notifications.json` as a disk can leave it: empty, cut mid-write, oversized, written by
/// a newer build, or not a regular file at all. Launching must never fail on it, and what survives
/// each shape is spelled out here.
@MainActor
final class AgentInboxPersistenceTests: XCTestCase {
    private var directory: URL!
    private var inboxURL: URL!
    private let workspaceID = WorkspaceID()
    private let tabGroupID = TabGroupID()

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "myterm-inbox-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        inboxURL = MyTermChannel.development.persistenceURL(applicationSupportDirectory: directory)
            .deletingLastPathComponent()
            .appending(path: "agent-notifications.json", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: inboxURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: inboxURL.deletingLastPathComponent().path)
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: inboxURL.path)
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Fixtures

    private func entry(
        tabID: TabID = TabID(),
        activity: AgentActivity = .finished,
        date: Date,
        isRead: Bool = false
    ) -> AgentInboxEntry {
        AgentInboxEntry(tabID: tabID, workspaceID: workspaceID, tabGroupID: tabGroupID, activity: activity, date: date, isRead: isRead)
    }

    private func inbox(with entries: [AgentInboxEntry]) -> AgentNotificationInbox {
        var inbox = AgentNotificationInbox()
        for entry in entries {
            inbox.record(entry.activity, workspaceID: entry.workspaceID, tabGroupID: entry.tabGroupID,
                         tabID: entry.tabID, isTabVisible: entry.isRead, date: entry.date)
        }
        return inbox
    }

    private func json(of inbox: AgentNotificationInbox) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(inbox)) as? [String: Any])
    }

    private func write(_ object: Any) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: inboxURL)
    }

    private func makeModel() throws -> AppModel {
        try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: nil,
            startsTerminalProcesses: false,
            makeAgentNotificationPoster: { RecordingNotificationPoster() },
            isApplicationActive: { false }
        )
    }

    // MARK: - Reading

    func testAZeroByteFileStartsAnEmptyHistory() throws {
        try Data().write(to: inboxURL)
        XCTAssertEqual(AppModel.loadAgentInbox(from: inboxURL), AgentNotificationInbox())
        XCTAssertNoThrow(try makeModel(), "an empty file must not keep the app from launching")
    }

    func testAFileCutMidWriteLosesTheWholeHistory() throws {
        // The whole file is one JSON document, so a cut anywhere loses everything: nothing before
        // the cut is recovered. That is what the entries before the cut are worth after a crash.
        let full = try JSONEncoder().encode(inbox(with: [
            entry(date: Date(timeIntervalSince1970: 10)), entry(date: Date(timeIntervalSince1970: 20)),
        ]))
        try full.prefix(full.count / 2).write(to: inboxURL)
        XCTAssertEqual(AppModel.loadAgentInbox(from: inboxURL).history, [])
        XCTAssertNoThrow(try makeModel())
    }

    func testAFileWithMoreEntriesThanTheCapIsTrimmedToTheNewestOnLoad() throws {
        // Ten megabytes of valid entries, well past the cap of 200.
        var entries: [AgentInboxEntry] = []
        var length = 0
        var second: TimeInterval = 0
        while length < 10 * 1024 * 1024 {
            let batch = (0..<1_000).map { _ -> AgentInboxEntry in
                second += 1
                return entry(date: Date(timeIntervalSince1970: second), isRead: true)
            }
            entries.append(contentsOf: batch)
            length += try JSONEncoder().encode(batch).count
        }
        // Encoded by hand rather than through `record`, which would never let the list grow this far.
        var document = try json(of: AgentNotificationInbox())
        document["entries"] = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entries)) as? [Any])
        try write(document)

        let loaded = AppModel.loadAgentInbox(from: inboxURL)
        XCTAssertEqual(loaded.history.count, AgentNotificationInbox.capacity,
                       "the cap is applied on the way in, and the newest entries are the ones kept")
        XCTAssertEqual(loaded.history.first?.date, Date(timeIntervalSince1970: second))
        XCTAssertEqual(loaded.history.last?.date, Date(timeIntervalSince1970: second - TimeInterval(AgentNotificationInbox.capacity) + 1))
    }

    func testAnUnreadEntryOutlivesReadOnesWhenAnOversizedFileIsTrimmed() throws {
        let unread = entry(date: Date(timeIntervalSince1970: 1), isRead: false)
        let read = (2...(AgentNotificationInbox.capacity + 10)).map {
            entry(date: Date(timeIntervalSince1970: TimeInterval($0)), isRead: true)
        }
        var document = try json(of: AgentNotificationInbox())
        document["entries"] = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode([unread] + read)) as? [Any])
        try write(document)
        let loaded = AppModel.loadAgentInbox(from: inboxURL)
        XCTAssertEqual(loaded.history.count, AgentNotificationInbox.capacity)
        XCTAssertEqual(loaded.history.last?.tabID, unread.tabID, "the oldest entry is kept because it is the one still waiting")
    }

    func testAnUnsortedFileComesBackNewestFirst() throws {
        let older = entry(date: Date(timeIntervalSince1970: 10))
        let newer = entry(date: Date(timeIntervalSince1970: 20))
        var document = try json(of: AgentNotificationInbox())
        document["entries"] = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode([older, newer])) as? [Any])
        try write(document)
        XCTAssertEqual(AppModel.loadAgentInbox(from: inboxURL).history.map(\.tabID), [newer.tabID, older.tabID])
    }

    func testAnOversizedHistoryIsCappedBeforeItIsSentToADevice() throws {
        // The device keeps 200 and the Mac sends its whole history, so a file past the cap would
        // send more than a device keeps unless the Mac trims first.
        let entries = (1...(AgentNotificationInbox.capacity + 50)).map {
            entry(date: Date(timeIntervalSince1970: TimeInterval($0)), isRead: true)
        }
        var document = try json(of: AgentNotificationInbox())
        document["entries"] = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entries)) as? [Any])
        try write(document)

        XCTAssertLessThanOrEqual(AppModel.loadAgentInbox(from: inboxURL).history.count, AgentNotificationInbox.capacity)
    }

    func testEntriesDatedInTheFutureAreKeptAndStayAheadOfNewerRealOnes() throws {
        let future = Date(timeIntervalSinceNow: 365 * 24 * 3_600)
        try JSONEncoder().encode(inbox(with: [entry(date: future)])).write(to: inboxURL)
        var loaded = AppModel.loadAgentInbox(from: inboxURL)
        XCTAssertEqual(loaded.history.map(\.date), [future], "a future date is kept as written")

        loaded.record(.finished, workspaceID: workspaceID, tabGroupID: tabGroupID, tabID: TabID(), isTabVisible: false, date: Date())
        XCTAssertEqual(loaded.history.first?.date, future,
                       "ordering is by date, so an entry from a clock that was ahead sits above everything until it is evicted")
    }

    func testEntriesWithTheSameDateAreKeptInFileOrder() throws {
        let moment = Date(timeIntervalSince1970: 1_000)
        let first = TabID(), second = TabID()
        let stored = inbox(with: [entry(tabID: first, date: moment), entry(tabID: second, date: moment)])
        try JSONEncoder().encode(stored).write(to: inboxURL)
        let loaded = AppModel.loadAgentInbox(from: inboxURL)
        XCTAssertEqual(loaded.history.map(\.tabID), stored.history.map(\.tabID))
        XCTAssertEqual(loaded.history.map(\.tabID), [second, first], "the later record comes first, and a relaunch keeps that")
    }

    func testAnEntryWithAnActivityThisBuildDoesNotKnowIsSkippedNotFatal() throws {
        // A newer build wrote an activity this one has no case for. Losing the whole history for
        // one row is the wrong trade, so the row is skipped and the rest is kept.
        let known = entry(date: Date(timeIntervalSince1970: 10))
        var document = try json(of: inbox(with: [known]))
        var entries = try XCTUnwrap(document["entries"] as? [[String: Any]])
        var unknown = entries[0]
        unknown["activity"] = "pondering"
        unknown["date"] = 20
        unknown["tabID"] = UUID().uuidString.lowercased()
        entries.insert(unknown, at: 0)
        document["entries"] = entries
        try write(document)

        let loaded = AppModel.loadAgentInbox(from: inboxURL)
        XCTAssertEqual(loaded.history.map(\.tabID), [known.tabID])
    }

    func testAnEntryWithAnUnknownExtraFieldIsRead() throws {
        var document = try json(of: inbox(with: [entry(date: Date(timeIntervalSince1970: 10))]))
        var entries = try XCTUnwrap(document["entries"] as? [[String: Any]])
        entries[0]["priority"] = "high"
        document["entries"] = entries
        document["schemaVersion"] = 7
        try write(document)
        XCTAssertEqual(AppModel.loadAgentInbox(from: inboxURL).history.count, 1)
    }

    func testDuplicateEntryIdentifiersAreCollapsedToOne() throws {
        // The identifier is the tab and the moment; two rows with both the same are one event
        // written twice. SwiftUI lists refuse duplicate identifiers, so they must not both be shown.
        let one = entry(date: Date(timeIntervalSince1970: 10))
        var document = try json(of: inbox(with: [one]))
        let entries = try XCTUnwrap(document["entries"] as? [[String: Any]])
        document["entries"] = entries + entries
        try write(document)
        let loaded = AppModel.loadAgentInbox(from: inboxURL)
        XCTAssertEqual(loaded.history.count, 1)
    }

    func testAFileThatIsADirectoryStartsAnEmptyHistoryAndDoesNotStopTheLaunch() throws {
        try FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)
        XCTAssertEqual(AppModel.loadAgentInbox(from: inboxURL), AgentNotificationInbox())
        let model = try makeModel()
        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)
        model.createWorkspace()
        // The write fails, is logged, and the in-memory inbox still works.
        model.recordAgentActivity(AgentActivityReport(agent: "claude", activity: .finished),
                                  workspaceID: workspace.id, tabGroupID: group.id, tabID: group.selectedTabID)
        XCTAssertEqual(model.agentNotificationCount, 1)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: inboxURL.path, isDirectory: &isDirectory) && isDirectory.boolValue,
                      "a directory in the way is left alone")
    }

    func testAFileThatIsASymlinkToDevNullReadsAsEmptyAndIsReplacedByARealFileOnWrite() throws {
        try FileManager.default.createSymbolicLink(atPath: inboxURL.path, withDestinationPath: "/dev/null")
        XCTAssertEqual(AppModel.loadAgentInbox(from: inboxURL), AgentNotificationInbox())
        let model = try makeModel()
        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)
        model.createWorkspace()
        model.recordAgentActivity(AgentActivityReport(agent: "claude", activity: .finished),
                                  workspaceID: workspace.id, tabGroupID: group.id, tabID: group.selectedTabID)
        // An atomic write renames a temp file over the link itself rather than writing through it.
        let attributes = try FileManager.default.attributesOfItem(atPath: inboxURL.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeRegular)
        XCTAssertEqual(AppModel.loadAgentInbox(from: inboxURL).history.count, 1)
    }

    // MARK: - Writing

    func testAReadOnlyFileIsReplacedBecauseTheWriteIsARename() throws {
        try XCTSkipIf(getuid() == 0)
        try JSONEncoder().encode(AgentNotificationInbox()).write(to: inboxURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: inboxURL.path)
        let model = try makeModel()
        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)
        model.createWorkspace()
        model.recordAgentActivity(AgentActivityReport(agent: "claude", activity: .finished),
                                  workspaceID: workspace.id, tabGroupID: group.id, tabID: group.selectedTabID)
        XCTAssertEqual(AppModel.loadAgentInbox(from: inboxURL).history.count, 1,
                       "the file's own mode does not stop a rename into its directory")
    }

    func testAReadOnlyParentDirectoryLosesTheWriteButNotTheSession() throws {
        try XCTSkipIf(getuid() == 0)
        let model = try makeModel()
        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)
        model.createWorkspace()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: inboxURL.deletingLastPathComponent().path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: inboxURL.deletingLastPathComponent().path) }

        model.recordAgentActivity(AgentActivityReport(agent: "claude", activity: .finished),
                                  workspaceID: workspace.id, tabGroupID: group.id, tabID: group.selectedTabID)
        XCTAssertEqual(model.agentNotificationCount, 1, "the bell still rings")
        XCTAssertFalse(FileManager.default.fileExists(atPath: inboxURL.path), "and nothing reached the disk")
    }

    func testTheHistoryComesBackReadAfterARelaunch() throws {
        let model = try makeModel()
        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)
        model.createWorkspace()
        model.recordAgentActivity(AgentActivityReport(agent: "claude", activity: .awaitingInput),
                                  workspaceID: workspace.id, tabGroupID: group.id, tabID: group.selectedTabID)
        XCTAssertEqual(model.agentNotificationCount, 1)

        let relaunched = try makeModel()
        XCTAssertEqual(relaunched.agentNotificationCount, 0)
        XCTAssertEqual(relaunched.remoteNotifications()?.entries.map(\.isRead), [true])
    }
}
