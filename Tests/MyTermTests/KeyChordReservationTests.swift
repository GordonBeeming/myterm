@testable import MyTerm
import AppKit
import MyTermCore
import MyTermPlatform
import XCTest

/// Runs the app's real `MyTermCommandShortcuts.allReserved` table through the real `KeyChordMatcher`.
/// `KeyChordMatcherTests` proves the matcher's logic in isolation; this proves the app's actual chords
/// are actually reserved — the gap where the Shift/uppercase bug shipped despite the matcher tests passing.
final class KeyChordReservationTests: XCTestCase {
    private func keyDown(characters: String, modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: 0
        ), "Could not synthesise a key event")
    }

    func testEveryShiftedLetterChordIsReservedAgainstARealisticUppercaseKeyDown() throws {
        // Each of these is a real Cmd+Shift+<letter> menu command. macOS reports the letter uppercase via
        // charactersIgnoringModifiers when Shift is held, so the synthesised event uses the uppercase
        // character a real keyboard produces — not the lowercase spelling the chord is declared with.
        let shiftedLetterCommands: [(name: String, uppercaseCharacter: String)] = [
            ("newFolder", "N"),
            ("renameWorkspace", "R"),
            ("closeWorkspace", "W"),
            ("newBrowserTab", "L"),
            ("splitBelow", "D"),
            ("showNotifications", "I"),
        ]
        for (name, uppercaseCharacter) in shiftedLetterCommands {
            let event = try keyDown(characters: uppercaseCharacter, modifiers: [.command, .shift])
            XCTAssertTrue(
                KeyChordMatcher.matchesAny(MyTermCommandShortcuts.allReserved, event: event),
                "Expected \(name) (Cmd+Shift+\(uppercaseCharacter)) to be reserved"
            )
        }
    }

    func testAnUnshiftedLetterDoesNotFalselyReserveTheShiftedCommand() throws {
        // Cmd+N (no Shift) must not be caught by newFolder's Cmd+Shift+N reservation.
        let event = try keyDown(characters: "n", modifiers: [.command])
        XCTAssertFalse(
            KeyChordMatcher.matches(MyTermCommandShortcuts.newFolder, event: event),
            "Cmd+N without Shift must not match the Cmd+Shift+N command"
        )
    }
}

/// The reserved table against the two things it must never collide with: itself, and the terminal
/// underneath. And against the document that tells the user what it holds.
final class KeyChordTableTests: XCTestCase {
    /// Every chord the app claims, named, so a failure says which command is at fault.
    private let namedChords: [(name: String, chord: KeyChord)] = [
        ("globalSettings", MyTermCommandShortcuts.globalSettings),
        ("newWorkspace", MyTermCommandShortcuts.newWorkspace),
        ("newFolder", MyTermCommandShortcuts.newFolder),
        ("renameWorkspace", MyTermCommandShortcuts.renameWorkspace),
        ("decreaseWorkspaceFontSize", MyTermCommandShortcuts.decreaseWorkspaceFontSize),
        ("increaseWorkspaceFontSize", MyTermCommandShortcuts.increaseWorkspaceFontSize),
        ("closeWorkspace", MyTermCommandShortcuts.closeWorkspace),
        ("previousWorkspace", MyTermCommandShortcuts.previousWorkspace),
        ("nextWorkspace", MyTermCommandShortcuts.nextWorkspace),
        ("toggleSidebar", MyTermCommandShortcuts.toggleSidebar),
        ("showNotifications", MyTermCommandShortcuts.showNotifications),
        ("newTerminalTab", MyTermCommandShortcuts.newTerminalTab),
        ("newBrowserTab", MyTermCommandShortcuts.newBrowserTab),
        ("renameTab", MyTermCommandShortcuts.renameTab),
        ("previousTab", MyTermCommandShortcuts.previousTab),
        ("nextTab", MyTermCommandShortcuts.nextTab),
        ("togglePaneFullScreen", MyTermCommandShortcuts.togglePaneFullScreen),
        ("splitRight", MyTermCommandShortcuts.splitRight),
        ("splitBelow", MyTermCommandShortcuts.splitBelow),
        ("closeFocusedPaneOrTab", MyTermCommandShortcuts.closeFocusedPaneOrTab),
        ("focusPaneLeft", MyTermCommandShortcuts.focusPaneLeft),
        ("focusPaneUp", MyTermCommandShortcuts.focusPaneUp),
        ("focusPaneRight", MyTermCommandShortcuts.focusPaneRight),
        ("focusPaneDown", MyTermCommandShortcuts.focusPaneDown),
        ("moveTabToPreviousPane", MyTermCommandShortcuts.moveTabToPreviousPane),
        ("moveTabToNextPane", MyTermCommandShortcuts.moveTabToNextPane),
        ("browserBack", MyTermCommandShortcuts.browserBack),
        ("browserForward", MyTermCommandShortcuts.browserForward),
        ("reloadBrowser", MyTermCommandShortcuts.reloadBrowser),
        ("focusBrowserAddress", MyTermCommandShortcuts.focusBrowserAddress),
        ("findInBrowser", MyTermCommandShortcuts.findInBrowser),
        ("resetBrowserZoom", MyTermCommandShortcuts.resetBrowserZoom),
    ] + MyTermCommandShortcuts.selectWorkspaceByNumber.enumerated().map { ("workspace\($0.offset + 1)", $0.element) }
      + MyTermCommandShortcuts.selectTabByNumber.enumerated().map { ("tab\($0.offset + 1)", $0.element) }

