import Foundation
@preconcurrency import SwiftTerm

/// Encodes a cell attribute as the SGR sequence that reproduces it.
///
/// Every sequence starts from parameter 0, so a run never inherits state from the run before it.
/// That costs a few bytes per run and removes the class of bugs where a snapshot only paints
/// correctly when it is applied to a terminal that already happens to be in the right state.
enum TerminalSGREncoder {
    static func sequence(for attribute: Attribute) -> [UInt8] {
        var parameters = ["0"]

        let style = attribute.style
        if style.contains(.bold) { parameters.append("1") }
        if style.contains(.dim) { parameters.append("2") }
        if style.contains(.italic) { parameters.append("3") }
        if style.contains(.blink) { parameters.append("5") }
        if style.contains(.inverse) { parameters.append("7") }
        if style.contains(.invisible) { parameters.append("8") }
        if style.contains(.crossedOut) { parameters.append("9") }

        // The plain underline flag and the extended underline style are separate in SwiftTerm. An
        // extended style implies the underline, so emitting both would be redundant.
        switch attribute.underlineStyle {
        case .none:
            if style.contains(.underline) { parameters.append("4") }
        case .single:
            parameters.append("4")
        case .double:
            parameters.append("21")
        case .curly:
            parameters.append("4:3")
        case .dotted:
            parameters.append("4:4")
        case .dashed:
            parameters.append("4:5")
        }

        parameters.append(contentsOf: foregroundParameters(attribute.fg))
        parameters.append(contentsOf: backgroundParameters(attribute.bg))
        if let underlineColor = attribute.underlineColor {
            parameters.append(contentsOf: underlineColorParameters(underlineColor))
        }

        return Array("\u{1b}[\(parameters.joined(separator: ";"))m".utf8)
    }

    private static func foregroundParameters(_ color: Attribute.Color) -> [String] {
        switch color {
        case .defaultColor, .defaultInvertedColor:
            ["39"]
        case .ansi256(let code) where code < 8:
            ["\(30 + Int(code))"]
        case .ansi256(let code) where code < 16:
            ["\(90 + Int(code) - 8)"]
        case .ansi256(let code):
            ["38", "5", "\(code)"]
        case .trueColor(let red, let green, let blue):
            ["38", "2", "\(red)", "\(green)", "\(blue)"]
        }
    }

    private static func backgroundParameters(_ color: Attribute.Color) -> [String] {
        switch color {
        case .defaultColor, .defaultInvertedColor:
            ["49"]
        case .ansi256(let code) where code < 8:
            ["\(40 + Int(code))"]
        case .ansi256(let code) where code < 16:
            ["\(100 + Int(code) - 8)"]
        case .ansi256(let code):
            ["48", "5", "\(code)"]
        case .trueColor(let red, let green, let blue):
            ["48", "2", "\(red)", "\(green)", "\(blue)"]
        }
    }

    private static func underlineColorParameters(_ color: Attribute.Color) -> [String] {
        switch color {
        case .defaultColor, .defaultInvertedColor:
            ["59"]
        case .ansi256(let code):
            ["58", "5", "\(code)"]
        case .trueColor(let red, let green, let blue):
            ["58", "2", "\(red)", "\(green)", "\(blue)"]
        }
    }
}
