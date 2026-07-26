import AppKit
import MyTermCore

/// Translates AppKit key events into `KeyChord` terms so the browser layer can recognise chords the app
/// has reserved for its own menu commands.
public enum KeyChordMatcher {
    public static func matches(_ chord: KeyChord, event: NSEvent) -> Bool {
        // `charactersIgnoringModifiers` still applies Shift, so a shifted letter arrives uppercase
        // ("N") while the table declares it lowercase ("n"). Compare case-insensitively, the same way
        // AppKit's own menu key-equivalent matching does.
        guard let characters = event.charactersIgnoringModifiers,
              characters.count == 1,
              characters.lowercased() == String(chord.key).lowercased() else {
            return false
        }
        return modifiers(for: event) == chord.modifiers
    }

    public static func matchesAny(_ chords: [KeyChord], event: NSEvent) -> Bool {
        chords.contains { matches($0, event: event) }
    }

    /// Exact-match semantics: a chord with extra modifiers held is a *different* chord, not the same one.
    /// Cmd+Shift+Option+Return must not trigger the Cmd+Shift+Return command.
    static func modifiers(for event: NSEvent) -> KeyChordModifiers {
        // Caps lock never participates in a chord. `.function` and `.numericPad` are set by macOS on the
        // arrow keys and the keypad, so leaving them in would make every arrow chord fail to match.
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .function, .numericPad])

        var modifiers: KeyChordModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        return modifiers
    }
}
