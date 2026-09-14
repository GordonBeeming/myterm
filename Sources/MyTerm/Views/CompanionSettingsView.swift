import MyTermRemote
import SwiftUI

struct CompanionSettingsView: View {
    @Bindable var companion: CompanionHostModel
    @State private var bootstrapLink = ""

    var body: some View {
        Form {
            Section("Relay") {
                TextField("https://relay.example.com", text: $companion.relayText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Companion relay address")

                TextField("Bootstrap link (first registration only)", text: $bootstrapLink)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button(bootstrapLink.isEmpty ? "Sign In" : "Register and Sign In") {
                        companion.signIn(
                            bootstrapURLText: bootstrapLink.isEmpty ? nil : bootstrapLink
                        )
                    }
                    .disabled(companion.relayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("Connect") { companion.connect() }
                        .disabled(companion.status == .connecting || companion.status == .connected)
                    Button("Disconnect") { companion.disconnect() }
                        .disabled(companion.status != .connecting && companion.status != .connected)
                    Spacer()
                    statusLabel
                }

                Text("MyTerm connects only after you configure a relay and sign in. The Mac must remain awake with MyTerm running for the companion to connect.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Pair a phone") {
                HStack {
                    Button("Start Pair Mode") { companion.beginPairing() }
                        .disabled(companion.status != .connected)
                    if companion.pairingQRCode != nil {
                        Button("Cancel") { companion.cancelPairing() }
                    }
                    Spacer()
                    if let expiry = companion.pairingExpiresAt {
                        Text("Expires \(expiry, style: .relative)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if let qr = companion.pairingQRCode {
                    Image(nsImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 220, height: 220)
                        .accessibilityLabel("Pairing QR code")
                }

                Text("The QR code contains a one-use secret and expires after five minutes. The relay never receives that secret. You must approve the phone on this Mac before it becomes trusted.")
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
        .formStyle(.grouped)
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
