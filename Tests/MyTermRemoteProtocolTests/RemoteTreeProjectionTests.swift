import Foundation
import XCTest
import MyTermCore
@testable import MyTermRemoteProtocol

final class RemoteTreeProjectionTests: XCTestCase {
    private func noAttention(_: TabID) -> AgentActivity? { nil }

    // MARK: - Flattening

    func testNestedSplitLayoutFlattensToTheMacsReadingOrder() {
        let tabA = Tab.terminal(customTitle: "A")
        let tabB = Tab.terminal(customTitle: "B")
        let tabC = Tab.terminal(customTitle: "C")
        let groupA = TabGroup(tab: tabA)
        let groupB = TabGroup(tab: tabB)
        let groupC = TabGroup(tab: tabC)
        let layout = WorkspaceLayout.split(
            orientation: .horizontal,
            children: [
                .group(groupA),
                .split(orientation: .vertical, children: [.group(groupB), .group(groupC)]),
            ]
        )
        let workspace = Workspace(title: "Split", layout: layout)

        let tree = RemoteTreeProjection.tree(
            revision: 1,
            folders: [],
            workspaces: [workspace],
            agentActivity: noAttention
        )

        XCTAssertEqual(tree.workspaces[0].tabs.map(\.title), ["A", "B", "C"])
    }

    func testSplitOrientationAndWeightsNeverAppearOnTheWire() throws {
        let workspace = Workspace(
            title: "Split",
            layout: .split(orientation: .horizontal, children: [.group(TabGroup(tab: .terminal())), .group(TabGroup(tab: .terminal()))])
        )

        let tree = RemoteTreeProjection.tree(revision: 1, folders: [], workspaces: [workspace], agentActivity: noAttention)
        let encoded = try JSONEncoder().encode(tree)
        let json = String(decoding: encoded, as: UTF8.self)

        XCTAssertFalse(json.contains("orientation"))
        XCTAssertFalse(json.contains("weight"))
    }

    // MARK: - Tab kinds

    func testTerminalTabProjectsWithKindAndSessionID() {
        let session = TerminalSession(workingDirectory: URL(fileURLWithPath: "/Users/someone/project"))
        let tab = Tab(content: .terminal(session))
        let workspace = Workspace(title: "W", tabs: [tab])

        let tree = RemoteTreeProjection.tree(revision: 1, folders: [], workspaces: [workspace], agentActivity: noAttention)
        let remoteTab = tree.workspaces[0].tabs[0]

        XCTAssertEqual(remoteTab.kind, .terminal)
        XCTAssertEqual(remoteTab.title, "Terminal")
        XCTAssertEqual(remoteTab.terminalSessionID, session.id.rawValue)
        XCTAssertNil(remoteTab.url)
    }

    func testBrowserTabProjectsWithKindAndURLAndNoSessionID() {
        let url = URL(string: "https://example.com/path")!
        let session = BrowserSession(url: url)
        let tab = Tab(content: .browser(session))
        let workspace = Workspace(title: "W", tabs: [tab])

        let tree = RemoteTreeProjection.tree(revision: 1, folders: [], workspaces: [workspace], agentActivity: noAttention)
        let remoteTab = tree.workspaces[0].tabs[0]

        XCTAssertEqual(remoteTab.kind, .browser)
        XCTAssertEqual(remoteTab.title, "example.com")
        XCTAssertEqual(remoteTab.url, url.absoluteString)
        XCTAssertNil(remoteTab.terminalSessionID)
    }

    // MARK: - Subtitle

    func testSubtitleIsOnlyTheLastPathComponent() {
        let session = TerminalSession(workingDirectory: URL(fileURLWithPath: "/Users/someone/secret-project/src"))
        let tab = Tab(content: .terminal(session))
        let workspace = Workspace(title: "W", tabs: [tab])

        let tree = RemoteTreeProjection.tree(revision: 1, folders: [], workspaces: [workspace], agentActivity: noAttention)

        XCTAssertEqual(tree.workspaces[0].tabs[0].subtitle, "src")
    }

    func testSubtitleIsNilWhenThereIsNoWorkingDirectory() {
        let tab = Tab.terminal()
        let workspace = Workspace(title: "W", tabs: [tab])

        let tree = RemoteTreeProjection.tree(revision: 1, folders: [], workspaces: [workspace], agentActivity: noAttention)

        XCTAssertNil(tree.workspaces[0].tabs[0].subtitle)
    }

