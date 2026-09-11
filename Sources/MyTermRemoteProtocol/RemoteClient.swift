import Foundation
import Network
import Observation

public enum RemoteClientState: Equatable, Sendable {
    case idle
    case connecting
    case connected(hostName: String, allowsInput: Bool)
    case failed(String)
}

/// Where a Mac is. A device keeps both ways of reaching it: the name the Mac advertises on the
/// local network, which survives the Mac's address changing, and the address itself, which works
/// where there is no Bonjour to ask.
public struct RemoteTarget: Equatable, Sendable {
    public var host: String
    public var port: UInt16
    public var token: String
    /// The Bonjour service name the Mac advertises, when the pairing code carried one.
    public var serviceName: String?
    /// The relay the Mac registered with, when the pairing code carried one. Tried last.
    public var relay: RelayEndpoint?

    public init(
        host: String,
        port: UInt16,
        token: String,
        serviceName: String? = nil,
        relay: RelayEndpoint? = nil
    ) {
        self.host = host
        self.port = port
        self.token = token
        self.serviceName = serviceName
        self.relay = relay
    }

    var hasAddress: Bool { !host.isEmpty && port != 0 }
}

/// How the bytes are reaching the Mac.
public enum RemotePath: Equatable, Sendable {
    case local
    case relay
}

/// Where the Mac turned out to be, once a connection to it was made.
public struct RemoteAddress: Equatable, Sendable {
    public var host: String
    public var port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
}

/// What a device does with what the host sends.
@MainActor
public protocol RemoteClientDelegate: AnyObject {
    func remoteClient(_ client: RemoteClient, didReceive tree: RemoteTree)
    func remoteClient(_ client: RemoteClient, didAttach attached: RemoteAttached)
    func remoteClient(_ client: RemoteClient, didReceiveOutput bytes: [UInt8], for session: UUID)
    /// Clear the emulator. A fresh screen arrives immediately after.
    func remoteClient(_ client: RemoteClient, shouldResync session: UUID)
    func remoteClient(_ client: RemoteClient, didReceive activity: RemoteAgentActivity)
    /// The Mac's backlog of agents waiting for the user, whole, whenever it changes.
    func remoteClient(_ client: RemoteClient, didReceive notifications: RemoteNotifications)
    /// An agent conversation, whole, as it stood when the device asked for it.
    func remoteClient(_ client: RemoteClient, didReceive conversation: RemoteAgentConversation)
    /// The entries that arrived after that.
    func remoteClient(_ client: RemoteClient, didReceive entries: RemoteAgentEntries)
    /// What a pending permission prompt is offering. Empty options mean it has gone.
    func remoteClient(_ client: RemoteClient, didReceive prompt: RemoteAgentPrompt)
    /// What a screen-only command drew on the Mac, and whether it is still up.
    func remoteClient(_ client: RemoteClient, didReceive screen: RemoteAgentScreen)
    /// The host refused one request. The connection is still good.
    func remoteClient(_ client: RemoteClient, didRefuse error: RemoteError)
}

public extension RemoteClientDelegate {
    func remoteClient(_ client: RemoteClient, didRefuse error: RemoteError) {}
    func remoteClient(_ client: RemoteClient, didReceive notifications: RemoteNotifications) {}
    func remoteClient(_ client: RemoteClient, didReceive conversation: RemoteAgentConversation) {}
    func remoteClient(_ client: RemoteClient, didReceive entries: RemoteAgentEntries) {}
    func remoteClient(_ client: RemoteClient, didReceive prompt: RemoteAgentPrompt) {}
    func remoteClient(_ client: RemoteClient, didReceive screen: RemoteAgentScreen) {}
}

