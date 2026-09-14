import Foundation
import MyTermRemoteProtocol

/// What an attach produced: the live session, its grid, and the screen to paint before live bytes.
public struct RemoteAttachment: Sendable {
    /// Names this one attachment, so detaching one device never silences another watching the
    /// same session.
    public let id: UUID
    public let session: UUID
    public let columns: Int
    public let rows: Int
    public let snapshot: [UInt8]

    public init(id: UUID = UUID(), session: UUID, columns: Int, rows: Int, snapshot: [UInt8]) {
        self.id = id
        self.session = session
        self.columns = columns
        self.rows = rows
        self.snapshot = snapshot
    }
}

/// The host's window onto the running app.
///
/// The listener owns sockets and framing and knows nothing about workspaces or terminals. Keeping
/// that boundary here is what lets the whole connection path be tested without an app, a window, or
/// a real process.
@MainActor
public protocol RemoteHostDataSource: AnyObject {
    /// The current tree, already flattened and stripped of anything a device must not receive.
    func remoteTree() -> RemoteTree

    /// Begins mirroring a tab. `output` is called for every byte the process writes.
    /// Returns nil when the tab does not exist or is not a terminal.
    func attach(
        tabID: String,
        output: @escaping @MainActor (ArraySlice<UInt8>) -> Void
    ) -> RemoteAttachment?

    /// Stops mirroring for one attachment. Other devices attached to the same session keep
    /// receiving output. Must be safe to call for an attachment that is already gone.
    func detach(attachment: UUID)

    /// Sends bytes to the process as if the user typed them.
    func sendInput(session: UUID, bytes: ArraySlice<UInt8>)

    /// The screen as it is now, for a resync.
    func snapshot(session: UUID) -> RemoteAttachment?

    /// The backlog of agents waiting for the user, as the Mac's bell lists it.
    ///
    /// `nil` means this source keeps no backlog, and nothing is sent. Defaulted, because a source
    /// that only serves terminals is a complete source, and every test fake is one of those.
    func remoteNotifications() -> RemoteNotifications?

    /// The agent conversation this tab is in, when it has one.
    ///
    /// The host projects the conversation by reading the agent's own transcript, so this only has
    /// to name the agent and the conversation. `nil` means there is nothing to project and the
    /// device falls back to the terminal.
    ///
    /// Defaulted, because a source that serves terminals and knows nothing about agents is a
    /// complete source. Every test fake is one of those.
    func agentSession(tabID: String) -> RemoteAgentSession?

    // Changing the workspaces from a device. Each returns false when the request named something
    // that is not there, which the host reports back rather than leaving the device to guess.
    //
    // These carry no confirmation of their own. The device asks the user before it sends, and the
    // Mac must not block on a modal for something nobody is sitting in front of.

    /// Blank or `nil` restores the tab's automatic title.
    func renameTab(tabID: String, title: String?) -> Bool

    /// Closes the tab and ends its process.
    func closeTab(tabID: String) -> Bool

    func renameWorkspace(workspaceID: String, title: String) -> Bool

    /// `nil` title accepts the name the Mac would have chosen.
    func createWorkspace(title: String?, folderID: String?) -> Bool

    /// Deletes the workspace and ends every process in it.
    func deleteWorkspace(workspaceID: String) -> Bool

    func createTerminalTab(workspaceID: String) -> Bool

    /// Types into a tab's terminal without the device holding an attachment.
    ///
    /// Following a conversation is not attaching, so answering one cannot require it either.
    /// Returns whether the tab was found and written to.
    func sendInput(tabID: String, bytes: ArraySlice<UInt8>) -> Bool

    /// The tab's visible screen as plain rows.
    ///
    /// Needed to read the menu an agent draws when it stops for permission. The options are on the
    /// screen and nowhere else: the agent's own record says a tool was requested, never what the
    /// person is being offered or which number each choice sits on.
    func visibleRows(tabID: String) -> [String]?
}

public extension RemoteHostDataSource {
    func remoteNotifications() -> RemoteNotifications? { nil }
    func agentSession(tabID: String) -> RemoteAgentSession? { nil }
    func sendInput(tabID: String, bytes: ArraySlice<UInt8>) -> Bool { false }
    func visibleRows(tabID: String) -> [String]? { nil }
}
