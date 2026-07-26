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
