import AppKit
import XCTest
@testable import MyTermPlatform

final class TerminalSessionConfigurationTests: XCTestCase {
    @MainActor
    func testForegroundProcessDetectionIgnoresIdleShellAndFindsActiveJob() async throws {
        let session = try SwiftTermTerminalSession(
            configuration: TerminalSessionConfiguration(
                workingDirectory: FileManager.default.temporaryDirectory,
                initialCommand: "sleep 5"
            )
        )
        defer { session.terminate() }

        try session.start()
        var activeProcessName: String?
        for _ in 0..<100 {
            activeProcessName = session.activeForegroundProcessName
            if activeProcessName == "sleep" { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(activeProcessName, "sleep")
    }

    func testRuntimeConfigurationClampsInvalidFontAndScrollbackValues() {
        let configuration = TerminalRuntimeConfiguration(fontSize: 0, scrollbackLines: -1)

        XCTAssertEqual(configuration.fontSize, 1)
        XCTAssertEqual(configuration.scrollbackLines, 0)
    }

    func testConfigurationCarriesRuntimeAndRestoredOutputSettings() {
        let runtime = TerminalRuntimeConfiguration(
            fontName: "An Installed Font Is Not Required",
            fontSize: 15,
            appearance: TerminalAppearance(
                foreground: TerminalColor(red: 1, green: 2, blue: 3),
                background: TerminalColor(red: 4, green: 5, blue: 6),
                cursor: TerminalCursorConfiguration(shape: .bar, blinks: false)
            ),
            scrollbackLines: 800,
            optionAsMeta: false
        )
        let configuration = TerminalSessionConfiguration(
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            runtimeConfiguration: runtime,
            restoredOutput: "previous output"
        )

        XCTAssertEqual(configuration.runtimeConfiguration, runtime)
        XCTAssertEqual(configuration.restoredOutput, "previous output")
    }

    @MainActor
    func testRuntimeConfigurationAppliesFontAppearanceCursorScrollbackAndOptionMeta() {
        let view = MyTermLocalProcessTerminalView(frame: .zero)
        view.apply(
            runtimeConfiguration: TerminalRuntimeConfiguration(
                fontName: "Missing Test Font",
                fontSize: 17,
                appearance: TerminalAppearance(
                    foreground: TerminalColor(red: 1, green: 2, blue: 3),
                    background: TerminalColor(red: 4, green: 5, blue: 6),
                    cursor: TerminalCursorConfiguration(shape: .bar, blinks: false)
                ),
                scrollbackLines: 42,
                optionAsMeta: false
            )
        )

        XCTAssertEqual(view.font.pointSize, 17)
        XCTAssertFalse(view.optionAsMetaKey)
        XCTAssertEqual(view.getTerminal().options.scrollback, 42)
        XCTAssertEqual(view.getTerminal().foregroundColor.red, 1)
        XCTAssertEqual(view.getTerminal().backgroundColor.blue, 6)
        switch view.getTerminal().options.cursorStyle {
        case .steadyBar:
            break
        default:
            XCTFail("Expected the configured steady bar cursor.")
        }

        view.apply(runtimeConfiguration: TerminalRuntimeConfiguration())
        XCTAssertEqual(view.nativeForegroundColor, .textColor)
        XCTAssertEqual(view.nativeBackgroundColor, .textBackgroundColor)
    }

    @MainActor
    func testPersistedOutputIsRenderedBeforeProcessStartWithoutTerminalInput() {
        let view = MyTermLocalProcessTerminalView(frame: .zero)

        view.presentPersistedOutput("first\u{1B}[31m\nsecond", maximumCharacters: 20)

        XCTAssertTrue(view.renderedText(maximumCharacters: 200).contains("first\nsecond"))
    }

    @MainActor
    func testSelectedTerminalTextSurvivesLinefeedWithMouseReportingEnabled() {
        let view = MyTermLocalProcessTerminalView(frame: .zero)
        view.allowMouseReporting = true
        view.feed(text: "selected text")
        view.selectAll()

        view.dataReceived(slice: ArraySlice("\nnew output".utf8))

        XCTAssertTrue(view.allowMouseReporting)
        XCTAssertTrue(view.selectionActive)
        XCTAssertTrue(view.getSelection()?.contains("selected text") == true)
        XCTAssertTrue(view.renderedText(maximumCharacters: 200).contains("new output"))

        view.selectNone()
        XCTAssertFalse(view.selectionActive)
    }

    @MainActor
    func testSelectedTerminalTextPreservesDisabledMouseReporting() {
        let view = MyTermLocalProcessTerminalView(frame: .zero)
        view.allowMouseReporting = false
        view.feed(text: "selected text")
        view.selectAll()

        view.dataReceived(slice: ArraySlice("\nnew output".utf8))

        XCTAssertFalse(view.allowMouseReporting)
        XCTAssertTrue(view.selectionActive)
        XCTAssertTrue(view.getSelection()?.contains("selected text") == true)
        XCTAssertTrue(view.renderedText(maximumCharacters: 200).contains("new output"))
    }

    @MainActor
    func testRenderedTextReturnsOnlyTheRequestedTail() {
        let view = MyTermLocalProcessTerminalView(frame: .zero)
        view.feed(text: (1...100).map { "line \($0)" }.joined(separator: "\r\n"))

        let snapshot = view.renderedText(maximumCharacters: 24)

        XCTAssertLessThanOrEqual(snapshot.count, 24)
        XCTAssertTrue(snapshot.hasSuffix("line 99\nline 100\n"))
    }

    func testInputTranslatorMapsMyTermShortcutsInNonKittyMode() {
        let cases: [(TerminalInputEvent, [UInt8])] = [
            (.init(keyCode: 36, charactersIgnoringModifiers: "\r", modifiers: [.shift]), [0x0A]),
            (.init(keyCode: 76, charactersIgnoringModifiers: "\r", modifiers: [.shift, .numericPad]), [0x0A]),
            (.init(keyCode: 51, charactersIgnoringModifiers: "\u{7F}", modifiers: [.command]), [0x15]),
            (.init(keyCode: 123, charactersIgnoringModifiers: "", modifiers: [.command]), [0x01]),
            (.init(keyCode: 124, charactersIgnoringModifiers: "", modifiers: [.command]), [0x05]),
            (.init(keyCode: 126, charactersIgnoringModifiers: "", modifiers: [.command]), Array("\u{1B}[1;9A".utf8)),
            (.init(keyCode: 125, charactersIgnoringModifiers: "", modifiers: [.command, .capsLock]), Array("\u{1B}[1;9B".utf8)),
        ]

        for (event, expected) in cases {
            XCTAssertEqual(TerminalInputTranslator.sequence(for: event, kittyKeyboardEnabled: false), expected)
        }
    }

    func testInputTranslatorLeavesKittyAndUnownedKeysForSwiftTerm() {
        let commandLeft = TerminalInputEvent(keyCode: 123, charactersIgnoringModifiers: "", modifiers: [.command])
        let commandRight = TerminalInputEvent(keyCode: 124, charactersIgnoringModifiers: "", modifiers: [.command])
        let commandDelete = TerminalInputEvent(keyCode: 51, charactersIgnoringModifiers: "", modifiers: [.command])
        let plainReturn = TerminalInputEvent(keyCode: 36, charactersIgnoringModifiers: "\r", modifiers: [])
        let plainArrow = TerminalInputEvent(keyCode: 126, charactersIgnoringModifiers: "", modifiers: [])
        let unrelatedShortcut = TerminalInputEvent(keyCode: 8, charactersIgnoringModifiers: "c", modifiers: [.command])

        for kittyKeyboardEnabled in [false, true] {
            XCTAssertEqual(
                TerminalInputTranslator.sequence(for: commandLeft, kittyKeyboardEnabled: kittyKeyboardEnabled),
                [0x01]
            )
            XCTAssertEqual(
                TerminalInputTranslator.sequence(for: commandRight, kittyKeyboardEnabled: kittyKeyboardEnabled),
                [0x05]
            )
            XCTAssertEqual(
                TerminalInputTranslator.sequence(for: commandDelete, kittyKeyboardEnabled: kittyKeyboardEnabled),
                [0x15]
            )
        }
        XCTAssertNil(TerminalInputTranslator.sequence(for: plainReturn, kittyKeyboardEnabled: false))
        XCTAssertNil(TerminalInputTranslator.sequence(for: plainArrow, kittyKeyboardEnabled: false))
        XCTAssertNil(TerminalInputTranslator.sequence(for: unrelatedShortcut, kittyKeyboardEnabled: false))
    }

    func testCommandVOnlyBecomesControlVForImageClipboardContent() {
        let commandV = TerminalInputEvent(keyCode: 9, charactersIgnoringModifiers: "v", modifiers: [.command])

        XCTAssertEqual(
            TerminalInputTranslator.sequence(
                for: commandV,
                kittyKeyboardEnabled: true,
                clipboardContainsImage: true
            ),
            [0x16]
        )
        XCTAssertNil(
            TerminalInputTranslator.sequence(
                for: commandV,
                kittyKeyboardEnabled: false,
                clipboardContainsImage: false
            )
        )
    }

    func testTerminalPasteboardDistinguishesImagesFromText() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("myterm-image-paste-test"))
        pasteboard.clearContents()
        pasteboard.setString("plain text", forType: .string)
        XCTAssertFalse(TerminalPasteboard.containsImage(in: pasteboard))

        pasteboard.clearContents()
        let image = NSImage(size: NSSize(width: 2, height: 2))
        XCTAssertTrue(pasteboard.writeObjects([image]))
        XCTAssertTrue(TerminalPasteboard.containsImage(in: pasteboard))
    }

