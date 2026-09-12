import MyTermRemoteProtocol
import SwiftUI
import UIKit

/// The device's entry point: pick a Mac that is already known, or add one, then hand off to the
/// live workspace list once `RemoteClient` reports it is connected.
///
/// This view also owns what happens when the connection goes away. A Mac that sleeps, a device
/// that leaves Wi-Fi, or an app that was in the background long enough for iOS to close the
/// socket all end the same way, and none of them should throw the user back to the list of Macs.
/// The screen stays, a banner says what is happening, and the device tries again on its own.
struct ConnectionView: View {
    /// The manual-entry fields, and the path launch arguments drive. Kept separate from the saved
    /// list so a one-off connection does not have to be saved to be tried.
    @AppStorage("remote.host") private var host = ""
    @AppStorage("remote.port") private var portText = ""
    /// Never `@AppStorage`: the token is the pre-shared key, and `SavedConnectionStore` keeps it in
    /// the Keychain for that reason. Read once from defaults so the `-remote.token` launch
    /// argument, which lives in the volatile argument domain, still reaches the manual path.
    @State private var token = Self.launchToken()
    /// A relay and rendezvous for the manual path. Launch arguments set these; the form does not.
    @AppStorage("remote.relay") private var relayText = ""
    @AppStorage("remote.rendezvous") private var rendezvousText = ""
    /// Reconnects to the last Mac without asking again. Off until the user turns it on, because a
    /// terminal that opens itself is not what someone handing over an iPad expects.
    @AppStorage("remote.reconnectsOnLaunch") private var reconnectsOnLaunch = false
    /// A tab to open as soon as the tree arrives. Cleared once used. A tapped banner writes it
    /// too, which is how a tap lands on the tab whether the app was running or not.
    @AppStorage("remote.openTab") private var openTab = ""
    @State private var store: RemoteSessionStore
    private let notifier: AgentNotifier
    @State private var connections = SavedConnectionStore()
    @State private var nearby = MacBrowser()
    @State private var path = NavigationPath()
    /// The split layout's selection. Held here so a deep link can drive either layout.
    @State private var selectedTabID: String?
    @State private var section = RemoteSection.workspaces
    /// The Latest tab's own stack, so a row opens over the list it came from.
    @State private var latestPath = NavigationPath()
    @State private var isAddingMac = false
    /// Which field the keyboard belongs to, so it can be sent away again. The port uses a
    /// number pad, and a number pad has no return key to dismiss itself with.
    @FocusState private var focusedField: AddMacField?
    @State private var isScanning = false
    /// A Mac picked from the nearby list, to be dialled by name.
    @State private var pickedNearbyMac: String?
    @State private var renaming: SavedConnection?
    @State private var renameText = ""
    /// The connection being dialled, so its `lastConnectedAt` is only stamped once it works.
    @State private var pendingConnectionID: UUID?
    /// True from the first welcome until the user leaves. While it holds, a failure is a loss to
    /// recover from rather than a refusal to report.
    @State private var wasConnected = false
    /// The Mac's own name from its last welcome, so a banner can still name it once it is gone.
    @State private var lastHostName: String?
    @State private var reconnect = ReconnectSchedule()
    @State private var reconnectTask: Task<Void, Never>?
    /// Keeps the process, and with it the socket, alive for the half minute iOS grants after the
    /// app leaves the screen. Without it the app is suspended within seconds, and an agent that
    /// finishes just after the phone goes down is not heard.
    @State private var backgroundGrace = UIBackgroundTaskIdentifier.invalid
    /// Decides the layout by the room there is, not by the device. An iPad in a narrow Split View
    /// is reported compact and gets the phone's stack, which is the only thing that fits.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase

    init(notifier: AgentNotifier) {
        self.notifier = notifier
        _store = State(initialValue: RemoteSessionStore(deviceName: UIDevice.current.name, notifier: notifier))
    }

