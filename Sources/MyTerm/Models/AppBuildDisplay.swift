import Foundation
import MyTermCore

/// User-facing labels for the numeric bundle versions used by the updater.
enum AppBuildDisplay {
    /// Identify main snapshots explicitly while retaining their immutable source counter.
    static func version(_ rawVersion: String, channel: UpdateCheck.Channel) -> String {
        let value = rawVersion.isEmpty ? "unknown" : rawVersion
        guard channel == .beta else { return value }
        if let version = AppVersion(rawVersion), version.components.count == 3,
           version.components[0] == 0, version.components[1] == 0 {
            return "Beta · main \(version.components[2])"
        }
        return "Beta \(value)"
    }

    /// Include the channel and build metadata beside the installed version in Settings.
    static func installed(_ rawVersion: String, channel: UpdateCheck.Channel, build: String) -> String {
        let label = version(rawVersion, channel: channel)
        if channel == .beta {
            return build.isEmpty ? label : "\(label) (build \(build))"
        }
        return "\(label) (\(channel.title))"
    }
}
