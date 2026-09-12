import Foundation
import MyTermRemoteProtocol
import Observation
import SwiftUI
import UIKit

/// Owns the one `RemoteClient` for the app's lifetime and turns its delegate callbacks into state
/// SwiftUI can observe, or into per-attachment closures that a terminal screen installs only while
/// it is the thing showing that session's bytes.
@MainActor
@Observable
final class RemoteSessionStore {
    let client: RemoteClient
    private(set) var tree: RemoteTree?
    /// What agents did while the person was away, and what they have read of it. Not cleared with
    /// the tree: it is the device's own record, and leaving a Mac does not unmake what happened.
    let notifications = RemoteNotificationLogStore()
    /// The last request the Mac refused, for a passing banner. Cleared on its own.
    private(set) var refusal: RemoteError?
    /// Why the tab on screen could not be attached, when the Mac said so.
    private(set) var attachRefusal: String?
    /// The agent conversation the screen on show is following, if any.
    ///
    /// One at a time, like the terminal attachment: a device shows one tab, and holding conversations
    /// for tabs nobody is looking at would keep the Mac reading files for nothing.
    private(set) var conversation: RemoteAgentConversation?
    /// Set while a conversation has been asked for and nothing has come back. The file may not exist
    /// yet, which is normal for the first seconds of an agent session.
    private(set) var isLoadingConversation = false
    /// What the tab's screen is offering, when the agent has stopped to ask. Empty means there is
    /// nothing to answer, which is the ordinary case.
    private(set) var promptOptions: [RemoteAgentPromptOption] = []
    /// Set while an answer is in flight, so the buttons cannot be pressed twice.
    private(set) var isAnswering = false
    /// The dialog a screen-only command drew on the followed tab, while the Mac says it is up.
    /// Its rows are already in the conversation as the command's output; this is what keeps the
    /// offer to dismiss it on screen.
    private(set) var screen: RemoteAgentScreen?
    /// Set while a dismissal is in flight, so the button cannot be pressed twice.
    private(set) var isDismissingScreen = false
    /// The tab whose screen is showing. Reaching a tab takes its banner down, and an agent that
    /// reports in this tab has nothing to announce.
    @ObservationIgnored
    var visibleTabID: String? {
        didSet {
            if let visibleTabID, visibleTabID != oldValue {
                notifier?.withdraw(tabID: visibleTabID)
            }
        }
    }

    /// Set by whichever `TerminalScreen` is currently attached; cleared when it detaches.
    @ObservationIgnored
    private(set) var onAttach: ((RemoteAttached) -> Void)?
    @ObservationIgnored
    private(set) var onOutput: (([UInt8], UUID) -> Void)?
    @ObservationIgnored
    private(set) var onResync: ((UUID) -> Void)?

    /// The screen these callbacks belong to. A pushed screen installs its callbacks before the
    /// screen it replaced is torn down, so a departing screen must not clear its successor's.
    @ObservationIgnored
    private weak var attachmentOwner: AnyObject?
    /// The screen following the conversation, and which tab, kept apart from `conversation`
    /// because a follow that has not been answered yet is still a follow.
    @ObservationIgnored
    private weak var followOwner: AnyObject?
    @ObservationIgnored
    private var followedTabID: String?
    @ObservationIgnored
    private var refusalTimer: Task<Void, Never>?
    @ObservationIgnored
    private var answeringTimer: Task<Void, Never>?
    @ObservationIgnored
    private let notifier: AgentNotifier?
    /// Read at the moment a report arrives rather than mirrored from `scenePhase`: inactive covers
    /// the lock screen and the app switcher, both of which are away from the tab.
    @ObservationIgnored
    var isApplicationActive: () -> Bool = { UIApplication.shared.applicationState == .active }

    init(deviceName: String, notifier: AgentNotifier? = nil) {
        client = RemoteClient(deviceName: deviceName)
        self.notifier = notifier
        client.delegate = self
    }

    func claimAttachment(
        owner: AnyObject,
        onAttach: @escaping (RemoteAttached) -> Void,
        onOutput: @escaping ([UInt8], UUID) -> Void,
        onResync: @escaping (UUID) -> Void
    ) {
        attachmentOwner = owner
        attachRefusal = nil
        self.onAttach = onAttach
        self.onOutput = onOutput
        self.onResync = onResync
    }

    func releaseAttachment(owner: AnyObject) {
        guard attachmentOwner === owner else { return }
        attachmentOwner = nil
        attachRefusal = nil
        onAttach = nil
        onOutput = nil
        onResync = nil
    }