    // MARK: - needsAttention

    func testNeedsAttentionPropagatesToTheTabAndTheWorkspace() {
        let tab = Tab.terminal()
        let workspace = Workspace(title: "W", tabs: [tab])

        let tree = RemoteTreeProjection.tree(
            revision: 1,
            folders: [],
            workspaces: [workspace],
            agentActivity: { $0 == tab.id ? .awaitingInput : nil }
        )

        XCTAssertTrue(tree.workspaces[0].tabs[0].needsAttention)
        XCTAssertTrue(tree.workspaces[0].needsAttention)
        XCTAssertEqual(tree.workspaces[0].tabs[0].agentActivity, .awaitingInput)
        XCTAssertEqual(tree.workspaces[0].agentActivity, .awaitingInput)
    }

    func testNeedsAttentionIsFalseWhenNoTabMatches() {
        let workspace = Workspace(title: "W", tabs: [.terminal()])

        let tree = RemoteTreeProjection.tree(revision: 1, folders: [], workspaces: [workspace], agentActivity: noAttention)

        XCTAssertFalse(tree.workspaces[0].tabs[0].needsAttention)
        XCTAssertFalse(tree.workspaces[0].needsAttention)
    }

    // MARK: - Colors, pins, emoji, folder membership

    func testFolderAndWorkspaceColorsPinsEmojiAndFolderMembershipProjectCorrectly() {
        let folder = WorkspaceFolder(title: "Folder", color: .purple)
        let workspace = Workspace(
            title: "W",
            emoji: "🚀",
            color: .teal,
            tabs: [.terminal()],
            folderID: folder.id,
            isPinned: true
        )

        let tree = RemoteTreeProjection.tree(revision: 1, folders: [folder], workspaces: [workspace], agentActivity: noAttention)

        XCTAssertEqual(tree.folders[0].id, folder.id.description)
        XCTAssertEqual(tree.folders[0].title, "Folder")
        XCTAssertEqual(tree.folders[0].colorName, "purple")

        let remoteWorkspace = tree.workspaces[0]
        XCTAssertEqual(remoteWorkspace.id, workspace.id.description)
        XCTAssertEqual(remoteWorkspace.emoji, "🚀")
        XCTAssertEqual(remoteWorkspace.colorName, "teal")
        XCTAssertEqual(remoteWorkspace.folderID, folder.id.description)
        XCTAssertTrue(remoteWorkspace.isPinned)
    }

    func testWorkspaceWithNoColorFolderOrEmojiProjectsNilFields() {
        let workspace = Workspace(title: "W", tabs: [.terminal()])

        let tree = RemoteTreeProjection.tree(revision: 1, folders: [], workspaces: [workspace], agentActivity: noAttention)
        let remoteWorkspace = tree.workspaces[0]

        XCTAssertNil(remoteWorkspace.emoji)
        XCTAssertNil(remoteWorkspace.colorName)
        XCTAssertNil(remoteWorkspace.folderID)
        XCTAssertFalse(remoteWorkspace.isPinned)
    }

    // MARK: - Security: no sensitive data ever reaches the wire

    func testEncodedTreeNeverContainsAnAbsoluteFilesystemPath() throws {
        // Only the last path component ("src") is meant to reach the wire as `subtitle`; the
        // secret parent directory and the recent terminal output must not.
        let secretDirectory = URL(fileURLWithPath: "/Users/someone/secret-project/src")
        let session = TerminalSession(
            workingDirectory: secretDirectory,
            recentText: "cat /Users/someone/secret-project/credentials.txt"
        )
        let tab = Tab(content: .terminal(session), customTitle: "Secret Work")
        let workspace = Workspace(title: "Secret", tabs: [tab])

        let tree = RemoteTreeProjection.tree(revision: 1, folders: [], workspaces: [workspace], agentActivity: noAttention)
        let encoded = try JSONEncoder().encode(tree)
        let json = String(decoding: encoded, as: UTF8.self)

        XCTAssertFalse(json.contains("/Users/someone"))
        XCTAssertFalse(json.contains("secret-project"))
        XCTAssertFalse(json.contains("credentials"))
    }
}
