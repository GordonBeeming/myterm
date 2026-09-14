import Foundation
import MyTermRemoteProtocol

/// Reads what a screen-only command drew, once the screen has stopped changing.
///
/// `/usage`, `/status` and `/help` write nothing to the transcript. Their answer is a dialog on
/// the grid, and the grid is the only place it can be read from. Two things make that reading a
/// matter of timing rather than a single look:
///
/// - The dialog is not there when the Return goes in. Against the CLI it finishes drawing 300 to
///   500 ms later, so a read straight after the Return would find the prompt, or half a dialog.
/// - Nothing announces that it has finished. The only sign is that the screen stops changing, so
///   the read waits for two looks in a row to agree, and gives up when they never do: a screen
///   that keeps changing has a spinner on it, not a dialog.
///
/// The clock and the screen are both passed in, so the rule can be tested without a terminal or
/// a wait.
enum AgentScreenCapture {
    /// How long the dialog gets before the first look. Measured against the CLI: the three
    /// dialogs finish drawing 300 to 500 ms after the Return.
    static let minimumWait: Duration = .milliseconds(500)
    static let pollInterval: Duration = .milliseconds(100)
    /// The most a screen is watched. Past this it is animating, and there is no dialog to read.
    static let maximumWait: Duration = .seconds(2)

    /// The rows once two consecutive reads agree, or nothing when they never did in time.
    ///
    /// `before` is the screen as it stood when the wait began, and a settled screen equal to it
    /// does not count: a dialog slow to draw leaves that screen standing still, and still is not
    /// the same as done. Passing nothing accepts whatever settles, which is the question after an
    /// Escape, where a screen that has not moved is the answer.
    ///
    /// `read` returns nil when the tab is gone, which ends the wait the same way. On the main
    /// actor because that is where the screen is read.
    @MainActor
    static func settledRows(
        changedFrom before: [String]? = nil,
        read: () -> [String]?,
        sleep: (Duration) async throws -> Void
    ) async -> [String]? {
        do {
            try await sleep(minimumWait)
            var elapsed = minimumWait
            guard var previous = read() else { return nil }
            while elapsed < maximumWait {
                try await sleep(pollInterval)
                elapsed += pollInterval
                guard let current = read() else { return nil }
                if current == previous, current != before { return current }
                previous = current
            }
            return nil
        } catch {
            return nil
        }
    }

    /// The rows as a device shows them.
    ///
    /// Blank rows at either end are the terminal's height, not the dialog's; a run of them inside
    /// is the same, and one is kept so what it separated stays apart. The indentation every row
    /// shares is the dialog's margin, which a phone's width cannot afford.
    static func trimmed(_ rows: [String]) -> [String] {
        var kept: [String] = []
        for row in rows {
            let trimmedRow = trailingTrimmed(row)
            if trimmedRow.isEmpty {
                // Dropped at the front, and collapsed elsewhere.
                if let last = kept.last, !last.isEmpty { kept.append("") }
                continue
            }
            kept.append(trimmedRow)
        }
        while kept.last?.isEmpty == true { kept.removeLast() }
        guard !kept.isEmpty else { return [] }

        let margin = kept
            .filter { !$0.isEmpty }
            .map { $0.prefix { $0 == " " }.count }
            .min() ?? 0
        guard margin > 0 else { return kept }
        return kept.map { $0.isEmpty ? $0 : String($0.dropFirst(margin)) }
    }

    /// What goes on the wire as the command's output: the trimmed rows as one text, cut to the
    /// same cap as any other block.
    static func output(from rows: [String]) -> String {
        AgentTranscriptReader.cut(
            trimmed(rows).joined(separator: "\n"),
            to: RemoteAgentLimits.maximumBlockCharacters
        ).text
    }

    /// Whether a dialog read earlier is still what the screen shows.
    ///
    /// Judged by how many of the dialog's rows are still there, rather than by equality: a dialog
    /// can carry a figure that moves, such as a duration, and one changed row must not read as the
    /// dialog having gone. Once it has gone, the prompt that replaces it shares a few rows of
    /// banner with the dialog at most.
    static func stillShows(_ dialog: [String], on rows: [String]) -> Bool {
        let wanted = Set(dialog.map(trailingTrimmed).filter { !$0.isEmpty })
        guard !wanted.isEmpty else { return false }
        let present = Set(rows.map(trailingTrimmed).filter { !$0.isEmpty })
        let kept = wanted.intersection(present).count
        return kept * 4 >= wanted.count * 3
    }

    private static func trailingTrimmed(_ row: String) -> String {
        var text = Substring(row)
        while let last = text.last, last == " " || last == "\t" { text.removeLast() }
        return String(text)
    }
}