    /// Starts following a tab's agent conversation, dropping whatever was followed before.
    ///
    /// `owner` is the screen asking. As with the terminal attachment, a replacing screen can
    /// appear before the one it replaces has gone, and the departing screen's stop must not undo
    /// what its successor just started, for the same tab or another.
    func followConversation(tabID: String, owner: AnyObject) {
        if let current = followedTabID, current != tabID {
            client.detachAgent(tabID: current)
        }
        followOwner = owner
        followedTabID = tabID
        // What was read off the Mac's screen for the last follow is not this one's. Another
        // tab's prompt or dialog must not be offered under this tab's name: a screen that
        // replaces another can appear before its predecessor has gone, and the predecessor's
        // stop, seeing it is no longer the follower, then clears nothing. After a reconnect the
        // Mac reads the screen again and says what is there now.
        promptOptions = []
        clearAnswering()
        screen = nil
        isDismissingScreen = false
        if conversation?.tabID != tabID {
            conversation = nil
        }
        // The same tab keeps its words on screen until the fresh copy lands, which is what a
        // re-follow after a reconnect wants: nothing blinks, and the tail catches up.
        isLoadingConversation = conversation == nil
        client.attachAgent(tabID: tabID)
    }

    func stopFollowingConversation(tabID: String, owner: AnyObject) {
        guard followOwner === owner else { return }
        followOwner = nil
        followedTabID = nil
        client.detachAgent(tabID: tabID)
        if conversation?.tabID == tabID {
            conversation = nil
        }
        isLoadingConversation = false
        promptOptions = []
        clearAnswering()
        screen = nil
        isDismissingScreen = false
    }

    /// Sends words to the agent, or says why they cannot go.
    ///
    /// Checked here, before anything leaves the phone, with the same rule the Mac applies. The
    /// Mac's refusal comes back after the words have been sent, and a field that had already
    /// cleared itself would have lost them. Returns whether the text went, so the field keeps
    /// what it holds when it did not.
    @discardableResult
    func reply(tabID: String, text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let reply = RemoteAgentReply(tabID: tabID, text: trimmed)
        if let problem = reply.problem {
            guard problem != .empty else { return false }
            show(RemoteError(code: Self.deviceRefusalCode, message: problem.message))
            return false
        }
        client.replyToAgent(tabID: tabID, text: trimmed)
        return true
    }

    /// The code of a refusal the phone made on its own, whose message is already in the phone's
    /// words and is shown as it is.
    static let deviceRefusalCode = "device"

    /// Sends the whole option rather than its number. The Mac checks the label is still on that
    /// number before it types anything, so a menu that changed answers nothing at all.
    func answerPrompt(tabID: String, option: RemoteAgentPromptOption) {
        beginAnswering()
        client.answerAgentPrompt(tabID: tabID, option: option)
    }

    func denyPrompt(tabID: String) {
        beginAnswering()
        client.denyAgentPrompt(tabID: tabID)
    }

    /// How long the buttons stay down waiting for the Mac to say what its screen shows now.
    ///
    /// The Mac reports the prompt again only when it changes. A deny whose Escape changed nothing,
    /// or a report that was lost with the connection, would otherwise leave the buttons down for
    /// good, with nothing the person could do but leave the tab.
    static let answeringTimeout: Duration = .seconds(5)

    private func beginAnswering() {
        isAnswering = true
        answeringTimer?.cancel()
        answeringTimer = Task { [weak self] in
            try? await Task.sleep(for: Self.answeringTimeout)
            guard !Task.isCancelled else { return }
            self?.isAnswering = false
        }
    }

    private func clearAnswering() {
        answeringTimer?.cancel()
        answeringTimer = nil
        isAnswering = false
    }

    /// Asks the Mac to close the dialog a screen-only command drew. The Mac sends the Escape and
    /// says whether it took.
    func dismissScreen(tabID: String) {
        isDismissingScreen = true
        client.dismissAgentScreen(tabID: tabID)
    }

    /// Forgets the Mac's tree. For leaving a Mac, not for losing it: a dropped connection keeps the
    /// tree so the screen stays where the user left it while the device reconnects.
    func clearTree() {
        tree = nil
        followOwner = nil
        followedTabID = nil
        conversation = nil
        isLoadingConversation = false
        promptOptions = []
        clearAnswering()
        screen = nil
        isDismissingScreen = false
    }

    func dismissRefusal() {
        refusalTimer?.cancel()
        refusalTimer = nil
        refusal = nil
    }

    /// Shows a refusal for a few seconds, whichever side refused.
    private func show(_ error: RemoteError) {
        refusal = error
        refusalTimer?.cancel()
        refusalTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.refusal = nil
        }
    }
}

extension RemoteSessionStore: RemoteClientDelegate {
    func remoteClient(_ client: RemoteClient, didReceive tree: RemoteTree) {
        self.tree = tree
    }

    func remoteClient(_ client: RemoteClient, didAttach attached: RemoteAttached) {
        attachRefusal = nil
        onAttach?(attached)
    }

    func remoteClient(_ client: RemoteClient, didReceiveOutput bytes: [UInt8], for session: UUID) {
        onOutput?(bytes, session)
    }