/// The device end of a MyTerm Remote connection.
///
/// This lives beside the protocol rather than in the app so both ends encode and decode with the
/// same code, and so the connection can be exercised from a test without a user interface.
@MainActor
@Observable
public final class RemoteClient {
    public private(set) var state: RemoteClientState = .idle
    /// The last tree the host sent. Kept through a dropped connection so the screen the user was
    /// on stays put while the device reconnects; cleared only when the user leaves the Mac.
    public private(set) var tree: RemoteTree?
    /// The last thing the host refused, for the device to show. Cleared by the next connect.
    public private(set) var lastError: RemoteError?
    /// Where the last `connect` was pointed, so `reconnect` can dial it again.
    public private(set) var target: RemoteTarget?
    /// Counts each time the host welcomes this device. A screen that was attached before the count
    /// moved has to attach again, because the old attachment died with the old socket.
    public private(set) var connectionGeneration = 0
    /// The address the current connection reached the Mac at. A Mac found by name lands here with
    /// an address the device can save, so it is reachable by address as well next time.
    public private(set) var resolvedAddress: RemoteAddress?
    /// Which route the current, or last attempted, connection took. The relay is slower, and the
    /// user should be able to tell a slow relay from a slow Mac.
    public private(set) var path: RemotePath?

    /// How long to wait for the Mac before giving up. Bonjour gets less, because when it fails the
    /// address is tried next and the user is still waiting on the total.
    public var addressTimeout: TimeInterval = 10
    public var serviceTimeout: TimeInterval = 4
    public var relayTimeout: TimeInterval = 20

    @ObservationIgnored
    public weak var delegate: (any RemoteClientDelegate)?

    private let deviceName: String
    private let queue = DispatchQueue(label: "com.gordonbeeming.myterm.remote-client")
    private var connection: NWConnection?
    private var decoder = RemoteFrameDecoder()
    private var attempt = 0
    private var timeout: Task<Void, Never>?
    private var tunnel: RelayDeviceTunnel?
    /// What the relay said when it closed the tunnel, if it said anything.
    private var tunnelFailure: RelayFailure?

    private enum Route {
        case service, address, relay
    }

    public init(deviceName: String) {
        self.deviceName = deviceName
    }

    public func connect(host: String, port: UInt16, token: String) {
        connect(to: RemoteTarget(host: host, port: port, token: token))
    }

    /// Dials the Mac. By name first when one is known, then by address.
    public func connect(to target: RemoteTarget) {
        // A different Mac gets a blank slate. The same one keeps its tree until the new one lands.
        if self.target?.host != target.host || self.target?.port != target.port {
            tree = nil
        }
        self.target = target
        lastError = nil
        tearDown()
        state = .connecting
        dial(target, via: firstRoute(for: target))
    }

    private func firstRoute(for target: RemoteTarget) -> Route {
        if target.serviceName != nil { return .service }
        if target.hasAddress { return .address }
        return .relay
    }

    /// The route after `route`, or nil when `route` was the last one worth trying.
    private func nextRoute(after route: Route, for target: RemoteTarget) -> Route? {
        switch route {
        case .service:
            target.hasAddress ? .address : (target.relay != nil ? .relay : nil)
        case .address:
            target.relay != nil ? .relay : nil
        case .relay:
            nil
        }
    }

    /// Connects to a Bonjour service found on the local network.
    public func connect(service name: String, domain: String = "local.", token: String) {
        connect(to: RemoteTarget(host: "", port: 0, token: token, serviceName: name))
    }

    /// Dials the last target again. Does nothing when there is none.
    public func reconnect() {
        guard let target else { return }
        connect(to: target)
    }

    /// Leaves the Mac. The tree goes with it; a reconnect starts from nothing.
    public func disconnect() {
        tearDown()
        tree = nil
        lastError = nil
        target = nil
        state = .idle
    }

    private func tearDown() {
        resolvedAddress = nil
        attempt += 1
        timeout?.cancel()
        timeout = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        tunnel?.cancel()
        tunnel = nil
        tunnelFailure = nil
        decoder = RemoteFrameDecoder()
    }