    func testTheNamedListAndTheReservedTableAreTheSameChords() {
        XCTAssertEqual(Set(namedChords.map(\.chord)), Set(MyTermCommandShortcuts.allReserved))
        XCTAssertEqual(namedChords.count, MyTermCommandShortcuts.allReserved.count)
    }

    func testNoTwoCommandsShareAChord() {
        var seen: [KeyChord: String] = [:]
        for (name, chord) in namedChords {
            if let other = seen[chord] {
                XCTFail("\(name) and \(other) both bind \(describe(chord))")
            }
            seen[chord] = name
        }
    }

    /// A chord without ⌘ is a keystroke the terminal would otherwise receive. The kinds the app
    /// already takes are listed here on purpose; a new one needs the same decision made, not made
    /// by accident. ⌃2…⌃8 are real control characters on most terminals (NUL, ESC, FS, GS, RS, US,
    /// DEL), which is the cost of ⌃1…⌃9 for tabs.
    func testEveryChordWithoutCommandIsAKnownTerminalTradeOff() {
        let knownTradeOffs: Set<KeyChord> = Set(
            [MyTermCommandShortcuts.previousTab, MyTermCommandShortcuts.nextTab]
            + MyTermCommandShortcuts.selectTabByNumber
        )
        for (name, chord) in namedChords where !chord.modifiers.contains(.command) {
            XCTAssertTrue(
                knownTradeOffs.contains(chord),
                "\(name) binds \(describe(chord)) without ⌘, which a terminal program may want"
            )
        }
    }