    /// The token a launch argument supplied, if one did. A copy an earlier build persisted is
    /// removed on the way past, so it does not outlive the Keychain entry that replaced it.
    private static func launchToken() -> String {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "remote.token")
        return defaults.string(forKey: "remote.token") ?? ""
    }

    var body: some View {
        Group {
            if showsWorkspaces {
                TabView(selection: $section) {
                    workspaces
                        .safeAreaInset(edge: .bottom, spacing: 0) { connectionStatus }
                        .tabItem { Label("Workspaces", systemImage: "square.grid.2x2") }
                        .tag(RemoteSection.workspaces)
                    NavigationStack(path: $latestPath) {
                        LatestView(store: store, path: $latestPath)
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) { connectionStatus }
                    .tabItem { Label("Latest", systemImage: "tray") }
                    .badge(store.notifications.log.unreadCount)
                    .tag(RemoteSection.latest)
                }
            } else {
                NavigationStack {
                    savedConnectionsList
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let refusal = store.refusal {
                RefusalBanner(error: refusal) { store.dismissRefusal() }
                    .padding()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.default, value: store.refusal)
        .onOpenURL(perform: connect(to:))
        .onAppear(perform: reconnectIfAsked)
        .onChange(of: store.client.state) { _, state in
            handle(state)
        }
        .onChange(of: scenePhase) { _, phase in
            handle(phase)
        }
        .onChange(of: store.tree) { _, _ in
            openTabIfAsked()
        }
        .onChange(of: openTab) { _, _ in
            openTabIfAsked()
        }
        // A device holds one terminal attachment, so only one tab may have a screen open at a
        // time. Opening from Latest closes whatever Workspaces had open, the way opening a
        // notification on the Mac moves its selection, and going back to Workspaces closes what
        // Latest opened.
        .onChange(of: latestPath.count) { _, count in
            guard count > 0 else { return }
            path = NavigationPath()
            selectedTabID = nil
        }
        .onChange(of: section) { _, section in
            if section == .workspaces {
                latestPath = NavigationPath()
            }
        }
    }

    /// Opens the tab a banner, or a launch argument, asked for, once there is a tree to find it in.
    /// A tap while the app is already connected must not wait for the next tree.
    private func openTabIfAsked() {
        guard store.tree != nil, !openTab.isEmpty else { return }
        section = .workspaces
        if horizontalSizeClass == .regular {
            selectedTabID = openTab
        } else {
            // Replaces the stack rather than pushing onto it: a tap arriving over another tab's
            // screen would otherwise leave two tab screens stacked, both claiming the attachment.
            path = NavigationPath([openTab])
        }
        openTab = ""
    }

    /// The workspace list and what it opens. Two columns where there is room, a stack where not.
    @ViewBuilder
    private var workspaces: some View {
        if horizontalSizeClass == .regular {
            RemoteSplitView(store: store, selectedTabID: $selectedTabID)
        } else {
            NavigationStack(path: $path) {
                RemoteTreeView(store: store)
            }
        }
    }

    // At the bottom, where it takes room from the content rather than fighting the navigation
    // bar for the top, and where the keyboard pushes it up along with everything else.
    @ViewBuilder
    private var connectionStatus: some View {
        if !isConnected {
            ConnectionLostBanner(
                hostName: currentHostName,
                isRetrying: isConnecting || reconnect.hasAttemptsLeft,
                onRetry: { retryNow() },
                onLeave: { leave() }
            )
        } else if store.client.path == .relay {
            // Said once, quietly, so a slow relay is not mistaken for a slow Mac.
            Label("Through the relay", systemImage: "antenna.radiowaves.left.and.right")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(.bar)
                .accessibilityIdentifier("connection.viaRelay")
        }
    }

    // MARK: - Saved Macs

    private var savedConnectionsList: some View {
        List {
            if connections.connectionsByRecency.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No Macs Yet",
                        systemImage: "macbook.and.iphone",
                        description: Text("On the Mac, open MyTerm’s Settings, then Devices, and press Link a Device. Then scan its code here.")
                    )
                }
            } else {
                Section("Macs") {
                    ForEach(connections.connectionsByRecency) { connection in
                        Button {
                            connect(to: connection)
                        } label: {
                            savedRow(connection)
                        }
                        .accessibilityIdentifier("mac.\(connection.displayName)")
                        .swipeActions(edge: .trailing) {
                            Button("Remove", role: .destructive) {
                                connections.remove(connection.id)
                            }
                            Button("Rename") {
                                renameText = connection.displayName
                                renaming = connection
                            }
                        }
                    }
                }
            }

            if case .failed(let message) = store.client.state {
                Section {
                    Label {
                        Text(message)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    .font(.callout)
                    .accessibilityIdentifier("connection.failure")
                }
            }

            Section {
                Button("Scan Pairing Code", systemImage: "qrcode.viewfinder") { isScanning = true }
                Button("Add a Mac…", systemImage: "plus") { isAddingMac = true }
                Toggle("Reconnect on launch", isOn: $reconnectsOnLaunch)
            } footer: {
                Text("A Mac shows its code under Settings, then Devices, then Link a Device. Scanning it here, or with the Camera app, adds the Mac to this list.")
            }

            Section {
                @Bindable var notifier = notifier
                Toggle("Notify me when an agent needs me", isOn: $notifier.isEnabled)
                    .accessibilityIdentifier("notifications.enabled")
            } footer: {
                // The limit is stated here rather than discovered: a phone in a pocket is the case
                // most people picture, and it is the one this cannot reach.
                Text("While this app is open and connected, a banner says when an agent finishes or asks a question in a tab you are not looking at. It reaches you for about half a minute after you leave the app; after that, only opening the app again catches up.")
            }
        }
        .navigationTitle("Macs")
        .sheet(isPresented: $isAddingMac, onDismiss: { nearby.stop() }) {
            NavigationStack {
                addMacForm
            }
        }
        .sheet(isPresented: $isScanning) {
            NavigationStack {
                PairingCodeScannerView { url in
                    isScanning = false
                    connect(to: url)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") { isScanning = false }
                    }
                }
            }
        }
        .alert("Rename Mac", isPresented: renamingBinding) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                if let renaming {
                    connections.rename(renaming.id, to: renameText)
                }
                renaming = nil
            }
        }
    }

    private func savedRow(_ connection: SavedConnection) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.displayName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(address(of: connection))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isConnecting, pendingConnectionID == connection.id {
                ProgressView()
            } else {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// The address is the fallback. The name is what the device dials first, so it leads.
    private func address(of connection: SavedConnection) -> String {
        let byAddress = connection.host.isEmpty ? nil : "\(connection.host):\(String(connection.port))"
        switch (connection.serviceName, byAddress) {
        case (let name?, let address?) where name != connection.displayName:
            return "\(name) · \(address)"
        case (_, let address?):
            return address
        case (let name?, nil):
            return name
        case (nil, nil):
            return ""
        }
    }

    private var renamingBinding: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    // MARK: - Adding a Mac

    private var addMacForm: some View {
        Form {
            Section {
                if nearby.macs.isEmpty {
                    HStack {
                        ProgressView()
                        Text("Looking for Macs on this network…")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(nearby.macs) { mac in
                        Button {
                            pickedNearbyMac = pickedNearbyMac == mac.name ? nil : mac.name
                        } label: {
                            HStack {
                                Label(mac.name, systemImage: "desktopcomputer")
                                    .foregroundStyle(.primary)
                                Spacer()
                                if pickedNearbyMac == mac.name {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .accessibilityIdentifier("nearby.\(mac.name)")
                    }
                }
            } header: {
                Text("Nearby")
            } footer: {
                Text("Macs running MyTerm with “Allow my devices to reach this Mac” turned on appear here.")
            }

            Section {
                TextField("Pairing Token", text: $token)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .token)
                    .accessibilityIdentifier("token")
            } header: {
                Text("Token")
            } footer: {
                Text("Shown under Settings, then Devices, in MyTerm on the Mac.")
            }

            if pickedNearbyMac == nil {
                Section("By Address") {
                    TextField("Host", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .focused($focusedField, equals: .host)
                    TextField("Port", text: $portText)
                        .keyboardType(.numberPad)
                        .focused($focusedField, equals: .port)
                }
            }

            Section {
                Button(pickedNearbyMac.map { "Connect to “\($0)”" } ?? "Save and Connect") {
                    isAddingMac = false
                    saveAndConnect()
                }
                .disabled(!canConnect)
                .accessibilityIdentifier("saveAndConnect")
            }
        }
        // On a phone the keyboard covers Save and Connect, and the number pad the port uses has no
        // return key of its own, so both ways out of it are given here.
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Add a Mac")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { isAddingMac = false }
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedField = nil }
                    .accessibilityIdentifier("dismissKeyboard")
            }
        }
        .onAppear {
            nearby.start()
            if portText.isEmpty {
                portText = String(RemoteProtocol.defaultPort)
            }
        }
    }

    // MARK: - Connecting

    /// Accepts `myterm-remote://connect?host=&port=&token=`, the shape a pairing code carries, so a
    /// scan and a typed entry arrive at the same place.
    private func connect(to url: URL) {
        guard let link = PairingLinkParser.parse(url) else { return }
        host = link.host
        portText = String(link.port)
        token = link.token

        let saved = connections.upsert(pairingLink: link)
        dial(saved, target: link.target)
    }

    private func connect(to connection: SavedConnection) {
        guard let token = connections.token(for: connection) else { return }
        host = connection.host
        portText = String(connection.port)
        self.token = token
        dial(connection, target: connection.target(token: token))
    }

    private func saveAndConnect() {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name = pickedNearbyMac {
            let saved = connections.upsert(host: "", port: 0, token: trimmedToken, serviceName: name)
            pickedNearbyMac = nil
            dial(saved, target: RemoteTarget(host: "", port: 0, token: trimmedToken, serviceName: name))
            return
        }
        guard let port = UInt16(portText) else { return }
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        var relay: RelayEndpoint?
        if let relayURL = URL(string: relayText), RelayRendezvous.isValidIdentifier(rendezvousText) {
            relay = RelayEndpoint(url: relayURL, rendezvousID: rendezvousText)
        }
        let saved = connections.upsert(host: trimmedHost, port: port, token: trimmedToken, relay: relay)
        dial(saved, target: RemoteTarget(host: trimmedHost, port: port, token: trimmedToken, relay: relay))
    }

    private func dial(_ saved: SavedConnection, target: RemoteTarget) {
        cancelReconnect()
        wasConnected = false
        pendingConnectionID = saved.id
        store.client.connect(to: target)
    }

    /// Names a saved Mac after the Mac itself, which is the only name that tells two of them apart.
    /// A name the user typed is left alone: only the address-shaped default is replaced.
    private func adoptHostName(_ hostName: String, for id: UUID) {
        guard !hostName.isEmpty,
              let saved = connections.connections.first(where: { $0.id == id })
        else {
            return
        }
        connections.recordServiceName(hostName, for: id)
        if saved.displayName == saved.host || saved.displayName.isEmpty {
            connections.rename(id, to: hostName)
        }
    }

    /// Launch arguments set the manual fields, so that path wins when it is present. Otherwise the
    /// most recently used Mac is the one worth reopening.
    private func reconnectIfAsked() {
        guard reconnectsOnLaunch, store.client.target == nil else { return }
        if canConnect {
            saveAndConnect()
        } else if let recent = connections.connectionsByRecency.first {
            connect(to: recent)
        }
    }

    // MARK: - Staying connected

    private func handle(_ state: RemoteClientState) {
        switch state {
        case .connected(let hostName, _):
            cancelReconnect()
            wasConnected = true
            lastHostName = hostName
            // Stamped on success only, so a Mac that is off does not climb the recency list.
            if let pendingConnectionID {
                connections.recordConnected(pendingConnectionID)
                adoptHostName(hostName, for: pendingConnectionID)
                if let address = store.client.resolvedAddress {
                    connections.recordAddress(host: address.host, port: address.port, for: pendingConnectionID)
                }
            }
        case .failed:
            pendingConnectionID = nil
            guard wasConnected, scenePhase == .active else { return }
            scheduleReconnect()
        case .idle:
            leaveWorkspaces()
        case .connecting:
            break
        }
    }

    private func handle(_ phase: ScenePhase) {
        switch phase {
        case .active:
            endBackgroundGrace()
            // Coming back is the moment to try again, whatever the schedule said. iOS closes the
            // socket of an app it suspends, so this is also the common path after any long absence.
            guard wasConnected, !isConnected else { return }
            retryNow()
        case .background:
            cancelReconnect()
            if isConnected {
                beginBackgroundGrace()
            }
        default:
            break
        }
    }

    private func beginBackgroundGrace() {
        guard backgroundGrace == .invalid else { return }
        backgroundGrace = UIApplication.shared.beginBackgroundTask(withName: "myterm.remote.connection") {
            // iOS is about to suspend the app whatever happens; ending the task is all that is
            // owed. The socket dies with the suspension and reconnects on the next foreground.
            endBackgroundGrace()
        }
    }

    private func endBackgroundGrace() {
        guard backgroundGrace != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundGrace)
        backgroundGrace = .invalid
    }

    private func scheduleReconnect() {
        guard let delay = reconnect.nextDelay() else { return }
        reconnectTask?.cancel()
        reconnectTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            store.client.reconnect()
        }
    }

    private func retryNow() {
        reconnectTask?.cancel()
        reconnect = ReconnectSchedule()
        store.client.reconnect()
    }

    private func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnect = ReconnectSchedule()
    }

    /// Leaves the Mac on purpose. The list of Macs is the right place to land.
    private func leave() {
        cancelReconnect()
        store.client.disconnect()
    }

    private func leaveWorkspaces() {
        wasConnected = false
        pendingConnectionID = nil
        path = NavigationPath()
        latestPath = NavigationPath()
        selectedTabID = nil
        section = .workspaces
        store.clearTree()
    }

    private var isConnected: Bool {
        if case .connected = store.client.state { return true }
        return false
    }

    private var isConnecting: Bool {
        if case .connecting = store.client.state { return true }
        return false
    }

    /// The workspace screens stay up through a dropped connection, so the user is never dumped
    /// mid-task. They only go when the user leaves.
    private var showsWorkspaces: Bool {
        isConnected || wasConnected
    }

    private var currentHostName: String? {
        store.client.hostName
            ?? lastHostName
            ?? pendingConnectionID.flatMap { id in connections.connections.first { $0.id == id }?.displayName }
            ?? store.client.target?.serviceName
    }

    private var canConnect: Bool {
        let hasToken = !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if pickedNearbyMac != nil { return hasToken }
        return !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && UInt16(portText) != nil && hasToken
    }
}

