import MyTermRemote
import MyTermUI
import SwiftUI

struct CompanionSettingsView: View {
    @Bindable var companion: CompanionHostModel
    @State private var connectionInput = ""
    @State private var isEditingConnection = false
    @State private var previousRelay = ""
    @State private var pairingLinkCopyError: String?
    @State private var diagnosticsError: String?
    @AppStorage(CompanionHostModel.collectConnectionLogKey) private var collectsConnectionLog = false

    private var showsLinkForm: Bool {
        !companion.hasLinkedRelay || isEditingConnection
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if showsLinkForm {
                SettingsCard("Link this Mac") {
                    TextField("Relay address or setup link", text: $connectionInput,
                              prompt: Text("Paste your relay address or setup link"))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Relay address or setup link")
                        .disabled(companion.isSigningIn || companion.status == .connecting)

                    Text("Use a setup link to create or recover your passkey. Otherwise, enter the relay address to sign in with an existing passkey.")
                        .font(Theme.Font.ui(12))
                        .foregroundStyle(Theme.textSecondary)

                    Button(companion.isSigningIn ? "Waiting for sign-in…" : companion.status == .connecting ? "Connecting…" : "Continue") {
                        let input = connectionInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        if (try? CompanionHostModel.parseBootstrapLink(input)) != nil {
                            companion.signIn(bootstrapURLText: input)
                        } else {
                            companion.relayText = input
                            companion.signIn()
                        }
                    }
                    .disabled(companion.isSigningIn || companion.status == .connecting || connectionInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if companion.isSigningIn {
                        Button("Cancel sign-in", role: .cancel) { companion.cancelSignIn() }
                    } else if companion.status == .connecting {
                        Button("Cancel connection", role: .cancel) { companion.disconnect() }
                    } else if companion.hasLinkedRelay && isEditingConnection {
                        Button("Cancel editing") {
                            companion.relayText = previousRelay
                            connectionInput = ""
                            isEditingConnection = false
                        }
                    }

                    if !companion.isSigningIn, case .failed = companion.status { statusLabel }
                }
            } else {
                SettingsCard("Relay") {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 16) {
                            relayDetails
                            Spacer(minLength: 12)
                            relayActions
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            relayDetails
                            relayActions
                        }
                    }
                    Text("Keep this Mac awake with MyTerm running so your phone can connect.")
                        .font(Theme.Font.ui(12))
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            if !showsLinkForm {
                SettingsCard("Pair a phone") {
                    HStack {
                        Button("Start Pair Mode") { companion.beginPairing() }
                            .disabled(
                                companion.status != .connected
                                    || companion.pairingQRCode != nil
                                    || companion.pendingPairing != nil
                            )
                        if companion.pairingQRCode != nil {
                            Button("Cancel") { companion.cancelPairing() }
                        }
                        Spacer()
                        if let refresh = companion.pairingRefreshesAt,
                           let expiry = companion.pairingExpiresAt {
                            Text("Refreshes \(refresh, style: .relative) · Link valid \(expiry, style: .relative)")
                                .font(Theme.Font.ui(12))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }

                    if let qr = companion.pairingQRCode {
                        VStack(alignment: .leading, spacing: 8) {
                            Image(nsImage: qr)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 132, height: 132)
                                .accessibilityLabel("Pairing QR code")
                            Button("Copy pairing link", systemImage: "doc.on.doc") {
                                do { try companion.copyPairingLink() }
                                catch { pairingLinkCopyError = error.localizedDescription }
                            }
                            .accessibilityHint("Copies the current one-use pairing link")
                        }
                    }

                    Text("The QR code refreshes every 30 seconds. Each one-use link remains valid for 60 seconds, so a scan can finish while the next code is shown. The relay never receives the secret. You must approve the phone on this Mac before it becomes trusted.")
                        .font(Theme.Font.ui(12))
                        .foregroundStyle(Theme.textSecondary)
                }

                SettingsCard("Paired phones", insetRows: false) {
                    if companion.pairedPeers.isEmpty {
                        Text("No phones paired")
                            .foregroundStyle(Theme.textSecondary)
                            .padding(16)
                    } else {
                        ForEach(companion.pairedPeers, id: \.deviceID) { peer in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(peer.name)
                                    Text("Paired \(peer.pairedAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption)
                                        .foregroundStyle(Theme.textSecondary)
                                }
                                Spacer()
                                Button("Revoke", role: .destructive) { companion.revoke(peer: peer) }
                                    .accessibilityLabel("Revoke \(peer.name)")
                            }
                            .padding(.vertical, 14)
                            .padding(.horizontal, 16)
                            if peer.deviceID != companion.pairedPeers.last?.deviceID {
                                Rectangle().fill(Theme.hairline).frame(height: 1)
                            }
                        }
                    }
                }

                if let diagnostics = companion.diagnosticsDirectory {
                    SettingsCard("Diagnostics") {
                        Toggle("Record this Mac's connection", isOn: $collectsConnectionLog)
                            .onChange(of: collectsConnectionLog) { _, enabled in
                                Task { await CompanionConnectionLog.shared.setEnabled(enabled) }
                            }
                        Text("Logs when this Mac connects, reconnects and loses its relay "
                             + "connection, and how large a terminal's checkpoint was. It never "
                             + "records terminal output.")
                            .font(Theme.Font.ui(12))
                            .foregroundStyle(Theme.textSecondary)
                        HStack {
                            Text("This Mac's log is filed beside what paired devices send.")
                                .font(Theme.Font.ui(12))
                                .foregroundStyle(Theme.textSecondary)
                            Spacer()
                            Button("Show in Finder") {
                                do {
                                    try FileManager.default.createDirectory(
                                        at: diagnostics, withIntermediateDirectories: true
                                    )
                                    NSWorkspace.shared.activateFileViewerSelecting([diagnostics])
                                } catch {
                                    diagnosticsError = error.localizedDescription
                                }
                            }
                        }
                    }
                }
                if !companion.remoteControllers.isEmpty {
                    SettingsCard("Remote control") {
                        ForEach(companion.remoteControllers) { controller in
                            HStack {
                                Text("\(controller.deviceName) controls a terminal")
                                Spacer()
                                Button("Take Control") {
                                    companion.takeControl(sessionID: controller.sessionID)
                                }
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            if connectionInput.isEmpty { connectionInput = companion.relayText }
        }
        .onChange(of: companion.status) { _, status in
            if status == .connected {
                connectionInput = ""
                isEditingConnection = false
            }
        }
        .alert(
            "Pair this phone?",
            isPresented: Binding(
                get: { companion.pendingPairing != nil },
                set: { if !$0 { companion.answerPairing(approved: false) } }
            ),
            presenting: companion.pendingPairing
        ) { _ in
            Button("Pair") { companion.answerPairing(approved: true) }
            Button("Cancel", role: .cancel) { companion.answerPairing(approved: false) }
        } message: { prompt in
            Text("Allow \(prompt.deviceName) to access this Mac through the configured relay?")
        }
        .alert("Diagnostics could not be opened", isPresented: Binding(
            get: { diagnosticsError != nil },
            set: { if !$0 { diagnosticsError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(diagnosticsError ?? "")
        }
        .alert(
            "Pairing link could not be copied",
            isPresented: Binding(
                get: { pairingLinkCopyError != nil },
                set: { if !$0 { pairingLinkCopyError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(pairingLinkCopyError ?? "")
        }
    }

    private var relayDetails: some View {
        VStack(alignment: .leading, spacing: 6) {
            statusLabel
            Text(companion.relayText)
                .font(Theme.Font.mono(12))
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
        }
    }

    private var relayActions: some View {
        HStack {
            Button("Change relay or recover passkey…") {
                previousRelay = companion.relayText
                connectionInput = companion.relayText
                isEditingConnection = true
            }
            .disabled(companion.isSigningIn || companion.status == .connecting)
            if companion.isSigningIn {
                Button("Cancel sign-in", role: .cancel) { companion.cancelSignIn() }
            } else if companion.status == .connecting {
                Button("Cancel connection", role: .cancel) { companion.disconnect() }
            } else if companion.status == .connected {
                Button("Disconnect") { companion.disconnect() }
            } else {
                Button(companion.needsSignIn ? "Sign in again" : "Reconnect") { companion.connect() }
            }
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch companion.status {
        case .notConfigured: Label("Not configured", systemImage: "circle")
        case .signedOut: Label("Signed out", systemImage: "person.crop.circle.badge.xmark")
        case .signInRequired(let reason):
            Label("Sign in required", systemImage: "person.crop.circle.badge.xmark")
                .foregroundStyle(.orange)
            Text(reason.message)
                .font(Theme.Font.ui(12))
                .foregroundStyle(Theme.textSecondary)
        case .disconnected: Label("Disconnected", systemImage: "network.slash")
        case .connecting: Label("Connecting", systemImage: "arrow.triangle.2.circlepath")
        case .connected:
            HStack(spacing: 7) {
                Circle().fill(Theme.success).frame(width: 8, height: 8).accessibilityHidden(true)
                Text("Connected")
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }
}
