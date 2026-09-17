import MyTermCore
import MyTermRemote
@testable import SwiftTerm
import SwiftUI
import UIKit
import XCTest
@testable import MyTermCompanion

@MainActor
final class TerminalExperienceTests: XCTestCase {
    private func makeView(height: CGFloat = 220) -> TerminalView {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: height))
        view.automaticallyResizesTerminal = false
        view.acceptsUserInput = false
        view.sendsTerminalResponses = false
        view.usesIndependentViewport = true
        view.coalescesInteractiveOutput = true
        view.resize(cols: 100, rows: 40)
        view.layoutIfNeeded()
        addTeardownBlock { await MainActor.run { view.updateUiClosed() } }
        return view
    }

    private func fill(_ view: TerminalView, lines: Int = 100) {
        view.feed(text: (0..<lines).map { "line \($0)\r\n" }.joined())
    }

    private func assertAtBottom(_ view: TerminalView, file: StaticString = #filePath, line: UInt = #line) {
        let bottom = max(0, view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom)
        XCTAssertEqual(view.contentOffset.y, bottom, accuracy: 1, file: file, line: line)
    }

    func testViewOnlyPaneFollowsPhysicalBottomWithoutResizingHostGrid() {
        let view = makeView()
        fill(view)
        view.followOutput()
        assertAtBottom(view)
        fill(view, lines: 20)
        assertAtBottom(view)
        XCTAssertEqual(view.getTerminal().getDims().rows, 40)
        XCTAssertEqual(view.getTerminal().getDims().cols, 100)
        XCTAssertFalse(view.acceptsUserInput)
    }

    func testShortPromptIsVisibleInsteadOfFollowingUnusedHostRows() async throws {
        let view = makeView()
        view.feed(text: "$ ")
        view.followOutput()
        XCTAssertEqual(view.contentOffset.y, 0, accuracy: 1)
        fill(view)
        view.feed(text: "\u{1b}[2J\u{1b}[H$ ")
        try await Task.sleep(for: .milliseconds(60))
        let buffer = view.getTerminal().displayBuffer
        let cellHeight = view.contentSize.height / CGFloat(buffer.lines.count)
        let cursorY = CGFloat(buffer.yBase + buffer.y) * cellHeight
        XCTAssertLessThanOrEqual(view.contentOffset.y, cursorY)
        XCTAssertGreaterThan(view.contentOffset.y + view.bounds.height, cursorY)
        XCTAssertTrue(view.followsOutput)
    }

    func testRestoringFrozenHostCheckpointKeepsViewerFollowing() throws {
        let host = makeView()
        fill(host)
        host.scroll(toPosition: 0.2)
        let frozen = try host.getTerminal().exportCheckpoint()
        let viewer = makeView()
        let local = viewer.captureViewport()
        try viewer.getTerminal().importCheckpoint(frozen)
        viewer.restoreViewport(local)
        try viewer.invalidateAfterCheckpointImport()
        XCTAssertTrue(viewer.followsOutput)
        assertAtBottom(viewer)
        fill(viewer, lines: 10)
        assertAtBottom(viewer)
    }

    func testViewOnlyMouseModeDoesNotStealHistoryPanning() throws {
        let view = makeView()
        view.feed(text: "\u{1b}[?1000h")
        XCTAssertNil(view.panMouseGesture)
        XCTAssertTrue(view.panGestureRecognizer.isEnabled)
        view.acceptsUserInput = true
        XCTAssertNotNil(view.panMouseGesture)
        view.acceptsUserInput = false
        XCTAssertNil(view.panMouseGesture)
        let checkpoint = try view.getTerminal().exportCheckpoint()
        let spectator = makeView()
        try spectator.getTerminal().importCheckpoint(checkpoint)
        try spectator.invalidateAfterCheckpointImport()
        XCTAssertNil(spectator.panMouseGesture)
        XCTAssertTrue(spectator.panGestureRecognizer.isEnabled)
    }

    func testAccessibilityPagingPausesFollowingAndResumesAtLiveOutput() {
        let view = makeView()
        view.contentInset.bottom = 20
        fill(view)
        view.followOutput()
        var captured: TerminalViewportState?
        view.onViewportChanged = { [weak view] in captured = view?.captureViewport() }
        XCTAssertTrue(view.accessibilityScroll(.up))
        XCTAssertFalse(view.followsOutput)
        XCTAssertEqual(captured?.followsOutput, false)
        let offset = view.contentOffset.y
        fill(view, lines: 20)
        XCTAssertEqual(view.contentOffset.y, offset, accuracy: 1)
        for _ in 0..<50 where !view.followsOutput {
            XCTAssertTrue(view.accessibilityScroll(.down))
        }
        XCTAssertTrue(view.followsOutput)
        assertAtBottom(view)
        fill(view, lines: 5)
        assertAtBottom(view)
    }

    func testAccessibilityPagingStopsAtSparsePromptInsteadOfBlankHostRows() {
        let view = makeView()
        fill(view)
        view.feed(text: "\u{1b}[2J\u{1b}[H$ ")
        view.followOutput()
        let liveOffset = view.contentOffset.y
        XCTAssertLessThan(liveOffset, view.contentSize.height - view.bounds.height)
        XCTAssertTrue(view.accessibilityScroll(.up))
        XCTAssertFalse(view.followsOutput)
        for _ in 0..<50 where !view.followsOutput {
            XCTAssertTrue(view.accessibilityScroll(.down))
        }
        XCTAssertTrue(view.followsOutput)
        XCTAssertEqual(view.contentOffset.y, liveOffset, accuracy: 1)
    }

    func testHistoryPositionSurvivesOutputAndCheckpointRestoreUntilJumpToLive() throws {
        let view = makeView()
        fill(view)
        view.scroll(toPosition: 0.3)
        let offset = view.contentOffset.y
        XCTAssertFalse(view.followsOutput)
        fill(view, lines: 10)
        XCTAssertEqual(view.contentOffset.y, offset, accuracy: 1)
        let local = view.captureViewport()
        let host = makeView()
        fill(host, lines: 110)
        try view.getTerminal().importCheckpoint(host.getTerminal().exportCheckpoint())
        view.restoreViewport(local)
        try view.invalidateAfterCheckpointImport()
        XCTAssertFalse(view.followsOutput)
        XCTAssertEqual(view.contentOffset.y, offset, accuracy: 1)
        view.followOutput()
        XCTAssertTrue(view.followsOutput)
        assertAtBottom(view)
    }

    func testKeyboardAndRotationKeepFollowAtBottomAndHistoryStationary() {
        let view = makeView()
        fill(view)
        view.followOutput()
        view.frame.size.height = 130
        view.layoutIfNeeded()
        assertAtBottom(view)
        view.contentInset.bottom = 30
        view.layoutIfNeeded()
        assertAtBottom(view)
        view.scroll(toPosition: 0.2)
        let offset = view.contentOffset.y
        view.frame.size = CGSize(width: 500, height: 160)
        view.layoutIfNeeded()
        XCTAssertEqual(view.contentOffset.y, offset, accuracy: 1)
        XCTAssertFalse(view.followsOutput)
    }

    func testCheckpointTrimKeepsRetainedTextAndClampsEvictedHistory() throws {
        let host = makeView()
        host.getTerminal().changeScrollback(80)
        fill(host, lines: 120)
        let viewer = makeView()
        try viewer.getTerminal().importCheckpoint(host.getTerminal().exportCheckpoint())
        viewer.followOutput()
        viewer.scroll(toPosition: 0.7)
        let local = viewer.captureViewport()
        let buffer = viewer.getTerminal().displayBuffer
        let row = local.absoluteRow - buffer.linesTop
        let text = buffer.lines[row].translateToString(trimRight: true)
        fill(host, lines: 5)
        try viewer.getTerminal().importCheckpoint(host.getTerminal().exportCheckpoint())
        viewer.restoreViewport(local)
        let restored = viewer.captureViewport()
        let updated = viewer.getTerminal().displayBuffer
        XCTAssertEqual(updated.lines[restored.absoluteRow - updated.linesTop].translateToString(trimRight: true), text)
        XCTAssertFalse(viewer.followsOutput)
        fill(host, lines: 200)
        try viewer.getTerminal().importCheckpoint(host.getTerminal().exportCheckpoint())
        viewer.restoreViewport(local)
        XCTAssertEqual(viewer.contentOffset.y, 0, accuracy: 1)
        XCTAssertFalse(viewer.followsOutput)
    }

    private func viewportCoordinator(_ state: TerminalSurfaceState) -> RemoteTerminalView.Coordinator {
        let parent = RemoteTerminalView(state: state, showTerminalKeys: false,
            onInput: { _ in }, onPasteImage: { _ in }, onResize: { _, _ in }, onResync: { _ in })
        let coordinator = parent.makeCoordinator()
        coordinator.checkpointRevision = 0
        coordinator.followOutputRevision = state.followOutputRevision
        return coordinator
    }

    private func viewportState() -> TerminalSurfaceState {
        TerminalSurfaceState(route: TerminalRoute(
            connectionID: SavedConnectionID(relayOrigin: "https://relay.example.com", accountID: UUID(), hostID: UUID()),
            workspaceID: UUID(), groupID: UUID(), tabID: UUID(), sessionID: UUID(), title: "Terminal"))
    }

    func testImmediateDismantleSavesFrozenIntentAndCancelsDeferredUpdates() async {
        let state = viewportState()
        let coordinator = viewportCoordinator(state)
        let view = makeView()
        fill(view)
        view.scroll(toPosition: 0.3)
        coordinator.synchronizeViewport(from: view)
        XCTAssertTrue(state.isFollowingOutput, "The deferred publication has not run yet")
        RemoteTerminalView.dismantleUIView(view, coordinator: coordinator)
        XCTAssertFalse(state.isFollowingOutput)
        XCTAssertEqual(state.viewport?.followsOutput, false)
        state.resumeFollowingOutput()
        await Task.yield()
        XCTAssertTrue(state.isFollowingOutput, "An obsolete view must not overwrite the new viewer's intent")
    }

    func testDismantleHonoursJumpToLiveBeforeNextRepresentableUpdate() {
        let state = viewportState()
        let coordinator = viewportCoordinator(state)
        let view = makeView()
        fill(view)
        view.scroll(toPosition: 0.3)
        state.resumeFollowingOutput()
        RemoteTerminalView.dismantleUIView(view, coordinator: coordinator)
        XCTAssertTrue(state.isFollowingOutput)
        XCTAssertEqual(state.viewport?.followsOutput, true)
    }

    func testRemoteEchoBurstIsRenderedTogetherWhileTyping() async throws {
        let view = makeView()
        let observer = DisplayObserver()
        view.terminalDelegate = observer
        view.notifyUpdateChanges = true
        fill(view)
        view.followOutput()
        try await Task.sleep(for: .milliseconds(60))
        observer.draws = 0
        view.acceptsUserInput = true
        view.send(txt: "a")
        for _ in 0..<30 { view.feed(text: "a") }
        XCTAssertEqual(observer.draws, 0, "Receiving each echo chunk must not immediately redraw the terminal")
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertGreaterThan(observer.draws, 0)
        XCTAssertLessThan(observer.draws, 5, "A burst should coalesce into a frame rather than 30 redraws")
        XCTAssertTrue(String(decoding: view.getTerminal().getBufferAsData(), as: UTF8.self)
            .contains(String(repeating: "a", count: 30)), "Coalescing must preserve every received byte")
    }

    func testComposerMakesOneUnicodePasteWithOptionalReturnOutsideDelimiters() throws {
        let text = "Hello 👩🏽‍💻\r\nsecond line\rthird"
        XCTAssertEqual(try TerminalComposerDraft.pasteBytes(text, bracketed: true, appendReturn: false),
            Data("\u{1b}[200~Hello 👩🏽‍💻\nsecond line\nthird\u{1b}[201~".utf8))
        XCTAssertEqual(try TerminalComposerDraft.pasteBytes("echo hi", bracketed: true, appendReturn: true),
            Data("\u{1b}[200~echo hi\u{1b}[201~\r".utf8))
        XCTAssertEqual(try TerminalComposerDraft.pasteBytes("echo hi", bracketed: false, appendReturn: false),
            Data("echo hi".utf8))
    }

    func testComposerRejectsOversizedAndEmbeddedTerminalControls() {
        for text in ["", "text\u{1b}[201~", "text\u{0}", "text\u{9b}201~", "text\u{9d}52;",
                     String(repeating: "🙂", count: 20_000)] {
            XCTAssertThrowsError(try TerminalComposerDraft.pasteBytes(text, bracketed: true, appendReturn: true))
        }
    }

    func testComposerLayout() async throws {
        let scene = SceneModel()
        let connection = SavedConnectionID(relayOrigin: "https://relay.example.com", accountID: UUID(), hostID: UUID())
        let route = TerminalRoute(connectionID: connection, workspaceID: UUID(), groupID: UUID(), tabID: UUID(),
                                  sessionID: UUID(), title: "Build pipeline")
        let state = TerminalSurfaceState(route: route)
        let bytes = try makeView().getTerminal().exportCheckpoint()
        let checkpoint = try await CheckpointAssembler().ingest(
            metadata: MessageMetadata(hostID: route.hostID, runtimeID: UUID(), sessionID: route.sessionID),
            chunk: CheckpointChunkParameters(transferID: UUID(), generation: UUID(), sequence: 0,
                chunkIndex: 0, chunkCount: 1, totalBytes: bytes.count, bytes: bytes))
        state.apply(checkpoint: try XCTUnwrap(checkpoint))
        scene.terminalStates[route.id] = state
        let draft = scene.composerDraft(for: route)
        draft.text = "Explain the failing build, then suggest the smallest fix.\n\nKeep the public API unchanged."
        let controller = UIHostingController(rootView: TerminalComposerView(scene: scene, route: route, draft: draft))
        let originalWindow = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; originalWindow?.makeKey() }
        try await Task.sleep(for: .milliseconds(500))
        controller.view.layoutIfNeeded()
        let screenshot = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: screenshot)
        attachment.name = "terminal-composer-view-only"
        attachment.lifetime = .keepAlways
        add(attachment)
        let path = FileManager.default.temporaryDirectory.appending(path: "terminal-composer-view-only.png")
        try XCTUnwrap(screenshot.pngData()).write(to: path)
        print("Composer snapshot: \(path.path)")
        XCTAssertEqual(draft.text, scene.composerDraft(for: route).text)
    }

    func testDraftsBelongToTerminalAndSurviveControlLossAndDismissal() async throws {
        let scene = SceneModel()
        let connection = SavedConnectionID(relayOrigin: "https://relay.example.com", accountID: UUID(), hostID: UUID())
        let route = TerminalRoute(connectionID: connection, workspaceID: UUID(), groupID: UUID(), tabID: UUID(),
                                  sessionID: UUID(), title: "One")
        let second = TerminalRoute(connectionID: connection, workspaceID: route.workspaceID, groupID: route.groupID,
                                   tabID: UUID(), sessionID: UUID(), title: "Two")
        let draft = scene.composerDraft(for: route)
        draft.text = "keep my draft"
        scene.sheet = .terminalComposer(route)
        scene.sheet = nil
        XCTAssertTrue(scene.composerDraft(for: route) === draft)
        XCTAssertEqual(scene.composerDraft(for: second).text, "")
        do {
            try await scene.insertComposedText(draft.text, appendReturn: true, route: route)
            XCTFail("A view-only or disconnected terminal must not accept a draft")
        } catch is TerminalComposerError {}
        XCTAssertEqual(draft.text, "keep my draft")
    }
}

private final class DisplayObserver: TerminalViewDelegate {
    var draws = 0
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) { draws += 1 }
}