/// The fields the Add a Mac form's keyboard can belong to.
private enum AddMacField: Hashable {
    case token
    case host
    case port
}

/// When to try again after a lost connection. Quick at first, because most drops are a blink,
/// then slower, because a Mac that has gone to sleep is not coming back in the next second.
struct ReconnectSchedule {
    private static let delays: [TimeInterval] = [1, 2, 4, 8, 15, 30]
    private var attempts = 0

    var hasAttemptsLeft: Bool { attempts < Self.delays.count }

    mutating func nextDelay() -> TimeInterval? {
        guard hasAttemptsLeft else { return nil }
        defer { attempts += 1 }
        return Self.delays[attempts]
    }
}

/// Sits above whatever the user was looking at when the Mac went away.
/// The two things a connected device shows: the Mac's workspaces, and what its agents did.
private enum RemoteSection: Hashable {
    case workspaces
    case latest
}

private struct ConnectionLostBanner: View {
    let hostName: String?
    let isRetrying: Bool
    let onRetry: () -> Void
    let onLeave: () -> Void

    /// A phone at an accessibility text size cannot hold the message and the buttons on one line.
    /// Side by side, the Mac's name breaks mid-word and the banner takes half the screen.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        marker
                        message
                    }
                    HStack(spacing: 10) { buttons }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 12) {
                    marker
                    message
                    Spacer()
                    buttons
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connection.lost")
    }

    @ViewBuilder
    private var marker: some View {
        if isRetrying {
            ProgressView()
        } else {
            Image(systemName: "wifi.exclamationmark")
                .foregroundStyle(.orange)
        }
    }

    private var message: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(isRetrying ? "Reconnecting to \(macName)…" : "Lost \(macName)")
                .font(.subheadline.weight(.semibold))
            Text(isRetrying
                 ? "What you see is from before the connection dropped."
                 : "It may be asleep, or off this network.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        // A Mac's name is one long word to the layout engine. Without this it is hyphenated down
        // the middle rather than given the width the banner has.
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var buttons: some View {
        if !isRetrying {
            Button("Retry", action: onRetry)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier("connection.retry")
        }
        Button("Leave", action: onLeave)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("connection.leave")
    }

    private var macName: String {
        hostName.map { "\u{201C}\($0)\u{201D}" } ?? "your Mac"
    }
}

/// A request the Mac would not do. It shows for a moment and leaves on its own, because the next
/// tree the Mac sends is already the truth about what did and did not change.
private struct RefusalBanner: View {
    let error: RemoteError
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.subheadline)
                .accessibilityIdentifier("refusal.message")
            Spacer(minLength: 0)
            Button("Dismiss", systemImage: "xmark", action: onDismiss)
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
    }

    private var text: String {
        switch error.code {
        case "denied":
            "Your Mac is not taking changes from devices."
        default:
            "Your Mac " + error.message + "."
        }
    }
}

#Preview {
    ConnectionView(notifier: AgentNotifier())
}
