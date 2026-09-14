import Foundation
import XCTest
@testable import MyTermRemoteProtocol

final class RemoteProtocolTests: XCTestCase {
    // MARK: - RemoteFrameCodec / RemoteFrameDecoder

    func testEncodeThenDecodeRoundTripsEveryFrameKind() throws {
        for kind in RemoteFrameKind.allCases {
            let frame = RemoteFrame(kind: kind, payload: [1, 2, 3, 4, 5])
            var decoder = RemoteFrameDecoder()
            decoder.append(RemoteFrameCodec.encode(frame))

            let decoded = try decoder.nextFrame()

            XCTAssertEqual(decoded, frame)
        }
    }

    func testDecoderReassemblesAFrameFedOneByteAtATime() throws {
        let frame = RemoteFrame(kind: .output, payload: Array("hello".utf8))
        let encoded = RemoteFrameCodec.encode(frame)
        var decoder = RemoteFrameDecoder()

        for (index, byte) in encoded.enumerated() {
            decoder.append([byte])
            let isLastByte = index == encoded.count - 1
            let decoded = try decoder.nextFrame()
            if isLastByte {
                XCTAssertEqual(decoded, frame)
            } else {
                XCTAssertNil(decoded)
            }
        }
    }

    func testDecoderReturnsSeveralFramesDeliveredInOneAppendInOrder() throws {
        let first = RemoteFrame(kind: .input, payload: [9])
        let second = RemoteFrame(kind: .output, payload: [1, 2])
        let third = RemoteFrame(kind: .control, payload: [])
        var decoder = RemoteFrameDecoder()
        decoder.append(RemoteFrameCodec.encode(first) + RemoteFrameCodec.encode(second) + RemoteFrameCodec.encode(third))

        XCTAssertEqual(try decoder.nextFrame(), first)
        XCTAssertEqual(try decoder.nextFrame(), second)
        XCTAssertEqual(try decoder.nextFrame(), third)
        XCTAssertNil(try decoder.nextFrame())
    }

    func testDecoderReassemblesAFrameSplitAcrossTwoChunks() throws {
        let frame = RemoteFrame(kind: .output, payload: Array(repeating: UInt8(7), count: 40))
        let encoded = RemoteFrameCodec.encode(frame)
        let splitPoint = 17
        var decoder = RemoteFrameDecoder()

        decoder.append(encoded[0..<splitPoint])
        XCTAssertNil(try decoder.nextFrame())

        decoder.append(encoded[splitPoint...])
        XCTAssertEqual(try decoder.nextFrame(), frame)
    }

    func testNextFrameReturnsNilRatherThanThrowingWhenBytesAreIncomplete() throws {
        var decoder = RemoteFrameDecoder()

        XCTAssertNil(try decoder.nextFrame())

        decoder.append([0, 0, 0])
        XCTAssertNil(try decoder.nextFrame())

        decoder.append([5, RemoteFrameKind.control.rawValue, 1, 2])
        XCTAssertNil(try decoder.nextFrame())
    }

    func testDeclaredLengthOfZeroThrowsEmptyFrame() throws {
        var decoder = RemoteFrameDecoder()
        decoder.append([0, 0, 0, 0])

        XCTAssertThrowsError(try decoder.nextFrame()) { error in
            XCTAssertEqual(error as? RemoteFrameError, .emptyFrame)
        }
    }

    func testDeclaredLengthAboveMaximumThrowsFrameTooLargeWithoutAllocatingIt() throws {
        let excessiveLength = RemoteFrameCodec.maximumFrameBytes + 1
        var decoder = RemoteFrameDecoder()
        decoder.append([
            UInt8(truncatingIfNeeded: excessiveLength >> 24),
            UInt8(truncatingIfNeeded: excessiveLength >> 16),
            UInt8(truncatingIfNeeded: excessiveLength >> 8),
            UInt8(truncatingIfNeeded: excessiveLength),
        ])

        XCTAssertThrowsError(try decoder.nextFrame()) { error in
            XCTAssertEqual(error as? RemoteFrameError, .frameTooLarge(excessiveLength))
        }
    }

