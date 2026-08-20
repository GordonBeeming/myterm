import Foundation
import MyTermCore
import Observation

/// Installs the Claude Code hooks that report agent activity to MyTerm.
///
/// The hooks write `AgentActivityMarker`'s escape sequence to the pane's TTY. They are guarded by
/// `MYTERM_PANE_ID`, which only MyTerm's terminals carry, so the same Claude configuration stays
/// silent in every other terminal.
@MainActor
@Observable
final class AgentHooksController {
    enum State: Equatable {
        case notInstalled
        case installed
        case failed(String)
    }

    /// Marks the commands this app owns, so removal never touches a hook somebody else wrote.
    static let marker = "# myterm-managed-hook"

    /// Each Claude Code event MyTerm listens to, and the activity it reports.
    static let hookedEvents: [(event: String, activity: AgentActivity)] = [
        ("UserPromptSubmit", .working),
        ("Stop", .finished),
        ("Notification", .awaitingInput),
    ]

    private let settingsURL: URL
    private(set) var state: State = .notInstalled

    init(settingsURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".claude/settings.json", directoryHint: .notDirectory)) {
        self.settingsURL = settingsURL
        refresh()
    }

    var isInstalled: Bool { state == .installed }

    func refresh() {
        do {
            let settings = try readSettings()
            state = Self.installedEvents(in: settings).count == Self.hookedEvents.count ? .installed : .notInstalled
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func install() {
        do {
            var settings = try readSettings()
            var hooks = settings["hooks"] as? [String: Any] ?? [:]
            for (event, activity) in Self.hookedEvents {
                var entries = Self.entriesWithoutMyTerm(hooks[event])
                entries.append([
                    "hooks": [[
                        "type": "command",
                        "command": Self.command(for: activity),
                        "timeout": 5,
                    ]],
                ])
                hooks[event] = entries
            }
            settings["hooks"] = hooks
            try writeSettings(settings)
            state = .installed
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func remove() {
        do {
            var settings = try readSettings()
            guard var hooks = settings["hooks"] as? [String: Any] else {
                state = .notInstalled
                return
            }
            for (event, _) in Self.hookedEvents {
                let entries = Self.entriesWithoutMyTerm(hooks[event])
                // Dropping the key entirely keeps the file as it was before MyTerm touched it.
                if entries.isEmpty {
                    hooks.removeValue(forKey: event)
                } else {
                    hooks[event] = entries
                }
            }
            if hooks.isEmpty {
                settings.removeValue(forKey: "hooks")
            } else {
                settings["hooks"] = hooks
            }
            try writeSettings(settings)
            state = .notInstalled
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// The shell one hook runs. It reports to the pane's TTY and never writes to stdout, which
    /// Claude Code reads as the hook's own JSON reply.
    static func command(for activity: AgentActivity) -> String {
        let payload = "agent=claude;event=\(activity.rawValue)"
        return """
        [ -n "${MYTERM_PANE_ID:-}" ] && { __tty=$(ps -o tty= -p "$PPID" 2>/dev/null | tr -d '[:space:]'); \
        case "$__tty" in *[0-9]*) __tty="/dev/${__tty#/dev/}";; *) __tty="/dev/tty";; esac; \
        printf '\\033]\(AgentActivityMarker.oscCode);\(payload)\\033\\\\' > "$__tty"; } >/dev/null 2>&1 || true \(marker)
        """
    }

    static func installedEvents(in settings: [String: Any]) -> [String] {
        guard let hooks = settings["hooks"] as? [String: Any] else { return [] }
        return hookedEvents.compactMap { event, _ in
            let entries = (hooks[event] as? [[String: Any]]) ?? []
            let hasMyTermCommand = entries.contains { entry in
                commands(in: entry).contains { $0.hasSuffix(marker) }
            }
            return hasMyTermCommand ? event : nil
        }
    }

    private static func entriesWithoutMyTerm(_ value: Any?) -> [[String: Any]] {
        guard let entries = value as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard commands(in: entry).contains(where: { $0.hasSuffix(marker) }) else { return entry }
            let remaining = (entry["hooks"] as? [[String: Any]] ?? []).filter { hook in
                ((hook["command"] as? String) ?? "").hasSuffix(marker) == false
            }
            guard !remaining.isEmpty else { return nil }
            var kept = entry
            kept["hooks"] = remaining
            return kept
        }
    }

    private static func commands(in entry: [String: Any]) -> [String] {
        (entry["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
    }

    private func readSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        let data = try Data(contentsOf: settingsURL)
        guard !data.isEmpty else { return [:] }
        guard let settings = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentHooksFailure(message: "\(settingsURL.lastPathComponent) is not a JSON object.")
        }
        return settings
    }

    private func writeSettings(_ settings: [String: Any]) throws {
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: settingsURL, options: .atomic)
    }
}

struct AgentHooksFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
