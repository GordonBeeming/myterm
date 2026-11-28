import MyTermRemote
import MyTermUI
import SwiftUI

struct CompanionSettingsView: View {
    @Bindable var companion: CompanionHostModel
    @State private var customRelayAddress = ""
    @State private var setupLink = ""
    @State private var relayChoice: CompanionRelayChoice?
    @State private var isEditingConnection = false
    @State private var pairingLinkCopyError: String?
    @State private var diagnosticsError: String?
    @State private var deviceToRevoke: PairedPeer?
    @AppStorage(CompanionHostModel.collectConnectionLogKey) private var collectsConnectionLog = false

    init(companion: CompanionHostModel) {
        _companion = Bindable(wrappedValue: companion)
        _collectsConnectionLog = AppStorage(
            wrappedValue: false, CompanionHostModel.collectConnectionLogKey, store: companion.connectionLogDefaults
        )
    }

    private var showsLinkForm: Bool {
        !companion.hasLinkedRelay || isEditingConnection
    }

    private var relayChoices: [CompanionRelayChoice] {
        CompanionRelayChoice.choices(channel: companion.channel, release: Bundle.main.releaseChannel)
    }

    private var selectedRelay: CompanionRelayChoice {
        relayChoice ?? CompanionRelayChoice.initial(savedAddress: companion.relayText, choices: relayChoices)
    }

    private var connectionInput: String {
        let value = switch selectedRelay {
        case .selfHosted: customRelayAddress
        case .setupLink: setupLink
        default: selectedRelay.origin ?? ""
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var connectionInProgress: Bool {
        companion.isSigningIn || companion.status == .connecting
    }

    private var canSubmit: Bool {
        guard !connectionInProgress, !connectionInput.isEmpty else { return false }
        if selectedRelay == .selfHosted {
            guard let url = URL(string: connectionInput) else { return false }
            return (try? RelayEndpoint(url)) != nil
        }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if showsLinkForm {
                SettingsCard("Link this Mac") {
                    Picker("Relay", selection: Binding(get: { selectedRelay }, set: { relayChoice = $0 })) {
                        ForEach(relayChoices, id: \.self) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(connectionInProgress)

                    switch selectedRelay {
                    case .selfHosted:
                        LabeledContent("Relay address") {
                            TextField("Relay address", text: $customRelayAddress, prompt: Text("https://relay.example.com"))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .modifier(SettingsFieldOutline())
                                .disabled(connectionInProgress)
                        }
                    case .setupLink:
                        LabeledContent("Setup link") {
                            SecureField("Setup link", text: $setupLink, prompt: Text("Paste your setup link"))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .modifier(SettingsFieldOutline())
                                .disabled(connectionInProgress)
                        }
                    default:
                        if let origin = selectedRelay.origin {
                            LabeledContent("Relay address") {
                                Text(origin)
                                    .font(Theme.Font.mono(12))
                                    .foregroundStyle(Theme.textSecondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }

                    Button(companion.isSigningIn ? "Waiting for sign-in…" : companion.status == .connecting ? "Connecting…" : selectedRelay == .setupLink ? "Open setup link" : "Sign in") {
                        if selectedRelay == .setupLink {
                            companion.signIn(bootstrapURLText: connectionInput)
                        } else {
                            companion.signIn(relayAddress: connectionInput)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)

                    Text("After signing in, show a pairing code to connect a device.")
                        .font(Theme.Font.ui(12))
                        .foregroundStyle(Theme.textSecondary)

                    if companion.isSigningIn {
                        Button("Cancel sign-in", role: .cancel) { companion.cancelSignIn() }
                    } else if companion.status == .connecting {
                        Button("Cancel connection", role: .cancel) { companion.disconnect() }
                    } else if companion.hasLinkedRelay && isEditingConnection {
                        Button("Cancel editing") {
                            setupLink = ""
                            loadRelaySelection()
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
                    Text("Keep this Mac awake with MyTerm running so your devices can connect.")
                        .font(Theme.Font.ui(12))
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            if !showsLinkForm {
                SettingsCard("Pair a device") {
                    HStack {
                        Button("Show pairing code") { companion.beginPairing() }
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

                    Text("Scan the code with the other device, then approve it on this Mac.")
                        .font(Theme.Font.ui(12))
                        .foregroundStyle(Theme.textSecondary)
                        .help("The code refreshes every 30 seconds. Each one-use link remains valid for 60 seconds.")
                }

                SettingsCard("Paired devices", insetRows: false) {
                    if companion.pairedPeers.isEmpty {
                        Text("No devices paired")
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
                                Button("Revoke", role: .destructive) { deviceToRevoke = peer }
                                    .accessibilityLabel("Revoke \(peer.name)")
                                    .help("Remove this device’s access to this Mac")
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
        .onAppear { if relayChoice == nil { loadRelaySelection() } }
        .onChange(of: companion.status) { _, status in
            if status == .connected {
                setupLink = ""
                loadRelaySelection()
                isEditingConnection = false
            }
        }
        .alert(
            "Pair this device?",
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
            "Revoke device access?",
            isPresented: Binding(
                get: { deviceToRevoke != nil },
                set: { if !$0 { deviceToRevoke = nil } }
            ),
            presenting: deviceToRevoke
        ) { peer in
            Button("Revoke", role: .destructive) { companion.revoke(peer: peer) }
            Button("Cancel", role: .cancel) {}
        } message: { peer in
            Text("\(peer.name) will need to pair again to access this Mac.")
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

    private func loadRelaySelection() {
        let selected = CompanionRelayChoice.initial(savedAddress: companion.relayText, choices: relayChoices)
        relayChoice = selected
        customRelayAddress = selected == .selfHosted ? companion.relayText : ""
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
                loadRelaySelection()
                isEditingConnection = true
            }
            .disabled(companion.isSigningIn || companion.status == .connecting)
            if companion.isSigningIn {
                Button("Cancel sign-in", role: .cancel) { companion.cancelSignIn() }
            } else if companion.status == .connecting {
                Button("Cancel connection", role: .cancel) { companion.disconnect() }
            } else if companion.status == .connected {
                Button("Disconnect") { companion.disconnect() }
                    .help("Pause relay access for all paired devices until you reconnect")
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
