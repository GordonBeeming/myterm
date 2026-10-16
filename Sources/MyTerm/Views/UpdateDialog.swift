import SwiftUI
import MyTermCore

/// A model-owned window keeps installation and a scheduled restart alive when other windows close.
struct UpdateDialog: View {
    let model: AppModel
    let release: AppRelease
    let close: () -> Void
    @State private var advanced = false

    private var updates: UpdateController { model.updates }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Update available — \(release.version.description)", systemImage: "arrow.down.circle")
                .font(.title2)
            Text("You’re running \(updates.currentVersion). Homebrew installs the update in the background.")
                .foregroundStyle(.secondary)

            installationStatus

            DisclosureGroup("Advanced", isExpanded: $advanced) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Restart when every hook-connected agent has finished its turn. Agents waiting for input keep the restart paused. Agents without hooks cannot report whether they’re idle.")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("\(model.updateRestartBlockingAgentCount) agents still working or waiting for input.")
                    if let warning = model.updateRestartRecoveryWarning {
                        Text(warning).foregroundStyle(.orange)
                    }
                    if updates.installation == .installed {
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
                        .accessibilityLabel("Homebrew update log")
                    }
                }.padding(.top, 8)
            }
            if updates.installation == .installed, let warning = model.updateRestartRecoveryWarning {
                Text(warning).font(.callout).foregroundStyle(.orange)
            }
            if let error = model.updateRestartError {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Link("Release Notes", destination: release.releaseURL)
                if updates.installation != .installed {
                    Button("Skip This Version") {
                        updates.skip(release)
                        close()
                    }
                    .disabled(updates.installation == .running)
                }
                Spacer()
                Button("Later", action: close)
                    .keyboardShortcut(.cancelAction)
                    .disabled(updates.installation == .running || model.waitsToRestartAfterUpdate)
                if updates.installation == .installed {
                    Button("Restart Now") { model.restartAfterUpdate() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(updates.installation == .ready ? "Update Now" : "Try Again") {
                        Task { await updates.install(release: release) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(updates.installation == .running)
                }
            }
        }
        .padding(24)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var installationStatus: some View {
        switch updates.installation {
        case .ready:
            Text("Your tabs and resumable agent conversations are saved when myterm restarts. Restarting ends running terminal processes.")
                .font(.callout)
        case .running:
            HStack {
                ProgressView().controlSize(.small)
                Text("Installing with Homebrew…")
            }
            Text(updates.installationOutput.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).last.map(String.init) ?? "Starting update…")
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
        case .installed:
            Label("Update installed. Ready to restart.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            if model.waitsToRestartAfterUpdate {
                Text("Waiting for agents to finish. You can keep using myterm, cancel the scheduled restart, or restart now.")
            } else {
                Text("Resumable agent conversations reopen when session restoration is enabled. Restarting ends running terminal processes.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        case .failed(let reason):
            Text(reason).foregroundStyle(.red).textSelection(.enabled)
        }
    }
}
