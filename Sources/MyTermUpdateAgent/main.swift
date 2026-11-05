import Darwin
import Foundation
import MyTermCore
import MyTermUpdating

@main
struct MyTermUpdateAgent {
    @MainActor static func main() async {
        var recoveryPlan: ApplicationUpdatePlan?
        var parentExited = false
        do {
            #if DEBUG
            if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--test-running-code" {
                FileHandle.standardOutput.write(Data("ready\n".utf8))
                let gate = CommandLine.arguments[3]
                let deadline = ContinuousClock.now.advanced(by: .seconds(10))
                while !FileManager.default.fileExists(atPath: gate), ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                print(try ApplicationUpdate.runningCodeMatchesFile(URL(fileURLWithPath: CommandLine.arguments[2])) ? "same" : "replaced")
                return
            }
            #endif
            if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "--open-after-exit",
               let parent = Int32(CommandLine.arguments[2]), parent > 0 {
                let app = URL(fileURLWithPath: CommandLine.arguments[3])
                try ApplicationUpdate.verifyInstalledIdentity(app)
                try ApplicationUpdate.waitForExit(parent)
                try ApplicationUpdate.run("/usr/bin/open", ["-n", "-a", app.path] + Array(CommandLine.arguments.dropFirst(4)))
                return
            }
            if CommandLine.arguments.count == 5, CommandLine.arguments[1] == "--verify-configuration" {
                let directory = URL(fileURLWithPath: CommandLine.arguments[2])
                guard CommandLine.arguments[3] == ApplicationUpdate.bundleIdentifier else {
                    throw ApplicationUpdateError.invalid("Only the myterm configuration domain can be checked.")
                }
                let config = ChannelConfigurationStore(directory: directory, preferencesDomain: CommandLine.arguments[3])
                if CommandLine.arguments[4] == "stable-fallback" { try config.checkStableSnapshot() }
                else if CommandLine.arguments[4] == "current" { try config.checkStableCapture() }
                else { throw ApplicationUpdateError.invalid("Unknown configuration validation mode.") }
                print("Configuration is compatible with this app's decoder.")
                return
            }
            if CommandLine.arguments.count == 5, CommandLine.arguments[1] == "--verify-app",
               let channel = UpdateCheck.Channel(rawValue: CommandLine.arguments[4]) {
                try ApplicationUpdate.validate(URL(fileURLWithPath: CommandLine.arguments[2]),
                    version: CommandLine.arguments[3], channel: channel)
                print("Verified application signature, notarization, version, channel, and update helpers.")
                return
            }
            guard CommandLine.arguments.count == 3, let parent = Int32(CommandLine.arguments[2]), parent > 0 else {
                throw ApplicationUpdateError.invalid("Expected an update manifest and parent PID.")
            }
            let manifest = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
            let plan = try JSONDecoder().decode(ApplicationUpdatePlan.self, from: Data(contentsOf: manifest))
            try ApplicationUpdate.validatePlan(plan, manifest: manifest)
            if FileManager.default.fileExists(atPath: plan.directory.appendingPathComponent("superseded").path) { return }
            try ApplicationUpdate.verifyInstalledIdentity(plan.target)
            recoveryPlan = plan
            try ApplicationUpdate.waitForExit(parent)
            if FileManager.default.fileExists(atPath: plan.directory.appendingPathComponent("superseded").path) { return }
            parentExited = true
            let installationLock = try ApplicationUpdate.acquireInstallationLock(directory: plan.configurationDirectory)
            defer { flock(installationLock, LOCK_UN); close(installationLock) }
            try ApplicationUpdate.apply(plan)
            do { try Data("applied".utf8).write(to: plan.directory.appendingPathComponent("applied"), options: .atomic) }
            catch { FileHandle.standardError.write(Data(("Installed, but could not mark cleanup: \(error.localizedDescription)\n").utf8)) }
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            if parentExited, let plan = recoveryPlan {
                do {
                    try Data(("The update could not be installed. " + error.localizedDescription).utf8)
                        .write(to: plan.configurationDirectory.appendingPathComponent("update-install-error.txt"), options: .atomic)
                    try ApplicationUpdate.verifyInstalledIdentity(plan.target)
                    if plan.relaunch { try ApplicationUpdate.run("/usr/bin/open", ["-n", plan.target.path]) }
                } catch {
                    FileHandle.standardError.write(Data(("Could not reopen the preserved app: \(error.localizedDescription)\n").utf8))
                }
            }
            exit(1)
        }
    }
}