    public func attach(tabID: String) {
        send(.attach(RemoteAttach(tabID: tabID)))
    }

    public func detach(session: UUID) {
        send(.detach(session: session))
    }

    /// Follows a tab's agent conversation. Separate from the terminal attachment, so watching an
    /// agent never costs the device the one session it may attach to.
    public func attachAgent(tabID: String) {
        send(.attachAgent(RemoteAttachAgent(tabID: tabID)))
    }

    public func detachAgent(tabID: String) {
        send(.detachAgent(RemoteAttachAgent(tabID: tabID)))
    }

    /// Says something to the agent. Text only: the host adds the Return and refuses control bytes.
    public func replyToAgent(tabID: String, text: String) {
        send(.agentReply(RemoteAgentReply(tabID: tabID, text: text)))
    }

    /// Takes the whole option, label and all, because the host checks the label is still on that
    /// number before it sends a keystroke.
    public func answerAgentPrompt(tabID: String, option: RemoteAgentPromptOption) {
        send(.agentAnswer(RemoteAgentAnswer(tabID: tabID, isDeny: false, option: option)))
    }

    public func denyAgentPrompt(tabID: String) {
        send(.agentAnswer(RemoteAgentAnswer(tabID: tabID, isDeny: true)))
    }

    /// Asks for the dialog a screen-only command drew to be closed. The host sends the Escape.
    public func dismissAgentScreen(tabID: String) {
        send(.dismissAgentScreen(RemoteDismissAgentScreen(tabID: tabID)))
    }

    public func sendInput(_ bytes: [UInt8], to session: UUID) {
        guard case .connected(_, let allowsInput) = state, allowsInput else { return }
        transmit(RemoteFrameCodec.encode(RemoteFrame(
            kind: .input,
            payload: RemoteSessionPayload.encode(session: session, bytes: bytes)
        )))
    }

    public func sendInput(_ text: String, to session: UUID) {
        sendInput(Array(text.utf8), to: session)
    }

    // Asking the Mac to change its workspaces. These only ever request: the tree the device shows
    // still comes back from the host, so a refused request simply leaves the device as it was.
    //
    // The `allowsInput` check here spares the Mac a request it would reject anyway. It is not the
    // permission check. The host refuses these on its own, because a device is not trusted to.

    public func renameTab(_ tabID: String, title: String?) {
        sendMutation(.renameTab(RemoteRenameTab(tabID: tabID, title: title)))
    }

    public func closeTab(_ tabID: String) {
        sendMutation(.closeTab(RemoteCloseTab(tabID: tabID)))
    }

    public func renameWorkspace(_ workspaceID: String, title: String) {
        sendMutation(.renameWorkspace(RemoteRenameWorkspace(workspaceID: workspaceID, title: title)))
    }

    public func createWorkspace(title: String? = nil, folderID: String? = nil) {
        sendMutation(.createWorkspace(RemoteCreateWorkspace(title: title, folderID: folderID)))
    }

    public func deleteWorkspace(_ workspaceID: String) {
        sendMutation(.deleteWorkspace(RemoteDeleteWorkspace(workspaceID: workspaceID)))
    }

    public func createTerminalTab(in workspaceID: String) {
        sendMutation(.createTerminalTab(RemoteCreateTerminalTab(workspaceID: workspaceID)))
    }

    /// True when the Mac has said it accepts changes from devices. The controls that send them are
    /// hidden when this is false, so the user is not offered something that will not happen.
    public var allowsMutation: Bool {
        guard case .connected(_, let allowsInput) = state else { return false }
        return allowsInput
    }

    /// The name of the Mac this device is, or was last, talking to.
    public var hostName: String? {
        if case .connected(let hostName, _) = state { return hostName }
        return nil
    }

    private func sendMutation(_ message: RemoteControlMessage) {
        guard allowsMutation else { return }
        send(message)
    }

