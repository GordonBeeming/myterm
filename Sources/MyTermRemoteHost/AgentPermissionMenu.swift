import Foundation
import MyTermRemoteProtocol

/// Reads the numbered menu an agent draws when it stops to ask permission.
///
/// The options are on the screen and nowhere else. The agent's own record shows that a tool was
/// requested and that nothing has answered it; what the person is being offered, and which number
/// each choice sits on, exists only in the terminal grid.
///
/// This drives one rule, and the rule is the whole reason the type exists:
///
/// **A device answers a label, never a number.** A menu's composition varies between runs. In one
/// observed run the third option was "Yes, and switch to auto mode", which grants the request *and*
/// turns off every later prompt in that session. A device that sent a remembered `3` would have
/// done that while believing it was denying. So the host reads the menu again at the moment of
/// answering, and sends a digit only when the label still sitting on that number is the one the
/// person actually saw.
enum AgentPermissionMenu {
    /// A choice the menu offers.
    struct Option: Equatable {
        let number: Int
        let label: String
    }

    /// Labels a device is never offered.
    ///
    /// These change what the Mac will do while nobody is watching it. A phone is the worst place to
    /// decide that, and refusing here means the verification step can never be handed one either.
    private static let refused = [
        // Matched loosely on purpose. The wording varies between builds and between agents, and a
        // list that only knew one spelling would offer a device the very choice it exists to keep
        // away from one.
        "ask again",
        "auto mode",
        "auto-accept",
        "always allow",
        "always approve",
        "remember this",
        // "Yes, allow all edits during this session (shift+tab)" is the CLI's file-edit prompt.
        // It turns on accept-edits for the rest of the session, which is the same disarming.
        "allow all",
        "this session",
    ]

    /// Whether these rows are showing a permission prompt at all.
    ///
    /// The question is required, not just the numbers: a numbered list in a command's output is not
    /// something to answer with a keystroke.
    static func isPrompt(rows: [String]) -> Bool {
        let text = rows.joined(separator: "\n").lowercased()
        guard text.contains("do you want to") || text.contains("do you want") else { return false }
        return !numberedOptions(rows: rows).isEmpty
    }

    /// Every numbered option on the screen, in the order they appear.
    static func numberedOptions(rows: [String]) -> [Option] {
        var options: [Option] = []
        for row in rows {
            guard let option = self.option(in: row) else { continue }
            // A number that appears twice means this is not a menu being read correctly.
            guard !options.contains(where: { $0.number == option.number }) else { return [] }
            options.append(option)
        }
        return options
    }

    /// What a device may be shown.
    ///
    /// The unsafe choices are dropped rather than disabled: an option a device was never offered
    /// cannot be tapped by mistake, and cannot be sent back for verification either.
    static func offerableOptions(rows: [String]) -> [RemoteAgentPromptOption] {
        guard isPrompt(rows: rows) else { return [] }
        return numberedOptions(rows: rows)
            .filter { !isRefused($0.label) }
            .map { RemoteAgentPromptOption(number: $0.number, label: $0.label) }
    }

    /// The keystrokes that answer a choice, or nothing when the screen no longer agrees.
    ///
    /// Called with what the device displayed, against the screen as it stands now. A menu that has
    /// changed under the person answers nothing at all.
    static func keystrokes(
        forAnswering option: RemoteAgentPromptOption,
        rows: [String]
    ) -> [UInt8]? {
        guard isPrompt(rows: rows) else { return nil }
        guard !isRefused(option.label) else { return nil }
        guard let current = numberedOptions(rows: rows).first(where: { $0.number == option.number }),
              matches(current.label, option.label) else {
            return nil
        }
        // The label on screen now is the one the keystroke answers. "Yes" is a prefix of "Yes,
        // and switch to auto mode", and the cut-off allowance must not widen a plain yes into that.
        guard !isRefused(current.label) else { return nil }
        return Array("\(option.number)\r".utf8)
    }

    /// Cancelling, which is the one answer that needs no menu read at all.
    ///
    /// Escape is what the prompt's own footer offers, and it means the same thing wherever the
    /// options happen to sit. It is the only safe answer that does not depend on reading the screen.
    static let denyKeystrokes: [UInt8] = [0x1B]

    // MARK: - Reading a row

    /// Matches `1. Yes`, and the same line with the selection marker in front of it.
    private static func option(in row: String) -> Option? {
        var text = Substring(row)
        text = text.drop { $0 == " " || $0 == "\t" }
        // The cursor marker sits ahead of the highlighted option.
        if let first = text.first, "❯>▶*".contains(first) {
            text = text.dropFirst().drop { $0 == " " }
        }
        let digits = text.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 2, let number = Int(digits) else { return nil }
        text = text.dropFirst(digits.count)
        guard text.first == "." || text.first == ")" else { return nil }
        let label = text.dropFirst().trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }
        return Option(number: number, label: label)
    }

    private static func isRefused(_ label: String) -> Bool {
        let lowered = label.lowercased()
        return refused.contains { lowered.contains($0) }
    }

    /// A label the terminal wrapped, or padded, is still the same label.
    ///
    /// Compared on its leading run rather than in full: a long option is cut by the grid's width,
    /// so requiring the whole string would refuse answers that are perfectly correct.
    private static func matches(_ current: String, _ shown: String) -> Bool {
        let a = normalized(current)
        let b = normalized(shown)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a.hasPrefix(b) || b.hasPrefix(a)
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
