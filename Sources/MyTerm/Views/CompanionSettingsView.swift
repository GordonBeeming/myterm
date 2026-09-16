import MyTermRemote
import SwiftUI

struct CompanionSettingsView: View {
    @Bindable var companion: CompanionHostModel
    @State private var connectionInput = ""
    @State private var isEditingConnection = false
    @State private var previousRelay = ""
    @State private var pairingLinkCopyError: String?

    private var showsLinkForm: Bool {
        !companion.hasLinkedRelay || isEditingConnection
    }

    var body: some View {
        Form {
            if showsLinkForm {
                Section("Link this Mac") {
                    TextField("Relay address or setup link", text: $connectionInput,
                              prompt: Text("Paste your relay address or setup link"))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Relay address or setup link")
                        .disabled(companion.isSigningIn)

                    Text("Use a setup link to create or recover your passkey. Otherwise, enter the relay address to sign in with an existing passkey.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button(companion.isSigningIn ? "Waiting for sign-in…" : "Continue") {
                        let input = connectionInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        if (try? CompanionHostModel.parseBootstrapLink(input)) != nil {
                            companion.signIn(bootstrapURLText: input)
                        } else {
                            companion.relayText = input
                            companion.signIn()
                        }
                    }
                    .disabled(companion.isSigningIn || connectionInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if companion.isSigningIn {
                        Button("Cancel sign-in", role: .cancel) { companion.cancelSignIn() }
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
                Section("Relay") {
                    LabeledContent("Address", value: companion.relayText)
                    statusLabel
                    HStack {
                        if companion.status == .connected {
                            Button("Disconnect") { companion.disconnect() }
                        } else {
                            Button("Reconnect") { companion.connect() }
                                .disabled(companion.status == .connecting || companion.isSigningIn)
                        }
                        Button("Change relay or recover passkey…") {
                            previousRelay = companion.relayText
                            connectionInput = companion.relayText
                            isEditingConnection = true
                        }
                    }
                    Text("Keep this Mac awake with MyTerm running so your phone can connect.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if !showsLinkForm {
                Section("Pair a phone") {
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
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let qr = companion.pairingQRCode {
                        VStack(alignment: .leading, spacing: 8) {
                            Image(nsImage: qr)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 220, height: 220)
                                .accessibilityLabel("Pairing QR code")
                            Button("Copy pairing link", systemImage: "doc.on.doc") {
                                do { try companion.copyPairingLink() }
                                catch { pairingLinkCopyError = error.localizedDescription }
                            }
                            .accessibilityHint("Copies the current one-use pairing link")
                        }
                    }

                    Text("The QR code refreshes every 30 seconds. Each one-use link remains valid for 60 seconds, so a scan can finish while the next code is shown. The relay never receives the secret. You must approve the phone on this Mac before it becomes trusted.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Paired phones") {
                    if companion.pairedPeers.isEmpty {
                        Text("No phones paired")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(companion.pairedPeers, id: \.deviceID) { peer in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(peer.name)
                                    Text("Paired \(peer.pairedAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Revoke", role: .destructive) { companion.revoke(peer: peer) }
                            }
                        }
                    }
                }

                if !companion.remoteControllers.isEmpty {
                    Section("Remote control") {
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
        .formStyle(.grouped)
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

    @ViewBuilder
    private var statusLabel: some View {
        switch companion.status {
        case .notConfigured: Label("Not configured", systemImage: "circle")
        case .signedOut: Label("Signed out", systemImage: "person.crop.circle.badge.xmark")
        case .disconnected: Label("Disconnected", systemImage: "network.slash")
        case .connecting: Label("Connecting", systemImage: "arrow.triangle.2.circlepath")
        case .connected: Label("Connected", systemImage: "checkmark.circle.fill")
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }
}
