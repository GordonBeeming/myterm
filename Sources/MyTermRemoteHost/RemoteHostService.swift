import Foundation
import MyTermRemoteProtocol
import Network
import Observation

public struct RemoteHostDevice: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

public enum RemoteHostState: Equatable, Sendable {
    case stopped
    case starting
    case listening(port: UInt16)
    case failed(String)
}

/// Accepts device connections and advertises this Mac on the local network.
///
/// Nothing here runs until the user turns the feature on. A listener that exists by default is a
/// remote shell that exists by default.
@MainActor
@Observable
public final class RemoteHostService {
    public private(set) var state: RemoteHostState = .stopped {
        didSet { onStateChanged?(state) }
    }
    /// Fires on every state change, for the app to start or stop what depends on the listener.
    public var onStateChanged: ((RemoteHostState) -> Void)?

    /// The port the listener is on, or nil while it is not listening.
    public var listeningPort: UInt16? {
        if case .listening(let port) = state { return port }
        return nil
    }
    public private(set) var connectedDevices: [RemoteHostDevice] = []

    /// The pairing token. A device proves it holds this by completing the TLS handshake.
    public private(set) var token: String

    /// Whether devices may type and change workspaces. Applies at once to every device already
    /// connected: each is told again what it may do, and its controls follow.
    public var allowsInput: Bool {
        didSet {
            guard allowsInput != oldValue else { return }
            for connection in connections.values {
                connection.sendWelcome()
            }
        }
    }

    /// The port to listen on. When something else holds it, the listener falls back to any free
    /// port and says so through `state`, so pairing still works and the address shown is right.
    public var preferredPort: UInt16 = RemoteProtocol.defaultPort

    /// What devices see this Mac as, and the name it asks to advertise on the local network.
    public let hostName: String
    /// The name Bonjour actually registered, once it has. Another Mac on the network with the
    /// same name gets there first and this one becomes "Name (2)": a device that scans a code
    /// carrying `hostName` would then dial the other Mac, so a pairing code carries this.
    public private(set) var advertisedName: String?
    /// Where the agents' transcripts are. Settable so a test can serve a transcript of its own.
    public var agentProjectsDirectory: URL = AgentTranscriptWatcher.defaultProjectsDirectory
    /// How long a connection that completed the handshake may stay silent before it is dropped.
    public var helloTimeout: Duration = RemoteHostConnection.defaultHelloTimeout
    private let queue = DispatchQueue(label: "com.gordonbeeming.myterm.remote-host")
    private var listener: NWListener?
    /// Listeners told to stop that have not yet said they did.
    private var cancelling: [ObjectIdentifier: NWListener] = [:]
    /// Set by a token rotation: start again once the old listener has let go of its port.
    private var restartsWhenCancelled = false
    /// The port the current listener was asked for, so a failure knows whether a fallback is left.
    private var attemptedPort: NWEndpoint.Port?
    private var connections: [UUID: RemoteHostConnection] = [:]
    private weak var dataSource: (any RemoteHostDataSource)?
    private var treeWatch: Timer?
    private var lastBroadcastRevision: Int?

    public init(
        hostName: String,
        token: String,
        allowsInput: Bool = true,
        dataSource: (any RemoteHostDataSource)? = nil
    ) {
        self.hostName = hostName
        self.token = token
        self.allowsInput = allowsInput
        self.dataSource = dataSource
    }

    public func connect(dataSource: (any RemoteHostDataSource)?) {
        self.dataSource = dataSource
    }

    public func rotateToken() {
        token = RemoteTransportSecurity.makeToken()
        switch state {
        case .listening, .starting:
            // The old socket gives its port back only once its cancel has run on the listener's
            // queue. Starting again before then lands on EADDRINUSE and the fallback port, and
            // the Mac quietly moves off the port every saved pairing names.
            stop()
            restartsWhenCancelled = true
        case .stopped, .failed:
            break
        }
    }

    public func start() {
        restartsWhenCancelled = false
        start(on: NWEndpoint.Port(rawValue: preferredPort) ?? .any)
    }

