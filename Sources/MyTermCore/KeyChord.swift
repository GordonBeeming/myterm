import Foundation

/// Modifier keys, expressed without reference to SwiftUI's `EventModifiers` or AppKit's
/// `NSEvent.ModifierFlags`. Both layers need to talk about the same chord, and MyTermCore is the only
/// module both of them can see, so the vocabulary has to be framework-free to live here.
public struct KeyChordModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let command = KeyChordModifiers(rawValue: 1 << 0)
    public static let shift = KeyChordModifiers(rawValue: 1 << 1)
    public static let option = KeyChordModifiers(rawValue: 1 << 2)
    public static let control = KeyChordModifiers(rawValue: 1 << 3)
}

/// A single keyboard chord: one key plus the modifiers held with it.
///
/// `key` is the character the key produces with modifiers ignored, which is what both SwiftUI's
/// `KeyEquivalent` and AppKit's `charactersIgnoringModifiers` report. Non-printing keys use the same
/// scalars those APIs use — Return is `\r`, Tab is `\t`, and the arrows are the private-use scalars in
/// `KeyChord.leftArrow` and friends.
public struct KeyChord: Equatable, Hashable, Sendable {
    public let key: Character
    public let modifiers: KeyChordModifiers

    public init(key: Character, modifiers: KeyChordModifiers) {
        self.key = key
        self.modifiers = modifiers
    }

    // NSLeftArrowFunctionKey and friends. SwiftUI's KeyEquivalent.leftArrow wraps the same scalars, so
    // one spelling serves both layers.
    public static let leftArrow: Character = "\u{F702}"
    public static let rightArrow: Character = "\u{F703}"
    public static let upArrow: Character = "\u{F700}"
    public static let downArrow: Character = "\u{F701}"
}
