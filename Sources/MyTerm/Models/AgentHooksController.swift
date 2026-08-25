import Foundation
import MyTermCore
import Observation

/// One event an agent reports, and what MyTerm makes of it.
struct AgentHookEvent: Sendable {
    /// The agent's own name for the event, which is the key its hooks file is organised by.
    let name: String
    let activity: AgentActivity
    /// Text in the agent's own hook payload that means this report is not worth passing on.
    ///
    /// The payload arrives on the hook's standard input, and it is the only thing that separates
    /// two different things an agent reports under one event name.
    let ignoredMessage: String?

    init(_ name: String, _ activity: AgentActivity, ignoring ignoredMessage: String? = nil) {
        self.name = name
        self.activity = activity
        self.ignoredMessage = ignoredMessage
    }
}

/// One agent MyTerm installs hooks for, and where that agent keeps them.
///
/// Codex reads the same hook format Claude Code does, from its own file, so one controller serves
/// both. Only the path, the event names, and the name the agent reports itself under differ.
struct AgentHookTarget: Equatable, Sendable {
    /// Lowercased, because it travels in the report and the parser lowercases what it reads.
    let agent: String
    let displayName: String
    /// The path as a person would type it, for Settings to show.
    let fileDescription: String
    let settingsURL: URL
    /// Each event MyTerm listens to, and the activity it reports.
    let events: [AgentHookEvent]

    static func == (lhs: AgentHookTarget, rhs: AgentHookTarget) -> Bool {
        lhs.agent == rhs.agent && lhs.settingsURL == rhs.settingsURL
    }

    static let claude = AgentHookTarget(
        agent: "claude",
        displayName: "Claude Code",
        fileDescription: "~/.claude/settings.json",
        settingsURL: FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/settings.json", directoryHint: .notDirectory),
        events: [
            AgentHookEvent("UserPromptSubmit", .working),
            AgentHookEvent("Stop", .finished),
            // Claude Code sends `Notification` for a question it cannot go on without, and again
            // for a prompt left alone for a minute. The second is nothing to answer, and it arrives
            // after every finished turn, so passing it on would leave the cook purple for good.
            AgentHookEvent("Notification", .awaitingInput, ignoring: "waiting for your input"),
        ]
    )

    /// Codex calls the same three things by two of the same names and one of its own.
    static let codex = AgentHookTarget(
        agent: "codex",
        displayName: "Codex",
        fileDescription: "~/.codex/hooks.json",
        settingsURL: FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".codex/hooks.json", directoryHint: .notDirectory),
        events: [
            AgentHookEvent("UserPromptSubmit", .working),
            AgentHookEvent("Stop", .finished),
            AgentHookEvent("PermissionRequest", .awaitingInput),
        ]
    )

    func writing(to url: URL) -> AgentHookTarget {
        AgentHookTarget(
            agent: agent,
            displayName: displayName,
            fileDescription: fileDescription,
            settingsURL: url,
            events: events
        )
    }
}

/// Installs the agent hooks that report agent activity to MyTerm.
///
/// The hooks write `AgentActivityMarker`'s escape sequence to the pane's TTY. They are guarded by
/// `MYTERM_PANE_ID`, which only MyTerm's terminals carry, so the same agent configuration stays
/// silent in every other terminal.
@MainActor
@Observable
final class AgentHooksController {
    enum State: Equatable {
        case notInstalled
        /// MyTerm's own hooks are in the file, but an older MyTerm wrote them.
        case outdated
        case installed
        case failed(String)
    }

    /// Marks the commands this app owns, so removal never touches a hook somebody else wrote.
    /// Agents keep these files shared: other tools install their own hooks alongside MyTerm's.
    static let marker = "# myterm-managed-hook"

    let target: AgentHookTarget
    private var settingsURL: URL { target.settingsURL }
    private(set) var state: State = .notInstalled

    init(target: AgentHookTarget = .claude) {
        self.target = target
        refresh()
    }

    /// Used by tests, which point the Claude target at a file of their own.
    init(settingsURL: URL) {
        target = AgentHookTarget.claude.writing(to: settingsURL)
        refresh()
    }

    var isInstalled: Bool { state == .installed }

    func refresh() {
        do {
            let settings = try readSettings()
            if currentEvents(in: settings).count == target.events.count {
                state = .installed
            } else {
                state = installedEvents(in: settings).isEmpty ? .notInstalled : .outdated
            }
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
                        "command": Self.command(
                            agent: target.agent,
                            activity: event.activity,
                            ignoring: event.ignoredMessage
                        ),
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

    /// The shell one hook runs. It reports to the pane's TTY and never writes to stdout, which
    /// Claude Code reads as the hook's own JSON reply.
    ///
    /// An ignored message is matched against the agent's own payload, which the agent pipes to the
    /// hook. Reading that input is the only way to tell a question from a prompt left sitting, and
    /// a hook with nothing to ignore never reads it. The installed entry carries a five second
    /// timeout, so an agent that pipes nothing cannot leave the read waiting.
    static func command(
        agent: String,
        activity: AgentActivity,
        ignoring ignoredMessage: String? = nil
    ) -> String {
        let payload = "agent=\(agent);event=\(activity.rawValue)"
        let filter = Self.stdinFilter(ignoring: ignoredMessage)
        return """
        [ -n "${MYTERM_PANE_ID:-}" ] && { \(filter)__tty=$(ps -o tty= -p "$PPID" 2>/dev/null | tr -d '[:space:]'); \
        case "$__tty" in *[0-9]*) __tty="/dev/${__tty#/dev/}";; *) __tty="/dev/tty";; esac; \
        printf '\\033]\(AgentActivityMarker.oscCode);\(payload)\\033\\\\' > "$__tty"; } >/dev/null 2>&1 || true \(marker)
        """
    }

    /// The guard that drops a report the agent's own payload says is not worth passing on.
    ///
    /// The payload is read from standard input, which is where the agent pipes it. A hook with
    /// nothing to ignore gets no guard at all, so it never reads its input.
    static func stdinFilter(ignoring ignoredMessage: String?) -> String {
        guard let ignoredMessage else { return "" }
        return "case \"$(cat)\" in *'\(ignoredMessage)'*) exit 0;; esac; "
    }

    /// Events carrying a hook of MyTerm's, whichever version of MyTerm wrote it.
    func installedEvents(in settings: [String: Any]) -> [String] {
        guard let hooks = settings["hooks"] as? [String: Any] else { return [] }
        return target.events.compactMap { event in
            let entries = (hooks[event.name] as? [[String: Any]]) ?? []
            let hasMyTermCommand = entries.contains { entry in
                Self.commands(in: entry).contains { $0.hasSuffix(Self.marker) }
            }
            return hasMyTermCommand ? event.name : nil
        }
    }

    /// Events carrying the hook this version of MyTerm writes.
    ///
    /// A hook an older MyTerm wrote still carries the mark, so the mark alone cannot say whether
    /// the file is current. What the hook reports changes between versions, and a file left on the
    /// old command keeps reporting the old way, so the whole command is what gets compared.
    func currentEvents(in settings: [String: Any]) -> [String] {
        guard let hooks = settings["hooks"] as? [String: Any] else { return [] }
        return target.events.compactMap { event in
            let expected = Self.command(
                agent: target.agent,
                activity: event.activity,
                ignoring: event.ignoredMessage
            )
            let entries = (hooks[event.name] as? [[String: Any]]) ?? []
            let isCurrent = entries.contains { Self.commands(in: $0).contains(expected) }
            return isCurrent ? event.name : nil
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