    // MARK: - Dialing

    private func dial(_ target: RemoteTarget, via route: Route) {
        switch route {
        case .service:
            guard let name = target.serviceName else { return dial(target, via: .address) }
            path = .local
            let endpoint = NWEndpoint.service(
                name: name, type: RemoteProtocol.bonjourServiceType, domain: "local.", interface: nil
            )
            start(
                connection: NWConnection(to: endpoint, using: RemoteTransportSecurity.parameters(token: target.token)),
                target: target,
                route: route,
                limit: serviceTimeout
            )
        case .address:
            path = .local
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(target.host), port: NWEndpoint.Port(rawValue: target.port) ?? .any
            )
            // With a relay to fall back on, a Mac that is not on this network need not be waited
            // for as long: the relay is where it will be found.
            start(
                connection: NWConnection(to: endpoint, using: RemoteTransportSecurity.parameters(token: target.token)),
                target: target,
                route: route,
                limit: target.relay != nil ? min(addressTimeout, 5) : addressTimeout
            )
        case .relay:
            guard let relay = target.relay else { return }
            path = .relay
            dialRelay(relay, target: target)
        }
    }

    /// The relay hands over a loopback port. What is dialled there is the same TLS session as on
    /// the local network, so the relay only ever carries ciphertext.
    private func dialRelay(_ relay: RelayEndpoint, target: RemoteTarget) {
        attempt += 1
        let thisAttempt = attempt
        let tunnel = RelayDeviceTunnel(endpoint: relay)
        self.tunnel = tunnel
        tunnel.start(
            ready: { [weak self] result in
                guard let self, self.attempt == thisAttempt else { return }
                switch result {
                case .success(let port):
                    let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
                    self.start(
                        connection: NWConnection(to: endpoint, using: RemoteTransportSecurity.parameters(token: target.token)),
                        target: target,
                        route: .relay,
                        limit: self.relayTimeout
                    )
                case .failure(let failure):
                    self.tearDown()
                    self.state = .failed(failure.message)
                }
            },
            ended: { [weak self] failure in
                // The relay side went away. Once connected, the loopback leg notices its peer
                // closing and ends up in `giveUp` on its own; keeping the verdict lets the message
                // say why. Before that, a TLS handshake whose peer vanished sits in `.waiting` and
                // would only report at the timeout, so the relay's verdict is acted on here.
                guard let self, self.attempt == thisAttempt else { return }
                self.tunnelFailure = failure
                if case .connected = self.state { return }
                self.giveUp(on: target, route: .relay, error: self.pendingWaitError)
            }
        )
    }

    private func start(connection: NWConnection, target: RemoteTarget, route: Route, limit: TimeInterval) {
        // A relay dial already counted its attempt; the tunnel and this connection are one try.
        if route != .relay {
            attempt += 1
        }
        let thisAttempt = attempt
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] connectionState in
            Task { @MainActor [weak self] in
                guard let self, self.attempt == thisAttempt else { return }
                switch connectionState {
                case .ready:
                    self.timeout?.cancel()
                    self.timeout = nil
                    self.resolvedAddress = Self.address(of: connection)
                    self.send(.hello(RemoteHello(deviceName: self.deviceName, token: target.token)))
                    self.receive(attempt: thisAttempt)
                case .failed(let error):
                    self.giveUp(on: target, route: route, error: error)
                case .waiting(let error):
                    // Refused means something answered and said no: nothing listens there, and
                    // waiting for a network change will not make it. Anything else is no route
                    // yet, and the timeout decides when waiting becomes failing.
                    if case .posix(.ECONNREFUSED) = error {
                        self.giveUp(on: target, route: route, error: error)
                        return
                    }
                    self.pendingWaitError = error
                case .cancelled:
                    break
                default:
                    break
                }
            }
        }
        pendingWaitError = nil
        timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
            guard !Task.isCancelled, let self, self.attempt == thisAttempt else { return }
            self.giveUp(on: target, route: route, error: self.pendingWaitError)
        }
        connection.start(queue: queue)
    }

    private var pendingWaitError: NWError?

    private static func address(of connection: NWConnection) -> RemoteAddress? {
        guard case .hostPort(let host, let port) = connection.currentPath?.remoteEndpoint else { return nil }
        // A link-local address carries its interface after a percent sign. A device on another
        // interface cannot use that suffix, so it is dropped.
        let text = "\(host)".split(separator: "%", maxSplits: 1).first.map(String.init) ?? "\(host)"
        return RemoteAddress(host: text, port: port.rawValue)
    }

    /// One way of reaching the Mac did not work. Try the next, or report it.
    private func giveUp(on target: RemoteTarget, route: Route, error: NWError?) {
        // A reset on the loopback leg is the relay closing the tunnel, not a wrong token; the
        // tunnel's own verdict, if it gave one, is what the user should read.
        let relayVerdict: String? = route == .relay ? tunnelFailureMessage : nil
        tearDown()
        if let next = nextRoute(after: route, for: target) {
            dial(target, via: next)
            return
        }
        state = .failed(relayVerdict ?? RemoteClientFailure.message(for: error, target: target, hadConnected: false))
    }

    private var tunnelFailureMessage: String? {
        // A normal close is the Mac hanging up, passed on by the relay. Before a welcome that is the
        // handshake being refused, which the general wording describes; the relay has nothing to add.
        if case .closed(code: 1000) = tunnelFailure { return nil }
        return tunnelFailure?.message
    }

    private func receive(attempt thisAttempt: Int) {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] content, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self, self.attempt == thisAttempt else { return }
                if let content, !content.isEmpty {
                    self.consume(content)
                }
                if isComplete || error != nil {
                    let hadConnected: Bool
                    if case .connected = self.state { hadConnected = true } else { hadConnected = false }
                    // A handshake the Mac refuses ends the same way as a Mac that went away: the
                    // socket closes. What was happening at the time is what tells them apart.
                    let message = RemoteClientFailure.message(
                        for: error,
                        target: self.target,
                        hadConnected: hadConnected,
                        hostName: self.hostName
                    )
                    self.tearDown()
                    self.state = .failed(message)
                    return
                }
                self.receive(attempt: thisAttempt)
            }
        }
    }

    private func consume(_ data: Data) {
        decoder.append(data)
        while true {
            let frame: RemoteFrame?
            do {
                frame = try decoder.nextFrame()
            } catch {
                // The bad header stays at the front of the buffer, so nothing behind it can ever
                // be read. Staying "connected" would mean a screen that never updates again and a
                // buffer that only grows. The host hangs up on the same error.
                tearDown()
                state = .failed("The Mac sent something this app could not read. Try connecting again.")
                return
            }
            guard let frame else { return }
            handle(frame)
        }
    }

    private func handle(_ frame: RemoteFrame) {
        switch frame.kind {
        case .control:
            guard let message = try? RemoteControlCodec.decode(frame) else { return }
            handle(message)
        case .output:
            guard let (session, bytes) = RemoteSessionPayload.decode(frame.payload) else { return }
            delegate?.remoteClient(self, didReceiveOutput: bytes, for: session)
        case .input:
            break
        }
    }

    private func handle(_ message: RemoteControlMessage) {
        switch message {
        case .welcome(let welcome):
            // A welcome after the first is the Mac changing what it permits, not a new connection.
            if case .connected = state {} else {
                connectionGeneration += 1
            }
            state = .connected(hostName: welcome.hostName, allowsInput: welcome.allowsInput)
        case .tree(let tree):
            self.tree = tree
            delegate?.remoteClient(self, didReceive: tree)
        case .attached(let attached):
            delegate?.remoteClient(self, didAttach: attached)
        case .resync(let session):
            delegate?.remoteClient(self, shouldResync: session)
        case .agentActivity(let activity):
            delegate?.remoteClient(self, didReceive: activity)
        case .notifications(let notifications):
            delegate?.remoteClient(self, didReceive: notifications)
        case .error(let error):
            lastError = error
            // Before the welcome, an error is the handshake failing and the host closes the socket
            // straight after. Once connected, an error is one request the host would not do, and the
            // connection is still good: a refused rename must not look like the Mac went away.
            if case .connected = state {
                delegate?.remoteClient(self, didRefuse: error)
            } else {
                tearDown()
                state = .failed(error.message)
            }
        case .agentConversation(let conversation):
            delegate?.remoteClient(self, didReceive: conversation)
        case .agentEntries(let entries):
            delegate?.remoteClient(self, didReceive: entries)
        case .agentPrompt(let prompt):
            delegate?.remoteClient(self, didReceive: prompt)
        case .agentScreen(let screen):
            delegate?.remoteClient(self, didReceive: screen)
        case .hello, .attach, .detach, .attachAgent, .detachAgent, .agentReply, .agentAnswer,
             .dismissAgentScreen, .renameTab, .closeTab, .renameWorkspace, .createWorkspace,
             .deleteWorkspace, .createTerminalTab:
            break
        }
    }

    /// Not private, so the package's own tests can put a message on the wire that the helpers above
    /// decline to send. Refusing host-side is the permission check, and proving it needs a device
    /// that asks anyway.
    func send(_ message: RemoteControlMessage) {
        guard let frame = try? RemoteControlCodec.encode(message) else { return }
        transmit(RemoteFrameCodec.encode(frame))
    }

    private func transmit(_ bytes: [UInt8]) {
        connection?.send(content: Data(bytes), completion: .idempotent)
    }
}