    @MainActor
    func testInactivePaneHidesAndRestoresItsCaret() {
        let terminal = MyTermLocalProcessTerminalView(frame: .zero)
        let activeColor = terminal.caretColor

        terminal.setPaneActive(false)
        XCTAssertEqual(terminal.caretColor, .clear)

        terminal.setPaneActive(true)
        XCTAssertEqual(terminal.caretColor, activeColor)
    }

    @MainActor
    func testTerminalAcceptsTheClickThatActivatesTheApp() {
        let terminal = MyTermLocalProcessTerminalView(frame: .zero)

        XCTAssertTrue(terminal.acceptsFirstMouse(for: nil))
    }

    @MainActor
    func testOnlyTheRealFirstResponderReportsItsTerminalPaneAsActive() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = container

        let terminals = (0..<3).map { _ in
            MyTermLocalProcessTerminalView(frame: .zero)
        }

        var focusedIndexes: [Int] = []
        let hosts = terminals.enumerated().map { index, terminal in
            let host = TerminalSessionHostView(
                contentView: terminal,
                onFocused: { focusedIndexes.append(index) }
            )
            host.frame = NSRect(x: CGFloat(index) * 120, y: 0, width: 120, height: 120)
            container.addSubview(host)
            return host
        }

        XCTAssertTrue(window.makeFirstResponder(terminals[2]))
        XCTAssertTrue(window.firstResponder === terminals[2])
        XCTAssertTrue(window.makeFirstResponder(terminals[1]))
        XCTAssertTrue(window.firstResponder === terminals[1])
        XCTAssertTrue(window.makeFirstResponder(terminals[0]))
        XCTAssertTrue(window.firstResponder === terminals[0])
        XCTAssertTrue(window.makeFirstResponder(terminals[2]))
        XCTAssertTrue(window.firstResponder === terminals[2])

