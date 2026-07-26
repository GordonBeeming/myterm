import MyTermCore
import XCTest

final class KeyChordTests: XCTestCase {
    func testChordsWithTheSameKeyButDifferentModifiersAreNotEqual() {
        let splitRight = KeyChord(key: "d", modifiers: [.command])
        let splitBelow = KeyChord(key: "d", modifiers: [.command, .shift])
        XCTAssertNotEqual(splitRight, splitBelow)
    }

    func testModifierOrderDoesNotAffectEquality() {
        XCTAssertEqual(
            KeyChord(key: "w", modifiers: [.command, .shift]),
            KeyChord(key: "w", modifiers: [.shift, .command])
        )
    }

    func testChordsAreUsableAsSetMembers() {
        let chords: Set<KeyChord> = [
            KeyChord(key: "d", modifiers: [.command]),
            KeyChord(key: "d", modifiers: [.command]),
            KeyChord(key: "d", modifiers: [.command, .shift]),
        ]
        XCTAssertEqual(chords.count, 2)
    }

    func testArrowScalarsMatchTheAppKitFunctionKeyValues() {
        // These have to stay the private-use scalars AppKit reports in charactersIgnoringModifiers and
        // SwiftUI wraps in KeyEquivalent.leftArrow, or arrow chords match neither layer.
        XCTAssertEqual(KeyChord.leftArrow, "\u{F702}")
        XCTAssertEqual(KeyChord.rightArrow, "\u{F703}")
        XCTAssertEqual(KeyChord.upArrow, "\u{F700}")
        XCTAssertEqual(KeyChord.downArrow, "\u{F701}")
    }

    func testModifierSetSemantics() {
        var modifiers: KeyChordModifiers = [.command]
        XCTAssertFalse(modifiers.contains(.shift))
        modifiers.insert(.shift)
        XCTAssertTrue(modifiers.contains(.command))
        XCTAssertTrue(modifiers.contains(.shift))
        XCTAssertEqual(modifiers, [.command, .shift])
    }
}