    private func start(on port: NWEndpoint.Port) {
        guard listener == nil else { return }
        state = .starting
        attemptedPort = port

        do {
            let parameters = RemoteTransportSecurity.parameters(token: token)
            let listener = try NWListener(using: parameters, on: port)
            listener.service = NWListener.Service(
                name: hostName,
                type: RemoteProtocol.bonjourServiceType
            )
            let identity = ObjectIdentifier(listener)
            listener.stateUpdateHandler = { [weak self] listenerState in
                Task { @MainActor [weak self] in
                    self?.handle(listenerState: listenerState, from: identity)
                }
            }
            listener.serviceRegistrationUpdateHandler = { [weak self] change in
                Task { @MainActor [weak self] in
                    self?.handle(registration: change, from: identity)
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    self?.accept(connection)
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    public func stop() {
        // A stop the user asked for outranks a restart a rotation is waiting on.
        restartsWhenCancelled = false
        stopWatchingTree()
        for connection in connections.values {
            connection.close()
        }
        connections.removeAll()
        connectedDevices = []
        if let listener {
            // Nothing that arrives on a cancelled listener is a device. Its state handler stays,
            // because its `.cancelled` is the moment its port is free again, and the listener is
            // held until then so that report is not lost with it.
            listener.newConnectionHandler = { $0.cancel() }
            cancelling[ObjectIdentifier(listener)] = listener
            listener.cancel()
        }
        listener = nil
        advertisedName = nil
        state = .stopped
    }

    private func handle(registration change: NWListener.ServiceRegistrationChange, from source: ObjectIdentifier) {
        guard let current = listener, ObjectIdentifier(current) == source else { return }
        switch change {
        case .add(.service(let name, _, _, _)):
            advertisedName = name
        case .remove(.service(let name, _, _, _)) where name == advertisedName:
            advertisedName = nil
        default:
            break
        }
    }

    /// Pushes the current tree to every connected device.
    public func broadcastTree() {
        guard let tree = dataSource?.remoteTree() else { return }
        lastBroadcastRevision = tree.revision
        for connection in connections.values {
            connection.send(tree: tree)
        }
    }

    /// Sends the tree only when its revision changed.
    ///
    /// The app mutates its workspaces through many paths, and threading a notification through all
    /// of them would touch far more of the app than this feature should. Comparing a cheap revision
    /// keeps the coupling at one call. Deltas and a push replace this once the tree grows.
    private func broadcastTreeIfChanged() {
        guard !connections.isEmpty, let tree = dataSource?.remoteTree() else { return }
        guard tree.revision != lastBroadcastRevision else { return }
        lastBroadcastRevision = tree.revision
        for connection in connections.values {
            connection.send(tree: tree)
        }
    }

    private func startWatchingTree() {
        guard treeWatch == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.broadcastTreeIfChanged()
                self?.pushAgentPrompts()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        treeWatch = timer
    }

    /// Tells each device what the tabs it is following are asking, when that has changed.
    ///
    /// Polled with the tree rather than pushed, because a permission prompt is drawn on the screen
    /// and nothing in the app announces it. A device learns about it the same second the Mac does.
    private func pushAgentPrompts() {
        for connection in connections.values {
            for tabID in connection.followedAgentTabs {
                connection.pushPrompt(tabID: tabID)
            }
        }
    }

    private func stopWatchingTree() {
        treeWatch?.invalidate()
        treeWatch = nil
        lastBroadcastRevision = nil
    }

    public func broadcast(agentActivity: RemoteAgentActivity) {
        for connection in connections.values {
            connection.send(agentActivity: agentActivity)
        }
    }

    public func broadcast(notifications: RemoteNotifications) {
        for connection in connections.values {
            connection.send(notifications: notifications)
        }
    }

    private func handle(listenerState: NWListener.State, from source: ObjectIdentifier) {
        guard let current = listener, ObjectIdentifier(current) == source else {
            // A listener that was stopped or replaced. A restart may have a new one up by now
            // whose state must not be overwritten with the old one's; its cancel completing is
            // the one thing worth hearing, because a restart that wants the same port waits on it.
            if case .cancelled = listenerState {
                cancelling.removeValue(forKey: source)
                if restartsWhenCancelled, cancelling.isEmpty, self.listener == nil {
                    start()
                }
            }
            return
        }
        switch listenerState {
        case .ready:
            state = .listening(port: listener?.port?.rawValue ?? 0)
        case .failed(let error):
            listener?.cancel()
            listener = nil
            // The fixed port belongs to something else, so take any port rather than stay off.
            // The pairing code carries whatever port was won, so a device still finds this Mac.
            if case .posix(.EADDRINUSE) = error, attemptedPort != .any {
                start(on: .any)
                return
            }
            state = .failed(error.localizedDescription)
        case .cancelled:
            state = .stopped
        default:
            break
        }
    }

    private func accept(_ nwConnection: NWConnection) {
        let identifier = UUID()
        let connection = RemoteHostConnection(
            connection: nwConnection,
            hostName: hostName,
            allowsInput: { [weak self] in self?.allowsInput ?? false },
            dataSource: dataSource,
            projectsDirectory: agentProjectsDirectory,
            helloTimeout: helloTimeout
        )
        connection.onClosed = { [weak self] in
            Task { @MainActor [weak self] in
                self?.connections.removeValue(forKey: identifier)
                self?.refreshDevices()
                if self?.connections.isEmpty == true {
                    self?.stopWatchingTree()
                }
            }
        }
        connection.onStateChanged = { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshDevices()
            }
        }
        connection.onTreeMutated = { [weak self] in
            // Every device, not just the one that asked. Two iPads looking at the same workspace
            // must not disagree about whether a tab still exists.
            self?.broadcastTree()
        }
        connections[identifier] = connection
        connection.start(queue: queue)
        startWatchingTree()
    }

    private func refreshDevices() {
        connectedDevices = connections
            .compactMap { identifier, connection in
                connection.deviceName.map { RemoteHostDevice(id: identifier, name: $0) }
            }
            .sorted { $0.name < $1.name }
    }
}
