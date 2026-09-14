import Foundation

/// The models a Claude Code session can be switched to, and how to name the one in use.
///
/// Shared by the host and the device so both say the same thing about the same identifier. The
/// host reads the identifier off the transcript; the device turns it into a label and offers the
/// switches. Neither guesses: the arguments here are the ones `/model` documents, and the labels
/// are the ones the agent's own picker shows.
public enum AgentModelCatalog {
    /// One model the person can switch to.
    public struct Choice: Identifiable, Equatable, Sendable {
        /// What `/model` accepts. An alias rather than a dated name, so the agent picks the
        /// current release of that family.
        public let argument: String
        public let label: String
        /// True for the million-token variant of a family.
        public let hasExtendedContext: Bool

        public var id: String { argument }

        public init(argument: String, label: String, hasExtendedContext: Bool = false) {
            self.argument = argument
            self.label = label
            self.hasExtendedContext = hasExtendedContext
        }

        /// The command that switches to this model, ready to be typed.
        public var command: String { "/model \(argument)" }
    }

    /// In the order the agent's own picker lists them: most capable first, then the same
    /// families again with the larger window.
    public static let choices: [Choice] = [
        Choice(argument: "fable", label: "Fable 5.1"),
        Choice(argument: "opus", label: "Opus 5"),
        Choice(argument: "sonnet", label: "Sonnet 5"),
        Choice(argument: "haiku", label: "Haiku 4.5"),
        Choice(argument: "fable[1m]", label: "Fable 5.1 (1M)", hasExtendedContext: true),
        Choice(argument: "opus[1m]", label: "Opus 5 (1M)", hasExtendedContext: true),
        Choice(argument: "sonnet[1m]", label: "Sonnet 5 (1M)", hasExtendedContext: true),
    ]

    /// The choice a transcript's model identifier corresponds to, so a menu can mark it.
    ///
    /// Matched by label, which is the one thing both sides derive the same way. An alias in the
    /// transcript names no version, so it matches nothing rather than the wrong version.
    public static func choice(matchingModel identifier: String) -> Choice? {
        guard let label = label(forModel: identifier) else { return nil }
        return choices.first { $0.label == label }
    }

    /// The agent writes this in place of a model on a turn it made up itself, such as a
    /// rate-limit notice. It says nothing about which model is in use.
    public static let syntheticModel = "<synthetic>"

    // MARK: - Naming the model in use

    /// A short label for a model identifier as the agent writes it: `claude-opus-5` is "Opus 5",
    /// `claude-haiku-4-5-20251001` is "Haiku 4.5", `opus[1m]` is "Opus (1M)".
    ///
    /// Nothing for the synthetic marker. An identifier of a shape this does not know is returned
    /// as it came, because a wrong label is worse than a raw one.
    public static func label(forModel identifier: String) -> String? {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != syntheticModel else { return nil }

        var name = trimmed
        let hasExtendedContext = name.hasSuffix("[1m]")
        if hasExtendedContext { name.removeLast(4) }
        if name.hasPrefix("claude-") { name.removeFirst(7) }

        var parts = name.split(separator: "-").map(String.init)
        guard let family = parts.first, families.contains(family) else { return trimmed }
        parts.removeFirst()
        // A dated release carries the date as a final eight-digit part.
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) {
            parts.removeLast()
        }
        guard parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return trimmed }

        var label = family.prefix(1).uppercased() + family.dropFirst()
        if !parts.isEmpty {
            label += " " + parts.joined(separator: ".")
        }
        if hasExtendedContext {
            label += " (1M)"
        }
        return label
    }

    private static let families: Set<String> = ["fable", "opus", "sonnet", "haiku"]
}