    func testUnknownFrameKindByteThrowsUnknownKind() throws {
        var decoder = RemoteFrameDecoder()
        // Length 1, then a kind byte no RemoteFrameKind case claims.
        decoder.append([0, 0, 0, 1, 0xFF])

        XCTAssertThrowsError(try decoder.nextFrame()) { error in
            XCTAssertEqual(error as? RemoteFrameError, .unknownKind(0xFF))
        }
    }

    // MARK: - RemoteSessionPayload

    func testRemoteSessionPayloadRoundTripsUUIDAndBytes() throws {
        let session = UUID()
        let bytes: [UInt8] = [10, 20, 30, 40]

        let encoded = RemoteSessionPayload.encode(session: session, bytes: bytes)
        let decoded = try XCTUnwrap(RemoteSessionPayload.decode(encoded))

        XCTAssertEqual(decoded.session, session)
        XCTAssertEqual(decoded.bytes, bytes)
    }

    func testRemoteSessionPayloadRoundTripsAnEmptyByteArray() throws {
        let session = UUID()

        let encoded = RemoteSessionPayload.encode(session: session, bytes: [])
        let decoded = try XCTUnwrap(RemoteSessionPayload.decode(encoded))

        XCTAssertEqual(decoded.session, session)
        XCTAssertEqual(decoded.bytes, [])
    }

    func testRemoteSessionPayloadDecodeReturnsNilForAPayloadShorterThanSixteenBytes() {
        let tooShort = Array(repeating: UInt8(1), count: 15)

        XCTAssertNil(RemoteSessionPayload.decode(tooShort))
    }

    // MARK: - RemoteControlCodec / RemoteControlMessage

    func testRemoteControlCodecRoundTripsEveryMessageCase() throws {
        let session = UUID()
        let messages: [RemoteControlMessage] = [
            .hello(RemoteHello(deviceName: "iPhone", token: "shared-secret")),
            .welcome(RemoteWelcome(hostName: "Gordon's Mac", allowsInput: true)),
            .tree(sampleTree()),
            .attach(RemoteAttach(tabID: "tab-1")),
            .attached(RemoteAttached(tabID: "tab-1", session: session, columns: 80, rows: 24)),
            .detach(session: session),
            .resync(session: session),
            .agentActivity(RemoteAgentActivity(tabID: "tab-1", activity: .awaitingInput)),
            .notifications(sampleNotifications()),
            .notifications(RemoteNotifications(entries: [])),
            .error(RemoteError(code: "not_found", message: "No such tab.")),
        ]

        for message in messages {
            let frame = try RemoteControlCodec.encode(message)
            let decoded = try RemoteControlCodec.decode(frame)

            XCTAssertEqual(decoded, message)
            XCTAssertEqual(frame.kind, .control)
        }
    }

    /// The order is the one the user works through, and the wire must keep it: a device that
    /// sorted for itself would put two entries with the same second in whichever order it liked.
    func testNotificationsKeepTheirOrderAndDatesAcrossTheWire() throws {
        let sent = sampleNotifications()

        let decoded = try RemoteControlCodec.decode(RemoteControlCodec.encode(.notifications(sent)))

        guard case .notifications(let received) = decoded else {
            return XCTFail("the message changed kind on the way through")
        }
        XCTAssertEqual(received.entries.map(\.tabID), ["tab-2", "tab-1"])
        XCTAssertEqual(received.entries.map(\.date), sent.entries.map(\.date))
        XCTAssertEqual(received.entries.map(\.activity), [.awaitingInput, .finished])
    }

    /// A Mac from before the history kept only the unread backlog and never said so. Its entries
    /// still decode, and they decode as unread, which is what they were.
    func testANotificationWithoutAReadMarkDecodesAsUnread() throws {
        let json = """
        {"tabID":"tab-1","workspaceID":"ws-1","workspaceTitle":"api","tabTitle":"build","activity":"finished","date":900}
        """
        let decoded = try JSONDecoder().decode(RemoteNotification.self, from: Data(json.utf8))
        XCTAssertFalse(decoded.isRead)
        XCTAssertEqual(decoded.date, Date(timeIntervalSinceReferenceDate: 900))
    }

