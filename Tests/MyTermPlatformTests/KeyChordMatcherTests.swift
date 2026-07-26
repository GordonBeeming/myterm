import AppKit
import MyTermCore
@testable import MyTermPlatform
import XCTest

final class KeyChordMatcherTests: XCTestCase {
    private func keyDown(
        characters: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16 = 0
    ) throws -> NSEvent {
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
            keyCode: keyCode
        ), "Could not synthesise a key event")
    }

    private let fullScreen = KeyChord(key: "\r", modifiers: [.command, .shift])

    func testMatchesTheDeclaredChord() throws {
        let event = try keyDown(characters: "\r", modifiers: [.command, .shift], keyCode: 36)
        XCTAssertTrue(KeyChordMatcher.matches(fullScreen, event: event))
    }

    func testRequiresAnExactModifierSet() throws {
        // A subset must not match, or Cmd+Return would trigger the Cmd+Shift+Return command.
        XCTAssertFalse(KeyChordMatcher.matches(
            fullScreen,
            event: try keyDown(characters: "\r", modifiers: [.command], keyCode: 36)
        ))
        // A superset must not match either — Cmd+Shift+Option+Return is a different chord.
        XCTAssertFalse(KeyChordMatcher.matches(
            fullScreen,
            event: try keyDown(characters: "\r", modifiers: [.command, .shift, .option], keyCode: 36)
        ))
    }

    func testIgnoresCapsLock() throws {
        let event = try keyDown(characters: "\r", modifiers: [.command, .shift, .capsLock], keyCode: 36)
        XCTAssertTrue(KeyChordMatcher.matches(fullScreen, event: event))
    }

    func testIgnoresTheFunctionAndNumericPadFlagsMacOSSetsOnArrowKeys() throws {
        // macOS sets .function and .numericPad on arrow keys. Without stripping them, every arrow chord
        // in the reserved list would silently fail to match.
        let moveTab = KeyChord(key: KeyChord.leftArrow, modifiers: [.command, .option, .shift])
        let event = try keyDown(
            characters: String(KeyChord.leftArrow),
            modifiers: [.command, .option, .shift, .function, .numericPad],
            keyCode: 123
        )
        XCTAssertTrue(KeyChordMatcher.matches(moveTab, event: event))
    }

    func testDoesNotMatchAnUnmodifiedKey() throws {
        let event = try keyDown(characters: "b", modifiers: [])
        XCTAssertFalse(KeyChordMatcher.matches(KeyChord(key: "b", modifiers: [.command]), event: event))
    }

    func testDoesNotMatchADifferentKey() throws {
        // Real Shift+D reports uppercase "D" via charactersIgnoringModifiers; synthesise that rather
        // than a hand-lowered "d", which is not what a real keyboard produces.
        let event = try keyDown(characters: "D", modifiers: [.command, .shift])
        XCTAssertFalse(KeyChordMatcher.matches(fullScreen, event: event))
    }

    func testMatchesAShiftedLetterChordDespiteTheUppercaseCharacter() throws {
        // charactersIgnoringModifiers still applies Shift, so a real Cmd+Shift+N key-down reports "N"
        // even though the chord declares the lowercase "n". Every hand-written event below carries the
        // uppercase a real keyboard would produce, not a lowercased stand-in — one per letter used by a
        // Cmd+Shift chord in MyTermCommandShortcuts (newFolder, renameWorkspace, closeWorkspace,
        // newBrowserTab, splitBelow).
        for lowercaseKey in "nrwld" {
            let chord = KeyChord(key: lowercaseKey, modifiers: [.command, .shift])
            let event = try keyDown(characters: String(lowercaseKey).uppercased(), modifiers: [.command, .shift])
            XCTAssertTrue(
                KeyChordMatcher.matches(chord, event: event),
                "Expected Cmd+Shift+\(lowercaseKey) to match an uppercase '\(lowercaseKey.uppercased())' key-down"
            )
        }
    }

    func testShiftedMatchingDoesNotLoosenModifierComparison() throws {
        // Case-insensitive key comparison must not make the modifier check any less exact: Cmd+N (no
        // Shift) still must not fire the Cmd+Shift+N command.
        let event = try keyDown(characters: "n", modifiers: [.command])
        XCTAssertFalse(KeyChordMatcher.matches(KeyChord(key: "n", modifiers: [.command, .shift]), event: event))
    }

    func testMatchesAnyFindsAChordInTheReservedList() throws {
        let reserved = [
            KeyChord(key: "b", modifiers: [.command]),
            fullScreen,
            KeyChord(key: "t", modifiers: [.command]),
        ]
        XCTAssertTrue(KeyChordMatcher.matchesAny(
            reserved,
            event: try keyDown(characters: "\r", modifiers: [.command, .shift], keyCode: 36)
        ))
        XCTAssertFalse(KeyChordMatcher.matchesAny(
            reserved,
            event: try keyDown(characters: "q", modifiers: [.command])
        ))
        XCTAssertFalse(KeyChordMatcher.matchesAny([], event: try keyDown(characters: "b", modifiers: [.command])))
    }

    func testMultiCharacterInputNeverMatches() throws {
        // Dead keys and IME composition can deliver more than one character; none of those are chords.
        let event = try keyDown(characters: "ab", modifiers: [.command])
        XCTAssertFalse(KeyChordMatcher.matches(KeyChord(key: "a", modifiers: [.command]), event: event))
    }

    @MainActor
    func testReservedChordsReachTheWebViewThroughTheFactory() {
        // The wiring that carries the app's command table to the view actually doing the declining:
        // factory -> controller -> MyTermWebView. A break anywhere here silently restores the old bug.
        let factory = WebKitBrowserSessionFactory(reservedChords: [fullScreen])
        let session = factory.makeSession(profile: BrowserDataProfile(scope: .workspace, persistentStoreID: UUID()))

        guard let webView = session.webView as? MyTermWebView else {
            return XCTFail("Expected the session to use MyTermWebView")
        }
        XCTAssertEqual(webView.reservedChords, [fullScreen])
    }

    @MainActor
    func testWebViewReservesNothingByDefault() {
        // The default has to stay empty so previews and tests keep plain WebKit behaviour.
        let session = WebKitBrowserSessionFactory()
            .makeSession(profile: BrowserDataProfile(scope: .workspace, persistentStoreID: UUID()))

        guard let webView = session.webView as? MyTermWebView else {
            return XCTFail("Expected the session to use MyTermWebView")
        }
        XCTAssertEqual(webView.reservedChords, [])
    }

    @MainActor
    func testTheWebViewDeclinesReservedChordsAndKeepsTheRest() throws {
        // Exercises the real override. `false` means "not handled here", which is what lets AppKit carry
        // the event on to the main menu instead of the page.
        let session = WebKitBrowserSessionFactory(reservedChords: [fullScreen])
            .makeSession(profile: BrowserDataProfile(scope: .workspace, persistentStoreID: UUID()))
        guard let webView = session.webView as? MyTermWebView else {
            return XCTFail("Expected the session to use MyTermWebView")
        }

        let reservedEvent = try keyDown(characters: "\r", modifiers: [.command, .shift], keyCode: 36)
        XCTAssertFalse(webView.performKeyEquivalent(with: reservedEvent))

        // An unreserved chord must fall through to WebKit's own handling rather than being declined by us.
        // With no page loaded WebKit answers `false` too, so assert on the matcher's decision instead —
        // the override's branch is what's under test here.
        let unreservedEvent = try keyDown(characters: "j", modifiers: [.command], keyCode: 38)
        XCTAssertFalse(KeyChordMatcher.matchesAny(webView.reservedChords, event: unreservedEvent))
    }
}
