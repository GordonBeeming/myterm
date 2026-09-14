import Foundation
import MyTermRemoteProtocol

/// Types replies into an agent one at a time, per tab.
///
/// A reply is its words and then, once they have settled as a paste, a Return of its own. Two
/// devices replying to the same tab inside that gap would have their words land as one line and
/// the second Return submit nothing. So the service owns one of these and every connection puts
/// its replies through it: a reply to a tab waits until the reply before it has been submitted.
@MainActor
public final class AgentReplyQueue {
    /// How long a reply's Return waits behind its words.
    ///
    /// An agent's input treats bytes that land together as one paste, and a Return inside a paste
    /// becomes a line break in the draft. Only a Return that arrives on its own, once the paste has
    /// settled, submits the line.
    public static let returnDelay: Duration = .milliseconds(200)
    static let returnKeystroke = Array("\r".utf8)

    /// What became of a reply once its turn came.
    enum Outcome {
        /// The words and the Return went in. `screenBefore` is the screen as it stood before the
        /// Return, read only for a command whose answer is drawn rather than written.
        case submitted(screenBefore: [String]?)
        /// Nothing was typed, for the reason given.
        case refused(RemoteError)
        /// The words went in, but the Mac stopped taking input before the Return could follow.
        /// They sit in the draft where the person at the Mac can see them.
        case leftInDraft
    }

    struct Reply {
        let text: String
        /// Read when the reply's turn comes and again before the Return, so a Mac that says no
        /// while a reply is waiting stops it.
        let allowsInput: () -> Bool
        /// Held, not the connection: a device that drops the instant it sends must still get its
        /// words submitted rather than left sitting in the draft.
        let dataSource: any RemoteHostDataSource
        /// Whether the screen is read before the Return, for a command that draws its answer.
        let readsScreen: Bool
        let completion: @MainActor (Outcome) -> Void
    }

    private var waiting: [String: [Reply]] = [:]
    private var typing: Set<String> = []

    public init() {}

    func enqueue(tabID: String, _ reply: Reply) {
        waiting[tabID, default: []].append(reply)
        pump(tabID: tabID)
    }

    private func pump(tabID: String) {
        guard !typing.contains(tabID), var queue = waiting[tabID], !queue.isEmpty else { return }
        let reply = queue.removeFirst()
        waiting[tabID] = queue.isEmpty ? nil : queue

        // Checked when the turn comes, not when the reply arrived: the answer can change while
        // a reply waits behind another, and the tab can close.
        guard reply.allowsInput() else {
            reply.completion(.refused(RemoteError(code: "denied", message: "is not taking input from devices")))
            pump(tabID: tabID)
            return
        }
        guard reply.dataSource.sendInput(tabID: tabID, bytes: Array(reply.text.utf8)[...]) else {
            reply.completion(.refused(RemoteError(code: "agentReply", message: "has no terminal for that tab")))
            pump(tabID: tabID)
            return
        }

        typing.insert(tabID)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.returnDelay)
            defer {
                self?.typing.remove(tabID)
                self?.pump(tabID: tabID)
            }
            // The Mac may have said no in the meantime. The words are in the draft where the
            // person at the Mac can see them; submitting them is the part that was refused.
            guard reply.allowsInput() else {
                reply.completion(.leftInDraft)
                return
            }
            // The screen the Return goes into, read first: a capture must see it move on.
            let before = reply.readsScreen ? reply.dataSource.visibleRows(tabID: tabID) : nil
            guard reply.dataSource.sendInput(tabID: tabID, bytes: Self.returnKeystroke[...]) else {
                reply.completion(.refused(RemoteError(code: "agentReply", message: "has no terminal for that tab")))
                return
            }
            reply.completion(.submitted(screenBefore: before))
        }
    }
}
