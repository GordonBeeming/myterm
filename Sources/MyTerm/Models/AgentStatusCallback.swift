import Foundation

/// Antigravity reports permission dialogs through its status callback rather than a hook.
/// Keep the prior object inside the managed object so removal can restore every option.
enum AgentStatusCallback {
    static let marker = "# myterm-managed-status"
    private static let originalKey = "mytermOriginalStatusLine"

    static func isInstalled(at url: URL) throws -> Bool {
        let settings = try read(url)
        guard let status = settings["statusLine"] as? [String: Any],
              let command = status["command"] as? String else { return false }
        return command.hasSuffix(marker) && status["enabled"] as? Bool != false
    }

    static func install(at url: URL) throws {
        var settings = try read(url)
        let current = settings["statusLine"]
        if let current, !(current is [String: Any]) {
            throw AgentHooksFailure(message: "Antigravity statusLine must be a JSON object before MyTerm can preserve it.")
        }
        let status = current as? [String: Any] ?? [:]
        let managed = (status["command"] as? String)?.hasSuffix(marker) == true
        let original: Any = managed ? (status[originalKey] ?? NSNull()) : (current ?? NSNull())
        let prior = original as? [String: Any] ?? [:]
        let priorCommand = prior["enabled"] as? Bool == false ? "" : (prior["command"] as? String ?? "")
        let quoted = "'" + priorCommand.replacingOccurrences(of: "'", with: "'\\''") + "'"
        var installed = prior
        installed["type"] = "command"
        installed["enabled"] = true
        if priorCommand.isEmpty { installed["stack_with_default"] = true }
        installed[originalKey] = original
        installed["command"] = """
        if [ -r "${MYTERM_RESOURCE_DIR:-}/myterm-antigravity-status" ]; then /bin/sh "$MYTERM_RESOURCE_DIR/myterm-antigravity-status" \(quoted); else /bin/sh -c \(quoted); fi \(marker)
        """
        settings["statusLine"] = installed
        try write(settings, to: url)
    }

    static func remove(at url: URL) throws {
        var settings = try read(url)
        guard let status = settings["statusLine"] as? [String: Any],
              (status["command"] as? String)?.hasSuffix(marker) == true else { return }
        let original = status[originalKey]
        settings["statusLine"] = original is NSNull ? nil : original
        try write(settings, to: url)
    }

    private static func read(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [:] }
        guard let settings = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentHooksFailure(message: "Antigravity settings must be a JSON object.")
        }
        return settings
    }

    private static func write(_ settings: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url.resolvingSymlinksInPath(), options: .atomic)
    }
}
