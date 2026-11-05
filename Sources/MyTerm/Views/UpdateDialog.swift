import SwiftUI
import MyTermCore

/// A model-owned window keeps installation and a scheduled restart alive when other windows close.
struct UpdateDialog: View {
    let model: AppModel
    let release: AppRelease
    let close: () -> Void
    @State private var advanced = false

    private var updates: UpdateController { model.updates }
    private var installation: UpdateController.Installation { updates.installation(for: release) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label("Update available — \(release.version.description)", systemImage: "arrow.down.circle")
                    .font(.title2)
                Text("You’re running \(updates.currentVersion) (\(updates.installedChannel.title)). The \(release.channel.title) update is verified before installation.")
                    .foregroundStyle(.secondary)

                installationStatus
                if updates.isPreparingRestart { ProgressView("Verifying update before restart…") }

                if updates.needsStableConfigurationChoice {
                    Picker("When returning to stable", selection: Binding(
                        get: { updates.stableConfigurationChoice }, set: { updates.stableConfigurationChoice = $0 }
                    )) {
                        Text("Restore last stable configuration").tag(ChannelConfigurationStore.StableChoice.restoreStable)
                            .disabled(!updates.hasStableConfiguration)
                        Text("Try current beta configuration").tag(ChannelConfigurationStore.StableChoice.tryBeta)
                    }
                    .disabled(installation == .running)
                    if updates.hasStableConfiguration {
                        Text("If stable cannot load the beta configuration, it restores your last stable snapshot and explains what happened. The beta configuration is preserved as a backup.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if !updates.hasStableConfiguration {
                        Text("This beta installation has no stable snapshot. The incoming stable app must be able to read the current configuration before installation; automatic fallback to a previous stable configuration is unavailable.")
                            .foregroundStyle(.orange)
                    }
                }

                DisclosureGroup("Advanced", isExpanded: $advanced) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Restart when every hook-connected agent has finished its turn. Agents waiting for input keep the restart paused. Agents without hooks cannot report whether they’re idle.")
                            .font(.callout).foregroundStyle(.secondary)
                        let count = model.updateRestartBlockingAgentCount
                        Text("\(count) \(count == 1 ? "agent" : "agents") still working or waiting for input.")
                        if let warning = model.updateRestartRecoveryWarning {
                            Text(warning).foregroundStyle(.orange)
                        }
                        if installation == .installed {
                            Button(model.waitsToRestartAfterUpdate ? "Cancel Scheduled Restart" : "Restart When Agents Are Idle") {
                                if model.waitsToRestartAfterUpdate { model.cancelUpdateRestart() }
                                else { model.waitToRestartAfterUpdate() }
                            }
                            .disabled(!model.waitsToRestartAfterUpdate && model.updateRestartRecoveryWarning != nil)
                        }
                        if !updates.installationOutput.isEmpty {
                            ScrollView {
                                Text(updates.installationOutput)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(height: 180)
                            .padding(8)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                            .accessibilityLabel("Update log")
                        }
                    }.padding(.top, 8)
                }
                if installation == .installed, let warning = model.updateRestartRecoveryWarning {
                    Text(warning).font(.callout).foregroundStyle(.orange)
                }
                if let error = model.updateRestartError {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
                if installation != .installed, updates.canRestartAfterUpdate,
                   let installed = updates.verifiedInstalledVersion {
                    HStack {
                        Text("Version \(installed.description) is ready to restart.").font(.callout)
                        Button("Restart Installed Update") { model.restartAfterUpdate() }
                    }
                }
                HStack {
                    Link("Release Notes", destination: release.releaseURL)
                    if installation != .installed {
                        Button("Skip This Version") {
                            updates.skip(release)
                            close()
                        }
                        .disabled(installation == .running)
                    }
                    Spacer()
                    Button("Later", action: close)
                        .keyboardShortcut(.cancelAction)
                        .disabled(installation == .running || model.waitsToRestartAfterUpdate || updates.isPreparingRestart)
                    if installation == .installed {
                        Button("Restart Now") { model.restartAfterUpdate() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(updates.isPreparingRestart)
                    } else {
                        Button(installation == .ready ? "Update Now" : "Try Again") {
                            Task { await model.prepareUpdate(release) }
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(installation == .running || (updates.needsStableConfigurationChoice && updates.stableConfigurationChoice == .restoreStable && !updates.hasStableConfiguration))
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 568, minHeight: 300)
    }

    @ViewBuilder private var installationStatus: some View {
        switch installation {
        case .ready:
            Text("Your workspace is saved before restart. Persistent terminal sessions keep running and reconnect after the update.")
                .font(.callout)
        case .running:
            HStack {
                ProgressView().controlSize(.small)
                Text("Preparing update…")
            }
            Text(updates.installationOutput.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).last.map(String.init) ?? "Starting update…")
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
        case .installed:
            Label("Update ready. Restart to finish.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            if model.waitsToRestartAfterUpdate {
                Text("Waiting for agents to finish. You can keep using myterm, cancel the scheduled restart, or restart now.")
            } else {
                Text("The verified update is applied after myterm quits. Persistent terminals continue running while the app restarts.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        case .failed(let reason):
            Text(reason).foregroundStyle(.red).textSelection(.enabled)
        }
    }
}
