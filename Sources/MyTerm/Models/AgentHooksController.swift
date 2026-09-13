import Foundation
import MyTermCore
import Observation

/// One agent MyTerm can install hooks for, and where that agent keeps them.
struct AgentHookTarget: Equatable, Sendable {
    /// Lowercased agent name. It travels in the report, and it decides the resume command.
    let agent: String
    let displayName: String
    /// The path to show in Settings, written the way a person would type it.
    let fileDescription: String
    let settingsURL: URL
    let events: [AgentHookEvent]

    static let claude = AgentHookTarget(
        agent: "claude",
        displayName: "Claude Code",
        fileDescription: "~/.claude/settings.json",
        settingsURL: FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/settings.json", directoryHint: .notDirectory),
        events: [
            AgentHookEvent(name: "SessionStart", activity: .ready),
            AgentHookEvent(name: "UserPromptSubmit", activity: .working),
            AgentHookEvent(name: "Stop", activity: .finished),
            AgentHookEvent(name: "Notification", activity: .awaitingInput),
            AgentHookEvent(name: "SessionEnd", activity: .exited),
        ]
    )

    static let codex = AgentHookTarget(
        agent: "codex",
        displayName: "Codex",
        fileDescription: "~/.codex/hooks.json",
        settingsURL: FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".codex/hooks.json", directoryHint: .notDirectory),
        events: [
            AgentHookEvent(name: "SessionStart", activity: .ready),
            AgentHookEvent(name: "UserPromptSubmit", activity: .working),
            AgentHookEvent(name: "Stop", activity: .finished),
            AgentHookEvent(name: "PermissionRequest", activity: .awaitingInput),
        ]
    )

    func withSettingsURL(_ url: URL) -> AgentHookTarget {
        AgentHookTarget(
            agent: agent,
            displayName: displayName,
            fileDescription: fileDescription,
            settingsURL: url,
            events: events
        )
    }
}

struct AgentHookEvent: Equatable, Sendable {
    let name: String
    let activity: AgentActivity
}

/// Installs the agent hooks that report agent activity, and agent session identity, to MyTerm.
///
/// The hooks write `AgentActivityMarker`'s escape sequence to the pane's TTY. They are guarded by
/// `MYTERM_PANE_ID`, which only MyTerm's terminals carry, so the same agent configuration stays
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

    let target: AgentHookTarget
    private(set) var state: State = .notInstalled

    init(target: AgentHookTarget = .claude) {
        self.target = target
        refresh()
    }

    init(settingsURL: URL) {
        target = AgentHookTarget.claude.withSettingsURL(settingsURL)
        refresh()
    }

    var isInstalled: Bool { state == .installed }

    /// Reads what is installed. A hook MyTerm wrote with an earlier text is reinstalled, so a
    /// guard added later reaches a settings file the user set up before it existed.
    func refresh() {
        do {
            let settings = try readSettings()
            if hasStaleHooks(in: settings) {
                install()
                return
            }
            state = installedEvents(in: settings).count == target.events.count ? .installed : .notInstalled
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func install() {
        do {
            var settings = try readSettings()
            var hooks = settings["hooks"] as? [String: Any] ?? [:]
            for event in target.events {
                var entries = Self.entriesWithoutMyTerm(hooks[event.name])
                entries.append([
                    "hooks": [[
                        "type": "command",
                        "command": Self.command(agent: target.agent, activity: event.activity),
                        "timeout": 5,
                    ]],
                ])
                hooks[event.name] = entries
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
            for event in target.events {
                let entries = Self.entriesWithoutMyTerm(hooks[event.name])
                // Dropping the key entirely keeps the file as it was before MyTerm touched it.
                if entries.isEmpty {
                    hooks.removeValue(forKey: event.name)
                } else {
                    hooks[event.name] = entries
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

    /// The shell one hook runs. It reports to the pane's TTY and never writes to stdout, which the
    /// agent reads as the hook's own JSON reply.
    ///
    /// The hook payload arrives on stdin. Reading `session_id` out of it is what lets MyTerm bring
    /// the same conversation back after a restart, and the character class is what keeps a hostile
    /// payload from reaching the command line that resumes it.
    ///
    /// A child session (`CLAUDE_CODE_CHILD_SESSION`: an agent another agent started in the same
    /// pane) inherits the pane's identifier but writes no transcript of its own, and it is not the
    /// conversation the pane is in. It stays silent, so its start cannot replace the pane's
    /// conversation and its end cannot discard it.
    static func command(agent: String, activity: AgentActivity) -> String {
        let idPattern = "s/.*\"session_id\"[[:space:]]*:[[:space:]]*\"\\([A-Za-z0-9._-]\\{1,64\\}\\)\".*/\\1/p"
        let payload = "agent=\(agent);event=\(activity.rawValue);session=%s"
        return """
        [ -n "${MYTERM_PANE_ID:-}" ] && [ -z "${CLAUDE_CODE_CHILD_SESSION:-}" ] && { __id=$(cat 2>/dev/null | tr -d '\\n' | sed -n '\(idPattern)'); \
        __tty=$(ps -o tty= -p "$PPID" 2>/dev/null | tr -d '[:space:]'); \
        case "$__tty" in *[0-9]*) __tty="/dev/${__tty#/dev/}";; *) __tty="/dev/tty";; esac; \
        printf '\\033]\(AgentActivityMarker.oscCode);\(payload)\\033\\\\' "$__id" > "$__tty"; \
        } >/dev/null 2>&1 || true \(marker)
        """
    }

    /// The events whose installed hook is the one this version writes.
    func installedEvents(in settings: [String: Any]) -> [String] {
        guard let hooks = settings["hooks"] as? [String: Any] else { return [] }
        return target.events.compactMap { event in
            let entries = (hooks[event.name] as? [[String: Any]]) ?? []
            let current = Self.command(agent: target.agent, activity: event.activity)
            let hasCurrentCommand = entries.contains { entry in
                Self.commands(in: entry).contains(current)
            }
            return hasCurrentCommand ? event.name : nil
        }
    }

    /// Whether any hook MyTerm wrote says something other than what this version writes.
    func hasStaleHooks(in settings: [String: Any]) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return target.events.contains { event in
            let entries = (hooks[event.name] as? [[String: Any]]) ?? []
            let current = Self.command(agent: target.agent, activity: event.activity)
            return entries.contains { entry in
                Self.commands(in: entry).contains { $0.hasSuffix(Self.marker) && $0 != current }
            }
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
        guard FileManager.default.fileExists(atPath: target.settingsURL.path) else { return [:] }
        let data = try Data(contentsOf: target.settingsURL)
        guard !data.isEmpty else { return [:] }
        guard let settings = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentHooksFailure(message: "\(target.settingsURL.lastPathComponent) is not a JSON object.")
        }
        return settings
    }

    private func writeSettings(_ settings: [String: Any]) throws {
        try FileManager.default.createDirectory(
            at: target.settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        // The file is the user's, and a dotfiles repo often owns it through a symlink. An atomic
        // write renames over the name it is given, which would replace the link with a copy, so
        // the write goes to whatever the link points at.
        try data.write(to: target.settingsURL.resolvingSymlinksInPath(), options: .atomic)
    }
}

struct AgentHooksFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
