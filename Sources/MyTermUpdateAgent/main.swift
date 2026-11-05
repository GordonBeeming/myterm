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
                try config.checkIncomingConfiguration(mode: CommandLine.arguments[4])
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
            if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--watch-trial" {
                let manifest = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
                let plan = try JSONDecoder().decode(ApplicationUpdatePlan.self, from: Data(contentsOf: manifest))
                try ApplicationUpdate.validatePlan(plan, manifest: manifest)
                guard UpdateStartupTrial.activeManifest(in: plan.configurationDirectory) == manifest,
                      let monitor = try UpdateStartupTrial.monitorLock(plan) else { return }
                defer { flock(monitor, LOCK_UN); close(monitor) }
                do {
                    try UpdateStartupTrial.waitForStartup(plan)
                    try UpdateStartupTrial.commit(plan)
                } catch {
                    try UpdateStartupTrial.stopUnconfirmedApp(plan)
                    let lock = try ApplicationUpdate.acquireInstallationLock(directory: plan.configurationDirectory)
                    defer { flock(lock, LOCK_UN); close(lock) }
                    if UpdateStartupTrial.readReceipt(plan)?.phase == .loaded {
                        try UpdateStartupTrial.commit(plan)
                        return
                    }
                    let failure = error.localizedDescription
                    try UpdateStartupTrial.rollback(plan)
                    try Data(("The new app could not finish startup. Restored the previous app and configuration. " + failure).utf8)
                        .write(to: plan.configurationDirectory.appendingPathComponent("update-install-error.txt"), options: .atomic)
                    try ApplicationUpdate.run("/usr/bin/open", ["-n", plan.target.path])
                }
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
            var locked = true
            defer { if locked { flock(installationLock, LOCK_UN) }; close(installationLock) }
            let monitor = plan.relaunch ? try UpdateStartupTrial.monitorLock(plan) : nil
            if plan.relaunch, monitor == nil { throw ApplicationUpdateError.invalid("Another update startup monitor is active.") }
            defer { if let monitor { flock(monitor, LOCK_UN); close(monitor) } }
            try ApplicationUpdate.apply(plan, launch: { app in
                flock(installationLock, LOCK_UN)
                locked = false
                do {
                    try ApplicationUpdate.run("/usr/bin/open", ["-n", app.path])
                    try UpdateStartupTrial.waitForStartup(plan)
                } catch {
                    try UpdateStartupTrial.stopUnconfirmedApp(plan)
                    if flock(installationLock, LOCK_EX | LOCK_NB) == 0 {
                        locked = true
                        throw error
                    }
                    if UpdateStartupTrial.readReceipt(plan)?.phase == .loaded { return }
                    throw ApplicationUpdateError.rollbackDeferred("Could not safely roll back while another instance owns the profile. The previous app remains at \(plan.staged.path).")
                }
            })
            if plan.relaunch { try UpdateStartupTrial.commit(plan) }

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