/// Turns what the network reported into a sentence a person can act on.
///
/// The raw errors name POSIX codes and TLS alerts. None of them say the only things that matter to
/// the person holding the device: is the Mac awake, is it on this network, and is the token right.
public enum RemoteClientFailure {
    public static func message(
        for error: NWError?,
        target: RemoteTarget?,
        hadConnected: Bool,
        hostName: String? = nil
    ) -> String {
        let mac = hostName.map { "“\($0)”" } ?? "your Mac"
        if hadConnected {
            return "The connection to \(mac) was lost. It may have gone to sleep, or left the network."
        }
        switch error {
        case .posix(.ECONNREFUSED):
            return "Nothing answered at \(address(target)). In MyTerm on the Mac, turn on “Allow my devices to reach this Mac” under Settings, then Devices."
        case .posix(.EHOSTUNREACH), .posix(.ENETUNREACH), .posix(.ETIMEDOUT), .posix(.EHOSTDOWN):
            return "\(address(target)) can’t be reached. Check that this device and the Mac are on the same network, and that the Mac is awake."
        case .dns:
            return "\(address(target)) could not be found on this network."
        case .tls:
            return "The Mac refused the pairing token. Scan a fresh code from Settings, then Devices, on the Mac."
        case .posix(.ECONNRESET), .posix(.EPIPE), .none:
            // A pre-shared key that does not match ends the handshake with a reset, not a TLS alert,
            // so a closed socket before any welcome most often means the token is wrong.
            return "The Mac closed the connection before saying hello. This usually means the pairing token is out of date: scan a fresh code from Settings, then Devices, on the Mac."
        default:
            return "Couldn’t reach \(address(target)). \(error.map { $0.localizedDescription } ?? "")"
                .trimmingCharacters(in: .whitespaces)
        }
    }

    private static func address(_ target: RemoteTarget?) -> String {
        guard let target else { return "the Mac" }
        if !target.host.isEmpty, target.port != 0 {
            return "\(target.host):\(target.port)"
        }
        return target.serviceName.map { "“\($0)”" } ?? "the Mac"
    }
}
