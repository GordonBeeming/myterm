import AppKit
import XCTest
@testable import MyTermPlatform

final class TerminalSessionConfigurationTests: XCTestCase {
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
        let plainReturn = TerminalInputEvent(keyCode: 36, charactersIgnoringModifiers: "\r", modifiers: [])
        let plainArrow = TerminalInputEvent(keyCode: 126, charactersIgnoringModifiers: "", modifiers: [])
        let unrelatedShortcut = TerminalInputEvent(keyCode: 8, charactersIgnoringModifiers: "c", modifiers: [.command])

        XCTAssertNil(TerminalInputTranslator.sequence(for: commandLeft, kittyKeyboardEnabled: true))
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

    func testTerminalLinkRouterAcceptsEveryValidWebHostAndRejectsOtherSchemes() {
        XCTAssertEqual(
            TerminalLinkRouter.webURL(from: "https://example.com/path?query=yes#result")?.absoluteString,
            "https://example.com/path?query=yes#result"
        )
        XCTAssertEqual(TerminalLinkRouter.webURL(from: "http://localhost:3000")?.host, "localhost")
        XCTAssertNil(TerminalLinkRouter.webURL(from: "file:///tmp/report.html"))
        XCTAssertNil(TerminalLinkRouter.webURL(from: "ssh://example.com"))
        XCTAssertNil(TerminalLinkRouter.webURL(from: "https:///missing-host"))
    }
}
