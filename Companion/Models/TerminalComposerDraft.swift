import Foundation
import Observation

@MainActor
@Observable
final class TerminalComposerDraft {
    static let maximumUTF8Bytes = 64 * 1_024
    var text = ""
    var isSending = false
    var errorMessage: String?

    static func pasteBytes(_ text: String, bracketed: Bool, appendReturn: Bool) throws -> Data {
        guard !text.isEmpty else { throw TerminalComposerError.empty }
        guard text.utf8.count <= maximumUTF8Bytes else { throw TerminalComposerError.tooLong }
        guard text.unicodeScalars.allSatisfy({
            (32...126).contains($0.value) || $0.value >= 160 || [9, 10, 13].contains($0.value)
        }) else { throw TerminalComposerError.controlCharacters }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var paste = bracketed ? "\u{1b}[200~" + normalized + "\u{1b}[201~" : normalized
        if appendReturn { paste += "\r" }
        return Data(paste.utf8)
    }
}

enum TerminalComposerError: LocalizedError {
    case empty, tooLong, controlCharacters, requiresControl

    var errorDescription: String? {
        switch self {
        case .empty: "Write something before inserting it."
        case .tooLong: "This draft is too long. Split it into smaller messages."
        case .controlCharacters: "The draft contains terminal control characters. Remove them before inserting it."
        case .requiresControl: "Take control of this terminal before inserting your draft."
        }
    }
}