    func remoteClient(_ client: RemoteClient, shouldResync session: UUID) {
        onResync?(session)
    }

    func remoteClient(_ client: RemoteClient, didReceive activity: RemoteAgentActivity) {
        // Decided against the tree as it stood, so the tab's previous state can tell a change from
        // the Mac repeating one.
        if let notifier {
            let policy = RemoteAgentNotificationPolicy(
                isEnabled: notifier.isEnabled,
                isApplicationActive: isApplicationActive(),
                visibleTabID: visibleTabID
            )
            notifier.apply(policy.action(for: activity, in: tree))
        }
        tree = tree?.applyingAttention(from: activity)
    }

    func remoteClient(_ client: RemoteClient, didReceive notifications: RemoteNotifications) {
        self.notifications.merge(notifications)
    }

    func remoteClient(_ client: RemoteClient, didReceive conversation: RemoteAgentConversation) {
        self.conversation = conversation
        isLoadingConversation = false
    }

    func remoteClient(_ client: RemoteClient, didReceive entries: RemoteAgentEntries) {
        // A late batch for a tab the user has left is not this screen's, and applying it would show
        // one conversation's entries under another's name.
        guard var current = conversation, current.tabID == entries.tabID else { return }
        var seen = Set(current.entries.map(\.id))
        for entry in entries.entries where !seen.contains(entry.id) {
            seen.insert(entry.id)
            current.entries.append(entry)
        }
        conversation = current
    }

    func remoteClient(_ client: RemoteClient, didReceive prompt: RemoteAgentPrompt) {
        guard conversation?.tabID == prompt.tabID else { return }
        promptOptions = prompt.options
        clearAnswering()
    }

    /// What a screen-only command drew, put into the conversation as that command's row.
    ///
    /// The row is the device's own: the agent never wrote it, so it is not in the record the Mac
    /// relays, and it is added here rather than by the host. Once, by the capture's id, because
    /// the Mac reports the same dialog again after every dismissal.
    func remoteClient(_ client: RemoteClient, didReceive screen: RemoteAgentScreen) {
        guard var current = conversation, current.tabID == screen.tabID else { return }
        let id = "screen-\(screen.id)"
        if !screen.command.output.isEmpty, !current.entries.contains(where: { $0.id == id }) {
            current.entries.append(RemoteAgentEntry(
                id: id,
                role: .system,
                timestamp: Date(),
                blocks: [.localCommand(screen.command)]
            ))
            conversation = current
        }
        self.screen = screen.isShowing ? screen : nil
        isDismissingScreen = false
    }

    func remoteClient(_ client: RemoteClient, didRefuse error: RemoteError) {
        // An attach that failed belongs to the screen that asked. Everything else is a passing
        // notice: the tree the Mac sends next already shows what did and did not change.
        if error.code == "attach", attachmentOwner != nil {
            attachRefusal = error.message
            return
        }
        if error.code == "agentAnswer" || error.code == "agentReply" || error.code == "denied" {
            // The banner says what happened. Freeing the buttons matters as much: a refused answer
            // that left them disabled would look like the Mac had stopped listening. "denied" is
            // the Mac turning typing off between the prompt and the tap, and the buttons come
            // back with typing, so they must not come back dead.
            clearAnswering()
        }
        if error.code == "dismissAgentScreen" || error.code == "denied" {
            isDismissingScreen = false
        }
        if error.code == "attachAgent" {
            // The tab has no conversation to show. The screen falls back to the terminal rather
            // than saying so: there is nothing the person can do about it.
            isLoadingConversation = false
            return
        }
        show(error)
    }
}

extension View {
    /// Tells the store which tab this screen shows, for as long as it is showing.
    ///
    /// The clear is guarded, because a replacing screen may appear before the one it replaces
    /// disappears, and the departing screen must not erase its successor's answer.
    func showsTab(_ tabID: String, in store: RemoteSessionStore) -> some View {
        onAppear { store.visibleTabID = tabID }
            .onDisappear {
                if store.visibleTabID == tabID {
                    store.visibleTabID = nil
                }
            }
    }
}

private extension RemoteTree {
    /// Patches one tab's agent state in place. The host sends this instead of a full tree resend,
    /// so the device's cook tracks the Mac's without the user reopening the tab list.
    func applyingAttention(from activity: RemoteAgentActivity) -> RemoteTree {
        var tree = self
        for workspaceIndex in tree.workspaces.indices {
            for tabIndex in tree.workspaces[workspaceIndex].tabs.indices
            where tree.workspaces[workspaceIndex].tabs[tabIndex].id == activity.tabID {
                tree.workspaces[workspaceIndex].tabs[tabIndex].agentActivity = activity.activity
                tree.workspaces[workspaceIndex].tabs[tabIndex].needsAttention = activity.needsAttention
            }
        }
        return tree
    }
}