    func testTheReadMarkCrossesTheWire() throws {
        let sent = sampleNotifications()
        let decoded = try RemoteControlCodec.decode(RemoteControlCodec.encode(.notifications(sent)))
        guard case .notifications(let received) = decoded else {
            return XCTFail("the message changed kind on the way through")
        }
        XCTAssertEqual(received.entries.map(\.isRead), [false, true])
    }

    private func sampleNotifications() -> RemoteNotifications {
        RemoteNotifications(entries: [
            RemoteNotification(
                tabID: "tab-2",
                workspaceID: "ws-1",
                workspaceTitle: "api",
                tabTitle: "server",
                activity: .awaitingInput,
                date: Date(timeIntervalSinceReferenceDate: 1_000)
            ),
            RemoteNotification(
                tabID: "tab-1",
                workspaceID: "ws-1",
                workspaceTitle: "api",
                tabTitle: "build",
                activity: .finished,
                date: Date(timeIntervalSinceReferenceDate: 900),
                isRead: true
            ),
        ])
    }

    // MARK: - RemoteAgentActivity.needsAttention

    func testRemoteAgentActivityNeedsAttentionIsDerivedFromTheActivity() {
        XCTAssertFalse(RemoteAgentActivity(tabID: "tab-1", activity: nil).needsAttention)
        XCTAssertFalse(RemoteAgentActivity(tabID: "tab-1", activity: .working).needsAttention)
        XCTAssertTrue(RemoteAgentActivity(tabID: "tab-1", activity: .finished).needsAttention)
        XCTAssertTrue(RemoteAgentActivity(tabID: "tab-1", activity: .awaitingInput).needsAttention)
    }

    // MARK: - RemoteTab.agentActivity / needsAttention

    func testRemoteTabDerivesNeedsAttentionFromAgentActivityWhenNotGivenExplicitly() {
        let workingTab = RemoteTab(id: "tab-1", kind: .terminal, title: "Shell", agentActivity: .working)
        let finishedTab = RemoteTab(id: "tab-2", kind: .terminal, title: "Shell", agentActivity: .finished)
        let quietTab = RemoteTab(id: "tab-3", kind: .terminal, title: "Shell")

        XCTAssertFalse(workingTab.needsAttention)
        XCTAssertTrue(finishedTab.needsAttention)
        XCTAssertFalse(quietTab.needsAttention)
    }

    // MARK: - RemoteWorkspace.agentActivity

    func testRemoteWorkspaceAgentActivityIsTheMostUrgentOfItsTabs() {
        let workspace = RemoteWorkspace(
            id: "workspace-1",
            title: "Development",
            tabs: [
                RemoteTab(id: "tab-1", kind: .terminal, title: "Shell", agentActivity: .working),
                RemoteTab(id: "tab-2", kind: .terminal, title: "Agent", agentActivity: .finished),
                RemoteTab(id: "tab-3", kind: .terminal, title: "Other", agentActivity: .awaitingInput),
            ]
        )

        XCTAssertEqual(workspace.agentActivity, .awaitingInput)
    }

    func testRemoteWorkspaceAgentActivityIsNilWhenNoTabHasOne() {
        let workspace = RemoteWorkspace(
            id: "workspace-1",
            title: "Development",
            tabs: [RemoteTab(id: "tab-1", kind: .terminal, title: "Shell")]
        )

        XCTAssertNil(workspace.agentActivity)
    }

    // MARK: - RemoteWorkspace.needsAttention

    func testWorkspaceNeedsAttentionIsTrueWhenAnyTabNeedsAttention() {
        let workspace = RemoteWorkspace(
            id: "workspace-1",
            title: "Development",
            tabs: [
                RemoteTab(id: "tab-1", kind: .terminal, title: "Shell", needsAttention: false),
                RemoteTab(id: "tab-2", kind: .terminal, title: "Agent", needsAttention: true),
            ]
        )

        XCTAssertTrue(workspace.needsAttention)
    }