    /// Chords macOS itself, or every AppKit text field, already answers to. None of the app's
    /// chords may land on one: the app would swallow it, or be swallowed.
    func testNoChordCollidesWithASystemWideShortcut() {
        let systemChords: [(String, KeyChord)] = [
            ("Quit", KeyChord(key: "q", modifiers: [.command])),
            ("Hide", KeyChord(key: "h", modifiers: [.command])),
            ("Hide Others", KeyChord(key: "h", modifiers: [.command, .option])),
            ("Minimize", KeyChord(key: "m", modifiers: [.command])),
            ("Enter Full Screen", KeyChord(key: "f", modifiers: [.command, .control])),
            ("Spotlight", KeyChord(key: " ", modifiers: [.command])),
            ("Force Quit", KeyChord(key: "\u{1B}", modifiers: [.command, .option])),
            ("Screenshot", KeyChord(key: "3", modifiers: [.command, .shift])),
            ("Screenshot selection", KeyChord(key: "4", modifiers: [.command, .shift])),
            ("Screenshot toolbar", KeyChord(key: "5", modifiers: [.command, .shift])),
            ("Copy", KeyChord(key: "c", modifiers: [.command])),
            ("Paste", KeyChord(key: "v", modifiers: [.command])),
            ("Cut", KeyChord(key: "x", modifiers: [.command])),
            ("Select All", KeyChord(key: "a", modifiers: [.command])),
            ("Undo", KeyChord(key: "z", modifiers: [.command])),
            ("Redo", KeyChord(key: "z", modifiers: [.command, .shift])),
            ("Emoji", KeyChord(key: " ", modifiers: [.command, .control])),
            ("Mission Control left", KeyChord(key: KeyChord.leftArrow, modifiers: [.control])),
            ("Mission Control right", KeyChord(key: KeyChord.rightArrow, modifiers: [.control])),
        ]
        let reserved = Set(MyTermCommandShortcuts.allReserved)
        for (name, chord) in systemChords {
            XCTAssertFalse(reserved.contains(chord), "\(describe(chord)) is \(name) on macOS")
        }
    }

    /// `docs/SHORTCUTS.md` is the user's copy of the table. Every chord in the code appears there,
    /// spelled the way the document spells chords.
    func testEveryReservedChordIsDocumented() throws {
        let documentURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "docs/SHORTCUTS.md")
        let document = try String(contentsOf: documentURL, encoding: .utf8)
        let documented = Set(documentedChords(in: document))
        XCTAssertFalse(documented.isEmpty, "No <kbd> chords found in \(documentURL.path)")

        for (name, chord) in namedChords {
            // The number keys are documented as a range, 1 … 9, so only the ends are literal.
            if let digit = chord.key.wholeNumberValue, (2...8).contains(digit) { continue }
            XCTAssertTrue(documented.contains(chord), "\(name) (\(describe(chord))) is missing from docs/SHORTCUTS.md")
        }
    }

    private func documentedChords(in document: String) -> [KeyChord] {
        guard let pattern = try? NSRegularExpression(pattern: "<kbd>([^<]+)</kbd>") else { return [] }
        let range = NSRange(document.startIndex..., in: document)
        return pattern.matches(in: document, range: range).compactMap { match in
            guard let range = Range(match.range(at: 1), in: document) else { return nil }
            return chord(fromDocumented: String(document[range]))
        }
    }

    private func chord(fromDocumented text: String) -> KeyChord? {
        var modifiers: KeyChordModifiers = []
        var rest = Substring(text)
        while let first = rest.first {
            switch first {
            case "⌘": modifiers.insert(.command)
            case "⇧": modifiers.insert(.shift)
            case "⌥": modifiers.insert(.option)
            case "⌃": modifiers.insert(.control)
            default:
                let key: Character
                switch rest {
                case "Tab": key = "\t"
                case "↩": key = "\r"
                case "←": key = KeyChord.leftArrow
                case "→": key = KeyChord.rightArrow
                case "↑": key = KeyChord.upArrow
                case "↓": key = KeyChord.downArrow
                case "⌫": key = "\u{7F}"
                default:
                    guard rest.count == 1 else { return nil }
                    key = Character(rest.lowercased())
                }
                return KeyChord(key: key, modifiers: modifiers)
            }
            rest.removeFirst()
        }
        return nil
    }

    private func describe(_ chord: KeyChord) -> String {
        var text = ""
        if chord.modifiers.contains(.control) { text += "⌃" }
        if chord.modifiers.contains(.option) { text += "⌥" }
        if chord.modifiers.contains(.shift) { text += "⇧" }
        if chord.modifiers.contains(.command) { text += "⌘" }
        switch chord.key {
        case "\t": text += "Tab"
        case "\r": text += "↩"
        case KeyChord.leftArrow: text += "←"
        case KeyChord.rightArrow: text += "→"
        case KeyChord.upArrow: text += "↑"
        case KeyChord.downArrow: text += "↓"
        default: text += String(chord.key).uppercased()
        }
        return text
    }
}