        XCTAssertEqual(focusedIndexes, [2, 1, 0, 2])
        XCTAssertEqual(terminals.filter { window.firstResponder === $0 }.count, 1)
        XCTAssertEqual(hosts.count, 3)
    }

    func testRenderedOutputSanitizesControlsAndKeepsABoundedTail() {
        let output = TerminalOutputSnapshot.plainText(
            from: "first\u{1B}[31m\r\nsecond\u{0007}\tthird",
            maximumCharacters: 12
        )

        XCTAssertEqual(output, "second\tthird")
    }

    @MainActor
    func testContentChangeCoalescerEmitsOneNotificationForABurst() async {
        let coalescer = TerminalContentChangeCoalescer(delay: 0.01)
        let notification = expectation(description: "coalesced notification")
        notification.expectedFulfillmentCount = 1
        var count = 0

        coalescer.notify {
            count += 1
            notification.fulfill()
        }
        coalescer.notify {
            count += 1
            notification.fulfill()
        }

        await fulfillment(of: [notification], timeout: 1)
        XCTAssertEqual(count, 1)
    }

    func testConfigurationCarriesOneShotInitialCommand() {
        let configuration = TerminalSessionConfiguration(
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            initialCommand: "echo ready",
            environment: ["BROWSER": "/Applications/myterm.app/Contents/Resources/myterm-browser"]
        )

        XCTAssertEqual(configuration.initialCommand, "echo ready")
        XCTAssertEqual(
            configuration.environment["BROWSER"],
            "/Applications/myterm.app/Contents/Resources/myterm-browser"
        )
    }

    func testStandardizesWorkingDirectory() {
        let configuration = TerminalSessionConfiguration(
            shell: URL(fileURLWithPath: "/bin/zsh"),
            workingDirectory: URL(fileURLWithPath: "/tmp/../tmp")
        )

        XCTAssertEqual(configuration.workingDirectory.path, "/tmp")
    }

    func testNormalizesOSC7FileURL() {
        let workingDirectory = TerminalWorkingDirectoryNormalizer.normalize(
            "file:///Users/gordon%20beeming/Developer/../workspace"
        )

        XCTAssertEqual(workingDirectory?.path, "/Users/gordon beeming/workspace")
    }

    func testNormalizesShellDirectoryPath() {
        let workingDirectory = TerminalWorkingDirectoryNormalizer.normalize("/tmp/../workspace")

        XCTAssertEqual(workingDirectory?.path, "/workspace")
    }

    func testRejectsNonFileOSC7Value() {
        XCTAssertNil(TerminalWorkingDirectoryNormalizer.normalize("https://example.com/workspace"))
    }

    func testTerminalLinkRouterAcceptsWebURLsLocalFileURLsAndAbsolutePaths() {
        XCTAssertEqual(
            TerminalLinkRouter.url(from: "https://example.com/path?query=yes#result")?.absoluteString,
            "https://example.com/path?query=yes#result"
        )
        XCTAssertEqual(TerminalLinkRouter.url(from: "http://localhost:3000")?.host, "localhost")
        XCTAssertEqual(TerminalLinkRouter.url(from: "file:///tmp/report.html")?.path, "/tmp/report.html")
        XCTAssertEqual(TerminalLinkRouter.url(from: "file:/tmp/report.html")?.path, "/tmp/report.html")
        let deepFileLink = TerminalLinkRouter.url(
            from: "file:///tmp/../tmp/report.html?theme=dark#section"
        )
        XCTAssertEqual(deepFileLink?.path, "/tmp/report.html")
        XCTAssertEqual(deepFileLink?.query, "theme=dark")
        XCTAssertEqual(deepFileLink?.fragment, "section")
        XCTAssertEqual(
            TerminalLinkRouter.url(from: "/Users/gordon beeming/report.html")?.path,
            "/Users/gordon beeming/report.html"
        )
        XCTAssertNil(TerminalLinkRouter.url(from: "ssh://example.com"))
        XCTAssertNil(TerminalLinkRouter.url(from: "https:///missing-host"))
    }
}