    func testWorkspaceNeedsAttentionIsFalseWhenNoTabNeedsAttention() {
        let workspace = RemoteWorkspace(
            id: "workspace-1",
            title: "Development",
            tabs: [
                RemoteTab(id: "tab-1", kind: .terminal, title: "Shell", needsAttention: false),
                RemoteTab(id: "tab-2", kind: .browser, title: "Docs", url: "https://example.com", needsAttention: false),
            ]
        )

        XCTAssertFalse(workspace.needsAttention)
    }

    // MARK: - Fixtures

    private func sampleTree() -> RemoteTree {
        let folder = RemoteFolder(id: "folder-1", title: "Client Work", colorName: "blue")
        let terminalTab = RemoteTab(
            id: "tab-1",
            kind: .terminal,
            title: "Shell",
            subtitle: "myterm",
            needsAttention: false,
            terminalSessionID: UUID()
        )
        let browserTab = RemoteTab(
            id: "tab-2",
            kind: .browser,
            title: "Docs",
            url: "https://example.com/docs",
            needsAttention: true
        )
        let firstWorkspace = RemoteWorkspace(
            id: "workspace-1",
            title: "Development",
            emoji: "🟢",
            colorName: "green",
            folderID: folder.id,
            isPinned: true,
            tabs: [terminalTab, browserTab]
        )
        let secondWorkspace = RemoteWorkspace(
            id: "workspace-2",
            title: "Scratch",
            tabs: [
                RemoteTab(id: "tab-3", kind: .terminal, title: "Shell", needsAttention: false),
            ]
        )
        return RemoteTree(revision: 1, folders: [folder], workspaces: [firstWorkspace, secondWorkspace])
    }

    // MARK: - Mutation messages

    /// Each change is its own message. Round-tripping the whole set catches a case added to the enum
    /// without the hand-written `Codable` learning about it, which would otherwise fail only on the
    /// wire, on a device, against a Mac nobody is watching.
    func testEveryMutationMessageSurvivesTheWire() throws {
        let messages: [RemoteControlMessage] = [
            .renameTab(RemoteRenameTab(tabID: "tab-1", title: "build")),
            .renameTab(RemoteRenameTab(tabID: "tab-1", title: nil)),
            .closeTab(RemoteCloseTab(tabID: "tab-1")),
            .renameWorkspace(RemoteRenameWorkspace(workspaceID: "ws-1", title: "api")),
            .createWorkspace(RemoteCreateWorkspace(title: "scratch", folderID: "folder-1")),
            .createWorkspace(RemoteCreateWorkspace()),
            .deleteWorkspace(RemoteDeleteWorkspace(workspaceID: "ws-1")),
            .createTerminalTab(RemoteCreateTerminalTab(workspaceID: "ws-1")),
        ]

        for message in messages {
            let decoded = try RemoteControlCodec.decode(RemoteControlCodec.encode(message))
            XCTAssertEqual(decoded, message)
        }
    }

    /// A cleared name is not the same as the name "nil", and the difference decides whether a tab
    /// goes back to titling itself.
    func testClearingATabTitleCrossesTheWireAsAbsentRatherThanEmpty() throws {
        let message = RemoteControlMessage.renameTab(RemoteRenameTab(tabID: "tab-1", title: nil))

        let decoded = try RemoteControlCodec.decode(RemoteControlCodec.encode(message))

        guard case .renameTab(let request) = decoded else {
            return XCTFail("the message changed kind on the way through")
        }
        XCTAssertNil(request.title)
    }

    // MARK: - Agent conversations

