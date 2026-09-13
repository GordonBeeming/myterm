import Foundation

/// One block of an agent's message, split out so a device can lay it out.
///
/// Agents write markdown, and a phone shows what they wrote as prose. SwiftUI reads inline
/// markdown from a literal but never from a value, and it knows nothing of blocks either way, so
/// the split into blocks lives here, where it can be tested, and the inline styling stays with the
/// view. Text inside a block still carries its inline markdown.
public enum AgentMarkdownBlock: Equatable, Sendable {
    case paragraph(String)
    case heading(level: Int, String)
    case bullets([String])
    case numbered([String])
    case tasks([AgentMarkdownTask])
    case quote(String)
    case code(language: String?, String)
    case table(header: [String], alignments: [AgentMarkdownColumnAlignment], rows: [[String]])
    case rule
}

/// One item of a task list: `- [ ] todo` or `- [x] done`.
public struct AgentMarkdownTask: Equatable, Sendable {
    public var isDone: Bool
    public var text: String

    public init(isDone: Bool, text: String) {
        self.isDone = isDone
        self.text = text
    }
}

/// How a table column lines up, read from the colons in its delimiter cell.
public enum AgentMarkdownColumnAlignment: Equatable, Sendable {
    case leading
    case center
    case trailing
}

public enum AgentMarkdown {
    /// Splits a message into blocks. A malformed message is still shown: an unclosed fence runs to
    /// the end, and anything unrecognised is a paragraph.
    public static func blocks(in text: String) -> [AgentMarkdownBlock] {
        var blocks: [AgentMarkdownBlock] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var numbered: [String] = []
        var tasks: [AgentMarkdownTask] = []
        var quote: [String] = []
        var code: [String]?
        var codeLanguage: String?
        var table: (header: [String], alignments: [AgentMarkdownColumnAlignment], rows: [[String]])?

        func flush() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: " ")))
                paragraph = []
            }
            if !bullets.isEmpty {
                blocks.append(.bullets(bullets))
                bullets = []
            }
            if !numbered.isEmpty {
                blocks.append(.numbered(numbered))
                numbered = []
            }
            if !tasks.isEmpty {
                blocks.append(.tasks(tasks))
                tasks = []
            }
            if !quote.isEmpty {
                blocks.append(.quote(quote.joined(separator: " ")))
                quote = []
            }
            if let open = table {
                blocks.append(.table(header: open.header, alignments: open.alignments, rows: open.rows))
                table = nil
            }
        }

        // "\r\n" is one Character in Swift, so a message with Windows line endings would never
        // split at all and every heading, list and fence in it would collapse into one paragraph.
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .flatMap { resolvingCarriageReturns(in: String($0)) }
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            index += 1

            if var openCode = code {
                if trimmed.hasPrefix("```") {
                    blocks.append(.code(language: codeLanguage, openCode.joined(separator: "\n")))
                    code = nil
                    codeLanguage = nil
                } else {
                    openCode.append(line)
                    code = openCode
                }
                continue
            }

            if trimmed.hasPrefix("```") {
                flush()
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                codeLanguage = language.isEmpty ? nil : language
                code = []
                continue
            }

            if trimmed.isEmpty {
                flush()
                continue
            }

            // A table runs until a blank line or a line that is not a row.
            if var open = table {
                if trimmed.contains("|"), let cells = tableCells(in: trimmed) {
                    open.rows.append(cells.fitted(to: open.header.count))
                    table = open
                    continue
                }
                flush()
            }

            // A row is only a table's header when the delimiter row stands under it with the same
            // number of cells; a row of pipes on its own is prose.
            if trimmed.contains("|"),
               index < lines.count,
               let header = tableCells(in: trimmed),
               let alignments = tableAlignments(in: lines[index].trimmingCharacters(in: .whitespaces)),
               alignments.count == header.count {
                flush()
                table = (header, alignments, [])
                index += 1
                continue
            }

            if isRule(trimmed) {
                flush()
                blocks.append(.rule)
                continue
            }

            if let heading = heading(in: trimmed) {
                flush()
                blocks.append(heading)
                continue
            }

            if let item = listItem(in: trimmed, markers: ["- ", "* ", "+ "]) {
                if let task = task(in: item) {
                    if !paragraph.isEmpty || !bullets.isEmpty || !numbered.isEmpty || !quote.isEmpty { flush() }
                    tasks.append(task)
                    continue
                }
                if !paragraph.isEmpty || !numbered.isEmpty || !tasks.isEmpty || !quote.isEmpty { flush() }
                bullets.append(item)
                continue
            }

            if let item = numberedItem(in: trimmed) {
                if !paragraph.isEmpty || !bullets.isEmpty || !tasks.isEmpty || !quote.isEmpty { flush() }
                numbered.append(item)
                continue
            }

            if trimmed.hasPrefix(">") {
                if !paragraph.isEmpty || !bullets.isEmpty || !numbered.isEmpty || !tasks.isEmpty { flush() }
                quote.append(trimmed.dropFirst().trimmingCharacters(in: .whitespaces))
                continue
            }

            // A line under a list item that is indented continues that item.
            if line.hasPrefix("  "), let last = bullets.popLast() {
                bullets.append(last + " " + trimmed)
                continue
            }
            if line.hasPrefix("  "), let last = numbered.popLast() {
                numbered.append(last + " " + trimmed)
                continue
            }
            if line.hasPrefix("  "), var last = tasks.popLast() {
                last.text += " " + trimmed
                tasks.append(last)
                continue
            }

            if !bullets.isEmpty || !numbered.isEmpty || !tasks.isEmpty || !quote.isEmpty { flush() }
            paragraph.append(trimmed)
        }

        if let openCode = code {
            blocks.append(.code(language: codeLanguage, openCode.joined(separator: "\n")))
        }
        flush()
        return blocks
    }

    /// A line with bare carriage returns in it, as a terminal would have shown it.
    ///
    /// A progress bar redraws its line by returning to column zero and writing over what was
    /// there, and a tool result holds every redraw with the returns still in. Text after a return
    /// that is at least as long as what came before covers it, so the line shows its final state.
    /// A shorter tail would leave a merged line on a terminal; here it starts a new line instead,
    /// so nothing written is lost.
    static func resolvingCarriageReturns(in line: String) -> [String] {
        guard line.contains("\r") else { return [line] }
        var lines: [String] = []
        var current = ""
        for segment in line.split(separator: "\r", omittingEmptySubsequences: false).map(String.init) {
            if segment.isEmpty { continue }
            if segment.count >= current.count {
                current = segment
            } else {
                lines.append(current)
                current = segment
            }
        }
        lines.append(current)
        return lines
    }

    private static func heading(in line: String) -> AgentMarkdownBlock? {
        let hashes = line.prefix(while: { $0 == "#" })
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = line.dropFirst(hashes.count)
        guard rest.first == " " else { return nil }
        return .heading(level: hashes.count, rest.trimmingCharacters(in: .whitespaces))
    }

    /// Three or more of the same of `-`, `*` or `_` alone on the line, spaces allowed between.
    private static func isRule(_ line: String) -> Bool {
        let marks = line.filter { $0 != " " }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    private static func listItem(in line: String, markers: [String]) -> String? {
        for marker in markers where line.hasPrefix(marker) {
            return line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func task(in item: String) -> AgentMarkdownTask? {
        for (box, isDone) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] where item.hasPrefix(box) {
            return AgentMarkdownTask(isDone: isDone, text: item.dropFirst(box.count).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private static func numberedItem(in line: String) -> String? {
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return rest.dropFirst(2).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Tables

    /// The cells of one pipe row, outer pipes dropped and `\|` kept as a pipe in its cell.
    private static func tableCells(in line: String) -> [String]? {
        var cells: [String] = []
        var cell = ""
        var escaped = false
        for character in line {
            if escaped {
                cell.append(character == "|" ? "|" : "\\\(character)")
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(cell)
                cell = ""
            } else {
                cell.append(character)
            }
        }
        if escaped { cell.append("\\") }
        cells.append(cell)
        if line.hasPrefix("|") { cells.removeFirst() }
        if line.hasSuffix("|"), !line.hasSuffix("\\|"), cells.count > 1 { cells.removeLast() }
        let trimmedCells = cells.map { $0.trimmingCharacters(in: .whitespaces) }
        return trimmedCells.isEmpty ? nil : trimmedCells
    }

    /// The delimiter row under a header: dashes per column, a colon on the side that aligns it.
    private static func tableAlignments(in line: String) -> [AgentMarkdownColumnAlignment]? {
        guard line.contains("-"), line.allSatisfy({ "-:| ".contains($0) }),
              let cells = tableCells(in: line) else {
            return nil
        }
        var alignments: [AgentMarkdownColumnAlignment] = []
        for cell in cells {
            let leading = cell.hasPrefix(":")
            let trailing = cell.hasSuffix(":") && cell.count > 1
            let dashes = cell.dropFirst(leading ? 1 : 0).dropLast(trailing ? 1 : 0)
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            switch (leading, trailing) {
            case (true, true): alignments.append(.center)
            case (false, true): alignments.append(.trailing)
            default: alignments.append(.leading)
            }
        }
        return alignments
    }
}

private extension Array where Element == String {
    /// A ragged row padded or cut to the header's width.
    func fitted(to width: Int) -> [String] {
        if count >= width { return Array(prefix(width)) }
        return self + Array(repeating: "", count: width - count)
    }
}