    /// The block enum's `Codable` is hand-written, so a case added without teaching it fails only
    /// on the wire. Sending one of every kind through catches that here.
    func testEveryKindOfConversationBlockSurvivesTheWire() throws {
        let blocks: [RemoteAgentBlock] = [
            .text("hello"),
            .thinking("hmm"),
            .toolUse(RemoteAgentToolUse(id: "t1", name: "Bash", summary: "ls", detail: "command: ls", isPending: true)),
            .toolResult(RemoteAgentToolResult(toolUseID: "t1", isError: false, text: "a b", isTruncated: true)),
            .image,
            .localCommand(RemoteAgentLocalCommand(name: "/model", args: "opus", output: "Set model to Opus 5")),
            .localCommand(RemoteAgentLocalCommand(name: "", output: "no such command", isError: true)),
            .note(RemoteAgentNote(text: "Conversation compacted")),
            .note(RemoteAgentNote(text: "Switched to Opus 4.8.", level: .warning)),
        ]
        let message = RemoteControlMessage.agentConversation(RemoteAgentConversation(
            tabID: "tab-1",
            title: "fixing the build",
            agent: "claude",
            entries: [
                RemoteAgentEntry(id: "e1", role: .system, blocks: blocks),
                RemoteAgentEntry(id: "e2", role: .assistant, blocks: [.text("ok")], model: "claude-opus-5"),
                RemoteAgentEntry(id: "e3", role: .user, blocks: [.text("thanks")]),
            ]
        ))

        let decoded = try RemoteControlCodec.decode(RemoteControlCodec.encode(message))

        XCTAssertEqual(decoded, message)
    }

    /// A model is only ever an assistant turn's; an entry from before the field existed still reads.
    func testAnEntryWithoutAModelStillDecodes() throws {
        let json = #"{"id":"e1","role":"user","blocks":[{"type":"text","text":"hi"}]}"#
        let entry = try JSONDecoder().decode(RemoteAgentEntry.self, from: Data(json.utf8))
        XCTAssertNil(entry.model)
    }

    /// A command's output is prose unless it says it is a screen, and one that does not say so
    /// still reads.
    func testACommandThatDoesNotSayItIsAScreenIsNot() throws {
        let json = #"{"name":"/model","args":"opus","output":"Set model to Opus 5","isError":false}"#
        let command = try JSONDecoder().decode(RemoteAgentLocalCommand.self, from: Data(json.utf8))
        XCTAssertFalse(command.isScreen)
    }

    // MARK: - A command whose answer is on the screen

    func testAScreenAndItsDismissalSurviveTheWire() throws {
        let screen = RemoteAgentScreen(
            tabID: "tab-1",
            id: "capture-7",
            command: RemoteAgentLocalCommand(
                name: "/usage",
                output: "Settings  Status   Config   Usage   Stats\n\nSession\n\nTotal cost:  $0.0000",
                isScreen: true
            ),
            isShowing: true
        )
        for message in [
            RemoteControlMessage.agentScreen(screen),
            .agentScreen(RemoteAgentScreen(tabID: "tab-1", id: "capture-7", command: screen.command, isShowing: false)),
            .agentScreen(RemoteAgentScreen(
                tabID: "tab-1",
                id: "capture-8",
                command: RemoteAgentLocalCommand(name: "/help", isScreen: true),
                isShowing: false
            )),
            .dismissAgentScreen(RemoteDismissAgentScreen(tabID: "tab-1")),
        ] {
            let decoded = try RemoteControlCodec.decode(RemoteControlCodec.encode(message))
            XCTAssertEqual(decoded, message)
        }
    }

    /// The dismissal names a tab and nothing else: no keystroke and no session travels from a device.
    func testADismissalCarriesOnlyTheTab() throws {
        let frame = try RemoteControlCodec.encode(.dismissAgentScreen(RemoteDismissAgentScreen(tabID: "tab-1")))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(frame.payload)) as? [String: Any])
        let body = try XCTUnwrap(json["dismissAgentScreen"] as? [String: Any])

        XCTAssertEqual(json["type"] as? String, "dismissAgentScreen")
        XCTAssertEqual(body.keys.sorted(), ["tabID"])
        XCTAssertEqual(body["tabID"] as? String, "tab-1")
    }
}
