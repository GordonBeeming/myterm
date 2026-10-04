import AppKit
import CryptoKit
import Network
@preconcurrency import WebKit
import Foundation
import MyTermCore
import MyTermPlatform
import MyTermRemote
import Security
import SwiftTerm
import XCTest
@testable import MyTerm

private final class FixtureTrustDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable
{
    static let challengeSelector = NSSelectorFromString(
        "URLSession:didReceiveChallenge:completionHandler:"
    )

    private let certificate: SecCertificate
    private let endpoint: RelayEndpoint
    private let diagnostics: FixtureNetworkDiagnostics

    init(
        certificate: SecCertificate,
        endpoint: RelayEndpoint,
        diagnostics: FixtureNetworkDiagnostics
    ) {
        self.certificate = certificate
        self.endpoint = endpoint
        self.diagnostics = diagnostics
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let url = request.url, endpoint.hasSameSecureAuthority(as: url) else {
            completionHandler(nil)
            return
        }
        var redirected = request
        if let authorization = task.originalRequest?.value(forHTTPHeaderField: "Authorization") {
            redirected.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        completionHandler(redirected)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard let error else { return }
        diagnostics.record(error)
    }
}

private extension FixtureTrustDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let challengeURL = challenge.protectionSpace.protectionSpaceURL,
              endpoint.hasSameSecureAuthority(as: challengeURL),
              SecTrustSetAnchorCertificates(trust, [certificate] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess else {
            diagnostics.record("TLS challenge rejected")
            return (.cancelAuthenticationChallenge, nil)
        }
        diagnostics.record("TLS challenge accepted")
        return (.useCredential, URLCredential(trust: trust))
    }
}

private final class FixtureNetworkDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    private var currentStage = "launch relay fixture"

    func setStage(_ stage: String) {
        lock.withLock { currentStage = stage }
        FileHandle.standardError.write(Data("Integration stage: \(stage)\n".utf8))
    }

    func record(_ message: String) {
        lock.withLock {
            if entries.count < 32 { entries.append(message) }
        }
    }

    func record(_ error: any Error) {
        let value = error as NSError
        record("\(value.domain) code \(value.code)")
    }

    var summary: String {
        lock.withLock { entries.joined(separator: ", ") }
    }

    var stage: String {
        lock.withLock { currentStage }
    }

    func contains(_ entry: String) -> Bool {
        lock.withLock { entries.contains(entry) }
    }
}

@MainActor
final class CompanionHostIntegrationTests: XCTestCase {
    private let browserRendererID = UUID()
    private final class MemorySecrets: SecretStore, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Data] = [:]

        func read(account: String) throws -> Data? {
            lock.withLock { values[account] }
        }

        func write(_ data: Data, account: String) throws {
            lock.withLock { values[account] = data }
        }

        func delete(account: String) throws {
            _ = lock.withLock { values.removeValue(forKey: account) }
        }
    }

    private final class CheckpointDelegate: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    private final class ShellEngine: TerminalEngine {
        func makeSession(
            configuration: TerminalSessionConfiguration
        ) throws -> any TerminalProcessSession {
            try SwiftTermTerminalSession(
                configuration: TerminalSessionConfiguration(
                    shell: URL(fileURLWithPath: "/bin/sh"),
                    workingDirectory: configuration.workingDirectory,
                    shellArguments: [],
                    environment: ["ENV": "/dev/null"],
                    runtimeConfiguration: configuration.runtimeConfiguration
                )
            )
        }
    }

    private actor RelayEventReader {
        private struct Waiter {
            let continuation: CheckedContinuation<RelayTransportEvent?, Error>
            let timeout: Task<Void, Never>
        }

        private var buffered: [RelayTransportEvent] = []
        private var waiters: [UUID: Waiter] = [:]
        private var completion: Result<Void, Error>?

        init(_ stream: AsyncThrowingStream<RelayTransportEvent, Error>) {
            Task { [weak self] in
                do {
                    for try await event in stream { await self?.yield(event) }
                    await self?.finish(.success(()))
                } catch {
                    await self?.finish(.failure(error))
                }
            }
        }

        func next(timeout: Duration = .seconds(8)) async throws -> RelayTransportEvent? {
            if !buffered.isEmpty { return buffered.removeFirst() }
            if let completion {
                switch completion {
                case .success: return nil
                case .failure(let error): throw error
                }
            }
            let id = UUID()
            return try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    await self?.expire(id)
                }
                waiters[id] = Waiter(continuation: continuation, timeout: timeoutTask)
            }
        }

        private func yield(_ event: RelayTransportEvent) {
            if let id = waiters.keys.first, let waiter = waiters.removeValue(forKey: id) {
                waiter.timeout.cancel()
                waiter.continuation.resume(returning: event)
            } else {
                buffered.append(event)
            }
        }

        private func finish(_ result: Result<Void, Error>) {
            guard completion == nil else { return }
            completion = result
            let pending = waiters.values
            waiters.removeAll()
            for waiter in pending {
                waiter.timeout.cancel()
                switch result {
                case .success: waiter.continuation.resume(returning: nil)
                case .failure(let error): waiter.continuation.resume(throwing: error)
                }
            }
        }

        private func expire(_ id: UUID) {
            guard let waiter = waiters.removeValue(forKey: id) else { return }
            waiter.continuation.resume(throwing: RemoteError.timedOut)
        }
    }

    private actor ReconnectRecorder {
        private(set) var delays: [TimeInterval] = []

        func record(_ delay: TimeInterval) {
            delays.append(delay)
        }
    }

    private struct RelayFixture: Decodable {
        let url: URL
        let certificatePath: String
        let accountID: UUID
        let hostDeviceID: UUID
        let hostToken: String
        let clientDeviceID: UUID
        let clientToken: String

        enum CodingKeys: String, CodingKey {
            case url
            case certificatePath = "certificate_path"
            case accountID = "account_id"
            case hostDeviceID = "host_device_id"
            case hostToken = "host_token"
            case clientDeviceID = "client_device_id"
            case clientToken = "client_token"
        }
    }

    private struct PhoneConnection: Sendable {
        let socket: RelayWebSocketClient
        let reader: RelayEventReader
        let channel: SecureRelayChannel
        let runtimeID: UUID
    }

    private struct TerminalTarget {
        let workspaceID: UUID
        let groupID: UUID
        let tabID: UUID
        let sessionID: UUID
    }

    func testFixtureFailureDiagnosticsPreserveStageWithoutSecrets() throws {
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("myterm-fixture-diagnostics-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: logURL) }
        try Data("server started\nAuthorization: Bearer private-token\n".utf8).write(to: logURL)
        let diagnostics = FixtureNetworkDiagnostics()
        diagnostics.setStage("register and connect Mac host")
        diagnostics.record(NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost))

        let error = fixtureIntegrationError(
            stage: diagnostics.stage,
            underlying: RemoteError.offline,
            serverLogURL: logURL,
            networkDiagnostics: diagnostics
        )
        let description = error.localizedDescription

        XCTAssertTrue(description.contains("register and connect Mac host"))
        XCTAssertTrue(description.contains("NSURLErrorDomain code -1004"))
        XCTAssertTrue(description.contains("server started"))
        XCTAssertTrue(description.contains("[redacted sensitive fixture log line]"))
        XCTAssertFalse(description.contains("private-token"))
        XCTAssertFalse(description.contains("Authorization"))
    }

    func testRealRelayHostPairingCheckpointLeaseGeometryAndPTYIO() async throws {
        let launched = try await launchRelayFixture()
        let process = launched.process
        let tempDirectory = launched.tempDirectory
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        let networkDiagnostics = FixtureNetworkDiagnostics()
        do {
            try await runCompanionHostIntegration(
                launched: launched,
                networkDiagnostics: networkDiagnostics
            )
        } catch {
            print("Companion integration failure stage: \(networkDiagnostics.stage)")
            throw fixtureIntegrationError(
                stage: networkDiagnostics.stage,
                underlying: error,
                serverLogURL: launched.serverLogURL,
                networkDiagnostics: networkDiagnostics
            )
        }
    }

    private func runCompanionHostIntegration(
        launched: (process: Process, tempDirectory: URL, fixture: RelayFixture, serverLogURL: URL),
        networkDiagnostics: FixtureNetworkDiagnostics
    ) async throws {
        networkDiagnostics.setStage("configure fixture TLS")
        let fixture = launched.fixture
        let endpoint = try RelayEndpoint(fixture.url)
        let hostSession = try fixtureSession(
            fixture: fixture,
            endpoint: endpoint,
            diagnostics: networkDiagnostics
        )
        let secrets = MemorySecrets()
        let reconnects = ReconnectRecorder()
        let defaultsSuite = "myterm-companion-integration-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defaults.set(false, forKey: "automaticallyChecksForUpdates")
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }

        let supportDirectory = launched.tempDirectory.appendingPathComponent(
            "app-support",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        networkDiagnostics.setStage("create scratch AppModel and PTYs")
        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: supportDirectory,
            terminalEngine: ShellEngine(),
            browserSettings: BrowserSettingsStore(channel: .development, defaults: defaults),
            browserLauncherURL: nil,
            updates: UpdateController(
                channel: .development,
                currentVersion: "0.0.0-test",
                defaults: defaults,
                fetch: { _ in Data() }
            ),
            agentNotifications: AgentNotificationSettings(
                channel: .development,
                defaults: defaults
            ),
            makeCompanionHost: { model, channel, namespace in
                CompanionHostModel(
                    appModel: model,
                    channel: channel,
                    storageNamespace: namespace,
                    sleep: { delay in await reconnects.record(delay) },
                    jitter: { 0.5 },
                    secrets: secrets,
                    defaults: defaults,
                    makeHTTPClient: { relay in
                        RelayHTTPClient(endpoint: relay, timeout: 5, session: hostSession)
                    },
                    makeTransport: { relay, hostID, role in
                        RelayWebSocketClient(
                            endpoint: relay,
                            hostID: hostID,
                            role: role,
                            session: hostSession
                        )
                    }
                )
            }
        )
        model.splitFocusedTerminal(orientation: .horizontal)
        XCTAssertNil(model.errorDescription)
        let host = model.companionHost
        try await host.installAuthenticatedSessionForTesting(
            TokenRecord(
                relay: endpoint,
                accountID: fixture.accountID,
                deviceID: fixture.hostDeviceID,
                accessToken: fixture.hostToken,
                refreshToken: "unused-by-fixture",
                expiresAt: Date().addingTimeInterval(3_600)
            )
        )
        networkDiagnostics.setStage("register and connect Mac host")
        host.startIfEnabled()
        try await waitUntil { host.status == .connected }
        guard networkDiagnostics.contains("TLS challenge accepted") else {
            throw NSError(
                domain: "RelayFixtureTLSDelegate",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "The fixture connected without exercising its pinned TLS challenge handler.",
                ]
            )
        }

        let identity = try await host.hostIdentityForTesting()
        let ticket = try await host.beginPairingForTesting()
        XCTAssertEqual(ticket.expiresAt.timeIntervalSinceNow, 60, accuracy: 1)
        let clientAgreementKey = P256.KeyAgreement.PrivateKey()
        let clientSigningKey = P256.Signing.PrivateKey()
        networkDiagnostics.setStage("connect first phone transport")
        let firstSocket = RelayWebSocketClient(
            endpoint: endpoint,
            hostID: identity.hostID,
            role: .client,
            session: try fixtureSession(
                fixture: fixture,
                endpoint: endpoint,
                diagnostics: networkDiagnostics
            )
        )
        let firstReader = RelayEventReader(try await firstSocket.connect(accessToken: fixture.clientToken))
        _ = try await requireReady(firstReader)
        let proposal = PairingProposal(
            ticketID: ticket.ticketID,
            secret: ticket.secret,
            clientDeviceID: fixture.clientDeviceID,
            clientPublicKey: clientAgreementKey.publicKey.x963Representation,
            clientNotificationSigningPublicKey: clientSigningKey.publicKey.x963Representation,
            clientName: "Integration Phone"
        )
        networkDiagnostics.setStage("pair first phone")
        try await firstSocket.send(
            destinationConnectionID: RelayFrame.broadcastDestination,
            payload: RelayApplicationPacket.pairingProposal(
                try PairingCrypto.sealProposal(proposal, ticket: ticket)
            ).encoded()
        )
        try await waitUntil { host.pendingPairing?.id == ticket.ticketID }
        host.answerPairing(approved: true)
        let responsePayload = try await requireApplication(firstReader)
        guard case .pairingResponse(let sealedResponse) = try RelayApplicationPacket.decode(responsePayload)
        else { throw RemoteError.invalidMessage }
        let pairingResponse = try PairingCrypto.openResponse(
            sealedResponse,
            relay: endpoint,
            hostID: identity.hostID,
            clientIdentity: clientAgreementKey,
            pinnedHostKey: identity.agreementKey.publicKey
        )
        XCTAssertTrue(pairingResponse.approved)

        networkDiagnostics.setStage("authenticate first phone")
        let first = try await authenticate(
            socket: firstSocket,
            reader: firstReader,
            endpoint: endpoint,
            fixture: fixture,
            hostIdentity: identity,
            clientAgreementKey: clientAgreementKey,
            clientSigningKey: clientSigningKey
        )
        defer { Task { await firstSocket.disconnect() } }
        let projection = try await requireWorkspaceProjection(first)
        let target = try terminalTarget(in: projection)
        let destinationGroupID = try XCTUnwrap(
            projection.workspaces
                .first(where: { $0.id.rawValue == target.workspaceID })?
                .groups
                .first(where: { $0.id.rawValue != target.groupID })?
                .id.rawValue
        )
        let targetMetadata = metadata(target: target, hostID: identity.hostID, runtimeID: first.runtimeID)

        let browserPhone = try await makeAuthenticatedConnection(
            endpoint: endpoint, fixture: fixture,
            session: try fixtureSession(fixture: fixture, endpoint: endpoint, diagnostics: networkDiagnostics),
            hostIdentity: identity, clientAgreementKey: clientAgreementKey,
            clientSigningKey: clientSigningKey
        )
        _ = try await requireWorkspaceProjection(browserPhone)
        networkDiagnostics.setStage("exercise both browsers through encrypted relay")
        try await exerciseRemoteBrowsers(model: model, connection: browserPhone,
            hostID: identity.hostID, directory: launched.tempDirectory.appendingPathComponent("browser-origin"))

        networkDiagnostics.setStage("attach first phone and import checkpoint")
        try await first.channel.send(
            .attach(targetMetadata, AttachParameters()),
            destinationConnectionID: RelayFrame.broadcastDestination,
            over: first.socket
        )
        let checkpoint = try await requireCheckpoint(first, sessionID: target.sessionID)
        let checkpointDelegate = CheckpointDelegate()
        let restoredTerminal = Terminal(delegate: checkpointDelegate)
        try restoredTerminal.importCheckpoint(checkpoint.bytes)
        XCTAssertEqual(try restoredTerminal.exportCheckpoint(), checkpoint.bytes)

        networkDiagnostics.setStage("acquire first controller lease")
        try await first.channel.send(
            .controlRequest(
                targetMetadata,
                ControlRequestParameters(action: .acquire)
            ),
            destinationConnectionID: RelayFrame.broadcastDestination,
            over: first.socket
        )
        let acquired = try await requireControlState(first) { $0.leaseID != nil }
        var leaseID = try XCTUnwrap(acquired.leaseID)
        XCTAssertEqual(acquired.generation, checkpoint.identity.generation)

        let firstMarker = "MYTERM-HOST-INTEGRATION-ONE"
        try await sendInput(
            "printf '\(firstMarker)\\n'\n",
            leaseID: leaseID,
            generation: acquired.generation,
            metadata: targetMetadata,
            connection: first
        )
        try await requireOutput(first, containing: firstMarker)

        networkDiagnostics.setStage("authenticate and attach second phone")
        let second = try await makeAuthenticatedConnection(
            endpoint: endpoint,
            fixture: fixture,
            session: try fixtureSession(
                fixture: fixture,
                endpoint: endpoint,
                diagnostics: networkDiagnostics
            ),
            hostIdentity: identity,
            clientAgreementKey: clientAgreementKey,
            clientSigningKey: clientSigningKey
        )
        defer { Task { await second.socket.disconnect() } }
        _ = try await requireWorkspaceProjection(second)
        let secondMetadata = metadata(target: target, hostID: identity.hostID, runtimeID: second.runtimeID)
        try await second.channel.send(
            .attach(secondMetadata, AttachParameters()),
            destinationConnectionID: RelayFrame.broadcastDestination,
            over: second.socket
        )
        _ = try await requireCheckpoint(second, sessionID: target.sessionID)

        networkDiagnostics.setStage("move attached terminal and continue PTY input")
        try await first.channel.send(
            .command(
                targetMetadata,
                CommandParameters(
                    operation: .tabMove,
                    payload: try JSONEncoder().encode(RemoteTabMovePayload(
                        destinationGroupID: TabGroupID(rawValue: destinationGroupID)
                    ))
                )
            ),
            destinationConnectionID: RelayFrame.broadcastDestination,
            over: first.socket
        )
        let movedControl = try await requireControlStateMessage(first) { metadata, _ in
            metadata.sessionID == target.sessionID && metadata.groupID == destinationGroupID
        }
        XCTAssertEqual(movedControl.metadata.tabID, target.tabID)
        XCTAssertEqual(movedControl.state.leaseID, leaseID)

        let movedMarker = "MYTERM-HOST-AFTER-MOVE"
        try await sendInput(
            "printf '\(movedMarker)\\n'\n",
            leaseID: leaseID,
            generation: acquired.generation,
            metadata: targetMetadata,
            connection: first
        )
        try await requireOutput(first, containing: movedMarker)

        let deniedRequestID = UUID()
        let deniedMetadata = MessageMetadata(
            requestID: deniedRequestID,
            hostID: identity.hostID,
            runtimeID: second.runtimeID,
            sessionID: target.sessionID,
            workspaceID: target.workspaceID,
            groupID: target.groupID,
            tabID: target.tabID
        )
        networkDiagnostics.setStage("deny contended control without disconnect")
        try await second.channel.send(
            .controlRequest(
                deniedMetadata,
                ControlRequestParameters(action: .acquire)
            ),
            destinationConnectionID: RelayFrame.broadcastDestination,
            over: second.socket
        )
        let denied = try await requireError(second, code: "control_denied")
        XCTAssertEqual(denied.metadata.requestID, deniedRequestID)
        XCTAssertEqual(denied.metadata.groupID, destinationGroupID)
        XCTAssertTrue(denied.error.retryable)
        let deniedState = try await requireControlState(second) { $0.leaseID == leaseID }
        XCTAssertNotNil(deniedState.controllerConnectionID)
        try await second.channel.send(
            .workspaceRequest(
                MessageMetadata(
                    requestID: UUID(),
                    hostID: identity.hostID,
                    runtimeID: second.runtimeID
                ),
                WorkspaceRequestParameters()
            ),
            destinationConnectionID: RelayFrame.broadcastDestination,
            over: second.socket
        )
        _ = try await requireWorkspaceProjection(second)

        networkDiagnostics.setStage("resize controller and broadcast geometry")
        try await first.channel.send(
            .resize(
                targetMetadata,
                ResizeParameters(
                    leaseID: leaseID,
                    generation: acquired.generation,
                    columns: 93,
                    rows: 31
                )
            ),
            destinationConnectionID: RelayFrame.broadcastDestination,
            over: first.socket
        )
        let resizedMarker = "MYTERM-HOST-AFTER-RESIZE"
        try await sendInput(
            "printf '\(resizedMarker)\\n'\n",
            leaseID: leaseID,
            generation: acquired.generation,
            metadata: targetMetadata,
            connection: first
        )
        let firstGeometry = try await requireControlState(first) {
            $0.columns == 93 && $0.rows == 31
        }
        let secondGeometry = try await requireControlState(second) {
            $0.columns == 93 && $0.rows == 31
        }
        XCTAssertEqual(firstGeometry.generation, acquired.generation)
        XCTAssertEqual(secondGeometry.generation, acquired.generation)
        let hostGeometry = try XCTUnwrap(
            model.companionTerminalSession(TerminalSessionID(rawValue: target.sessionID))
        ).remoteGeometry
        XCTAssertEqual(hostGeometry.columns, 93)
        XCTAssertEqual(hostGeometry.rows, 31)
        try await requireOutput(first, containing: resizedMarker)

        networkDiagnostics.setStage("Mac takeover rejects late control packets without disconnecting viewers")
        host.takeControl(sessionID: TerminalSessionID(rawValue: target.sessionID))
        _ = try await requireControlState(first) { $0.controllerConnectionID == nil }
        _ = try await requireControlState(second) { $0.controllerConnectionID == nil }
        XCTAssertFalse(host.locallyPausedSessions.contains(TerminalSessionID(rawValue: target.sessionID)))
        try await sendInput("printf 'STALE-MUST-NOT-RUN\\n'\n", leaseID: leaseID,
                            generation: acquired.generation, metadata: targetMetadata, connection: first)
        _ = try await requireError(first, code: "control_denied")
        try await first.channel.send(
            .resize(targetMetadata, ResizeParameters(leaseID: leaseID, generation: acquired.generation,
                                                     columns: 77, rows: 22)),
            destinationConnectionID: RelayFrame.broadcastDestination, over: first.socket
        )
        _ = try await requireError(first, code: "control_denied")
        for imageLease in [leaseID, UUID()] {
            let image = try RemoteTerminalImagePayload(leaseID: imageLease, generation: acquired.generation,
                                                       contentType: .png, bytes: Data([1]))
            let chunk = try RemoteImageChunkPayload(transferID: UUID(), leaseID: imageLease,
                generation: acquired.generation, contentType: .png, chunkIndex: 0,
                chunkCount: 1, totalBytes: 1, bytes: Data([1]))
            for (operation, payload) in [
                (CommandOperation.terminalPasteImage, try JSONEncoder().encode(image)),
                (CommandOperation.terminalPasteImageChunk, try JSONEncoder().encode(chunk))
            ] {
                let request = metadata(target: target, hostID: identity.hostID, runtimeID: first.runtimeID)
                try await first.channel.send(.command(request, CommandParameters(operation: operation, payload: payload)),
                    destinationConnectionID: RelayFrame.broadcastDestination, over: first.socket)
                while true {
                    let packet = try await requireApplication(first.reader)
                    let message = try await first.channel.open(packet)
                    if case .commandResult(let response, let result) = message,
                       response.requestID == request.requestID {
                        XCTAssertFalse(result.succeeded)
                        XCTAssertEqual(result.errorCode, "control_denied")
                        break
                    }
                }
            }
        }
        for connection in [first, second] {
            try await connection.channel.send(
                .workspaceRequest(MessageMetadata(requestID: UUID(), hostID: identity.hostID,
                                                   runtimeID: connection.runtimeID), WorkspaceRequestParameters()),
                destinationConnectionID: RelayFrame.broadcastDestination, over: connection.socket
            )
            _ = try await requireWorkspaceProjection(connection)
        }
        // Explicitly regain remote control for the remainder of the test.
        try await first.channel.send(.controlRequest(targetMetadata, ControlRequestParameters(action: .acquire)),
                                     destinationConnectionID: RelayFrame.broadcastDestination, over: first.socket)
        let reacquired = try await requireControlState(first) { $0.leaseID != nil }
        leaseID = try XCTUnwrap(reacquired.leaseID)
        XCTAssertTrue(host.locallyPausedSessions.contains(TerminalSessionID(rawValue: target.sessionID)))

        networkDiagnostics.setStage("reject forged lease")
        try await second.channel.send(
            .input(
                secondMetadata,
                InputParameters(
                    leaseID: UUID(),
                    generation: acquired.generation,
                    bytes: Data("printf 'MUST-NOT-RUN\\n'\n".utf8)
                )
            ),
            destinationConnectionID: RelayFrame.broadcastDestination,
            over: second.socket
        )
        try await requireDisconnect(second.reader)

        let secondMarker = "MYTERM-HOST-INTEGRATION-TWO"
        try await sendInput(
            "printf '\(secondMarker)\\n'\n",
            leaseID: leaseID,
            generation: acquired.generation,
            metadata: targetMetadata,
            connection: first
        )
        try await requireOutput(first, containing: secondMarker)

        networkDiagnostics.setStage("reject stale runtime")
        let stale = try await makeAuthenticatedConnection(
            endpoint: endpoint,
            fixture: fixture,
            session: try fixtureSession(
                fixture: fixture,
                endpoint: endpoint,
                diagnostics: networkDiagnostics
            ),
            hostIdentity: identity,
            clientAgreementKey: clientAgreementKey,
            clientSigningKey: clientSigningKey
        )
        defer { Task { await stale.socket.disconnect() } }
        _ = try await requireWorkspaceProjection(stale)
        try await stale.channel.send(
            .workspaceRequest(
                MessageMetadata(requestID: UUID(), hostID: identity.hostID, runtimeID: UUID()),
                WorkspaceRequestParameters()
            ),
            destinationConnectionID: RelayFrame.broadcastDestination,
            over: stale.socket
        )
        try await requireDisconnect(stale.reader)

        networkDiagnostics.setStage("detach while keeping PTY running")
        try await first.channel.send(
            .detach(targetMetadata, DetachParameters()),
            destinationConnectionID: RelayFrame.broadcastDestination,
            over: first.socket
        )
        try await first.channel.send(
            .workspaceRequest(
                MessageMetadata(
                    requestID: UUID(),
                    hostID: identity.hostID,
                    runtimeID: first.runtimeID
                ),
                WorkspaceRequestParameters()
            ),
            destinationConnectionID: RelayFrame.broadcastDestination,
            over: first.socket
        )
        _ = try await requireWorkspaceProjection(first)
        XCTAssertTrue(
            try XCTUnwrap(
                model.companionTerminalSession(TerminalSessionID(rawValue: target.sessionID))
            ).isRunning
        )
        XCTAssertTrue(host.remoteControllers.isEmpty)
        XCTAssertTrue(host.locallyPausedSessions.contains(TerminalSessionID(rawValue: target.sessionID)),
                      "The Mac must not automatically retake control when the companion detaches")
        host.takeControl(sessionID: TerminalSessionID(rawValue: target.sessionID))
        XCTAssertFalse(host.locallyPausedSessions.contains(TerminalSessionID(rawValue: target.sessionID)))

        networkDiagnostics.setStage("controller disconnect does not automatically resume Mac input")
        let reattachMetadata = MessageMetadata(requestID: UUID(), hostID: identity.hostID,
            runtimeID: first.runtimeID, sessionID: target.sessionID,
            workspaceID: target.workspaceID, groupID: destinationGroupID, tabID: target.tabID)
        try await first.channel.send(.attach(reattachMetadata, AttachParameters()),
                                     destinationConnectionID: RelayFrame.broadcastDestination, over: first.socket)
        networkDiagnostics.setStage("receive reattached checkpoint")
        _ = try await requireCheckpoint(first, sessionID: target.sessionID)
        networkDiagnostics.setStage("request reattached control")
        try await first.channel.send(.controlRequest(reattachMetadata, ControlRequestParameters(action: .acquire)),
                                     destinationConnectionID: RelayFrame.broadcastDestination, over: first.socket)
        _ = try await requireControlState(first) { $0.leaseID != nil && $0.leaseID != leaseID }
        let observer = try await makeAuthenticatedConnection(
            endpoint: endpoint, fixture: fixture,
            session: try fixtureSession(fixture: fixture, endpoint: endpoint, diagnostics: networkDiagnostics),
            hostIdentity: identity, clientAgreementKey: clientAgreementKey, clientSigningKey: clientSigningKey
        )
        defer { Task { await observer.socket.disconnect() } }
        _ = try await requireWorkspaceProjection(observer)
        let observerMetadata = MessageMetadata(requestID: UUID(), hostID: identity.hostID,
            runtimeID: observer.runtimeID, sessionID: target.sessionID,
            workspaceID: target.workspaceID, groupID: destinationGroupID, tabID: target.tabID)
        try await observer.channel.send(.attach(observerMetadata, AttachParameters()),
                                        destinationConnectionID: RelayFrame.broadcastDestination, over: observer.socket)
        _ = try await requireCheckpoint(observer, sessionID: target.sessionID)
        _ = try await requireControlState(observer) { $0.leaseID != nil }
        networkDiagnostics.setStage("close controller socket")
        await first.socket.disconnect()
        networkDiagnostics.setStage("wait for controller socket removal")
        try await waitUntil { host.remoteControllers.isEmpty }
        _ = try await requireControlState(observer) { $0.controllerConnectionID == nil && $0.leaseID == nil }
        XCTAssertTrue(host.locallyPausedSessions.contains(TerminalSessionID(rawValue: target.sessionID)))
        host.takeControl(sessionID: TerminalSessionID(rawValue: target.sessionID))
        XCTAssertFalse(host.locallyPausedSessions.contains(TerminalSessionID(rawValue: target.sessionID)))

        networkDiagnostics.setStage("reconnect after transport loss")
        await host.disconnectTransportForTesting()
        try await waitUntilAsync {
            await reconnects.delays == [1]
        }
        try await waitUntil { host.status == .connected }

        host.disconnect()
        host.startIfEnabled()
        XCTAssertEqual(host.status, .disconnected)
    }

    private actor BrowserPacketCounter {
        private(set) var chunks = 0
        private(set) var error: String?
        func record(_ parameters: BrowserTunnelParameters) {
            if parameters.action == .data { chunks += 1 }
        }
        func fail(_ value: String) { error = value }
    }

    private func exerciseRemoteBrowsers(model: AppModel, connection: PhoneConnection,
                                        hostID: UUID, directory: URL) async throws {
        let origin = try await BrowserHTTPFixture.start(in: directory)
        defer { origin.stop() }
        let workspaceID = model.store.selectedWorkspaceID
        let groupID = model.store.selectedWorkspace.focusedTabGroupID
        let pageURL = origin.origin.appendingPathComponent("index.html")
        let tabID = try model.store.addBrowserTab(to: workspaceID, tabGroupID: groupID,
            url: pageURL, selectsCreatedTab: false)
        let route = MessageMetadata(hostID: hostID, runtimeID: connection.runtimeID,
            workspaceID: workspaceID.rawValue, groupID: groupID.rawValue, tabID: tabID.rawValue)

        var frame = try await browserCommand(.init(action: .open, width: 800, height: 600),
                                              route: route, connection: connection)
        for _ in 0..<40 where frame.title != "RELAY FETCH OK" {
            try await Task.sleep(for: .milliseconds(150))
            frame = try await browserCommand(.init(action: .snapshot, width: 800, height: 600),
                                             route: route, connection: connection)
        }
        XCTAssertEqual(frame.title, "RELAY FETCH OK", frame.error ?? "Rendered page did not load")
        XCTAssertNotNil(NSImage(data: frame.image), "A real rendered JPEG must cross the relay")
        XCTAssertEqual(frame.width, 800)
        XCTAssertEqual(frame.height, 600)
        frame = try await browserCommand(.init(action: .tap, width: 800, height: 600, x: 0.1, y: 0.04),
                                         route: route, connection: connection)
        for _ in 0..<40 where frame.title != "Browser next" {
            try await Task.sleep(for: .milliseconds(150))
            frame = try await browserCommand(.init(action: .snapshot, width: 800, height: 600),
                                             route: route, connection: connection)
        }
        XCTAssertEqual(frame.title, "Browser next", frame.error ?? "Remote tap did not navigate")
        frame = try await browserCommand(.init(action: .back, width: 800, height: 600), route: route, connection: connection)
        for _ in 0..<40 where frame.title != "RELAY FETCH OK" {
            try await Task.sleep(for: .milliseconds(150))
            frame = try await browserCommand(.init(action: .snapshot, width: 800, height: 600), route: route, connection: connection)
        }
        _ = try await browserCommand(.init(action: .tap, width: 800, height: 600, x: 0.1, y: 0.14), route: route, connection: connection)
        frame = try await browserCommand(.init(action: .text, width: 800, height: 600, text: "REMOTE TYPED"), route: route, connection: connection)
        XCTAssertEqual(frame.title, "REMOTE TYPED", "Text input must execute on the Mac page")
        _ = try await browserCommand(.init(action: .close, rendererID: UUID(), width: 800, height: 600), route: route, connection: connection)
        frame = try await browserCommand(.init(action: .snapshot, width: 800, height: 600), route: route, connection: connection)
        XCTAssertEqual(frame.title, "REMOTE TYPED", "A stale renderer owner must not close its replacement")
        frame = try await browserCommand(.init(action: .navigate, width: 800, height: 600,
            url: origin.origin.appendingPathComponent("redirect").absoluteString), route: route, connection: connection)
        for _ in 0..<40 where frame.title != "Browser next" {
            try await Task.sleep(for: .milliseconds(150))
            frame = try await browserCommand(.init(action: .snapshot, width: 800, height: 600), route: route, connection: connection)
        }
        XCTAssertEqual(frame.title, "Browser next")
        _ = try await browserCommand(.init(action: .close, width: 800, height: 600), route: route, connection: connection)

        for (path, title) in [("socket-test.html", "RELAY WEBSOCKET OK"), ("post-test.html", "RELAY POST through-relay")] {
            frame = try await browserCommand(.init(action: .open, width: 800, height: 600,
                url: origin.origin.appendingPathComponent(path).absoluteString), route: route, connection: connection)
            for _ in 0..<40 where frame.title != title {
                try await Task.sleep(for: .milliseconds(150))
                frame = try await browserCommand(.init(action: .snapshot, width: 800, height: 600), route: route, connection: connection)
            }
            XCTAssertEqual(frame.title, title, frame.error ?? "Remote browser network operation did not finish")
            _ = try await browserCommand(.init(action: .close, width: 800, height: 600), route: route, connection: connection)
        }

        // A file tab grants only its artifact directory; the companion never reads local disk.
        let artifactURL = directory.appendingPathComponent("index.html")
        try model.store.updateWorkspaceSettings(workspaceID) { $0.allowsLocalFileJavaScript = true }
        try model.store.updateBrowserURL(workspaceID: workspaceID, tabGroupID: groupID, tabID: tabID, url: artifactURL)
        frame = try await browserCommand(.init(action: .open, width: 800, height: 600), route: route, connection: connection)
        for _ in 0..<40 where frame.title != "RELAY FETCH OK" {
            try await Task.sleep(for: .milliseconds(150))
            frame = try await browserCommand(.init(action: .snapshot, width: 800, height: 600), route: route, connection: connection)
        }
        XCTAssertEqual(frame.title, "RELAY FETCH OK", frame.error ?? "Mac artifact did not load")
        XCTAssertEqual(frame.url, artifactURL.absoluteString)
        _ = try await browserCommand(.init(action: .close, width: 800, height: 600), route: route, connection: connection)
        let symlink = directory.appendingPathComponent("link.html")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: artifactURL)
        for unavailableURL in [directory.appendingPathComponent("missing.html"), symlink, directory] {
            let unavailableTab = try model.store.addBrowserTab(to: workspaceID, tabGroupID: groupID,
                url: unavailableURL, selectsCreatedTab: false)
            let unavailableRoute = MessageMetadata(hostID: hostID, runtimeID: connection.runtimeID,
                workspaceID: workspaceID.rawValue, groupID: groupID.rawValue, tabID: unavailableTab.rawValue)
            let streamID = UUID()
            try await connection.channel.send(.browserTunnel(unavailableRoute,
                .init(streamID: streamID, action: .open,
                      host: UUID().uuidString.lowercased() + ".myterm-artifact.invalid", port: 80)),
                destinationConnectionID: RelayFrame.broadcastDestination, over: connection.socket)
            var closed = false
            for _ in 0..<100 {
                let message = try await connection.channel.open(requireApplication(connection.reader))
                if case .browserTunnel(_, let response) = message, response.streamID == streamID {
                    closed = response.action == .close
                    break
                }
            }
            XCTAssertTrue(closed, "An unavailable artifact must reject only its browser stream")
        }
        try await connection.channel.send(.workspaceRequest(
            MessageMetadata(requestID: UUID(), hostID: hostID, runtimeID: connection.runtimeID), .init()),
            destinationConnectionID: RelayFrame.broadcastDestination, over: connection.socket)
        _ = try await requireWorkspaceProjection(connection)

        let nativeURL = try XCTUnwrap(URL(string: "http://\(UUID().uuidString.lowercased()).myterm-artifact.invalid/index.html"))

        let counter = BrowserPacketCounter()
        let proxy = RemoteBrowserProxy { parameters in
            await counter.record(parameters)
            try await connection.channel.send(.browserTunnel(route, parameters),
                destinationConnectionID: RelayFrame.broadcastDestination, over: connection.socket)
        }
        let endpoint = try await proxy.start(protocolKind: .socks5)
        let pump = Task {
            do {
                while !Task.isCancelled {
                    let packet = try await self.requireApplication(connection.reader)
                    let message = try await connection.channel.open(packet)
                    if case .browserTunnel(_, let parameters) = message {
                        try await proxy.receive(parameters)
                    }
                }
            } catch {
                if !Task.isCancelled { await counter.fail(error.localizedDescription) }
            }
        }
        do {
            let configuration = WKWebViewConfiguration()
            let store = WKWebsiteDataStore.nonPersistent()
            let port = try XCTUnwrap(NWEndpoint.Port(rawValue: endpoint.port))
            var proxyConfiguration = ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: port))
            proxyConfiguration.matchDomains = ["localhost", "127.0.0.1", "::1", ""]
            proxyConfiguration.excludedDomains = []
            proxyConfiguration.allowFailover = false
            proxyConfiguration.applyCredential(username: endpoint.username, password: endpoint.password)
            store.proxyConfigurations = [proxyConfiguration]
            configuration.websiteDataStore = store
            let browser = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
            browser.load(URLRequest(url: nativeURL))
            try await waitUntil { browser.title == "RELAY FETCH OK" }
            let chunks = await counter.chunks
            XCTAssertGreaterThan(chunks, 0, "WebKit must actually use the relay proxy")

            try await runBrowserScript(browser, "document.getElementById('next').click(); void 0")
            try await waitUntil { browser.title == "Browser next" }
            browser.load(URLRequest(url: nativeURL))
            try await waitUntil { browser.title == "RELAY FETCH OK" }
            try await runBrowserScript(browser, "fetch('/submit',{method:'POST',body:'through-relay'}).then(r=>document.title=r.status===405?'ARTIFACT READ ONLY':'UNEXPECTED STATUS'); void 0")
            try await waitUntil { browser.title == "ARTIFACT READ ONLY" }
            if ProcessInfo.processInfo.environment["MYTERM_BROWSER_TEST_PUBLIC_HTTPS"] == "1" {
                let secureURL = try XCTUnwrap(URL(string: "https://example.com/"))
                browser.load(URLRequest(url: secureURL))
                try await waitUntil { browser.title == "Example Domain" }
                print("Browser integration verified public HTTPS through the encrypted relay")
            }
            browser.stopLoading()
            await proxy.stop()
            // A dead local proxy must not silently become a direct localhost connection.
            browser.load(URLRequest(url: nativeURL.appending(queryItems: [URLQueryItem(name: "uncached", value: UUID().uuidString)])))
            try await Task.sleep(for: .seconds(1))
            XCTAssertNotEqual(browser.title, "RELAY FETCH OK")
            browser.stopLoading()
            pump.cancel()
            await connection.socket.disconnect()
            let pumpError = await counter.error
            XCTAssertNil(pumpError)
        } catch {
            await proxy.stop()
            pump.cancel()
            await connection.socket.disconnect()
            let pumpError = await counter.error
            XCTFail("Native browser relay pump: \(pumpError ?? "no pump error")")
            throw error
        }
    }

    private func browserCommand(_ request: RemoteBrowserRequest, route: MessageMetadata,
                                connection: PhoneConnection) async throws -> RemoteBrowserFrame {
        let metadata = MessageMetadata(requestID: UUID(), hostID: route.hostID, runtimeID: route.runtimeID,
            workspaceID: route.workspaceID, groupID: route.groupID, tabID: route.tabID)
        let owned = try RemoteBrowserRequest(action: request.action, rendererID: request.rendererID ?? browserRendererID,
            width: request.width, height: request.height, url: request.url, x: request.x, y: request.y,
            deltaX: request.deltaX, deltaY: request.deltaY, text: request.text, key: request.key)
        try await connection.channel.send(.command(metadata, .init(operation: .browserInteract,
            payload: JSONEncoder().encode(owned))), destinationConnectionID: RelayFrame.broadcastDestination,
            over: connection.socket)
        for _ in 0..<100 {
            let packet = try await requireApplication(connection.reader)
            let message = try await connection.channel.open(packet)
            if case .commandResult(let response, let result) = message, response.requestID == metadata.requestID {
                guard result.succeeded, let data = result.result else {
                    throw NSError(domain: "BrowserIntegration", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: result.errorMessage ?? "Browser command failed"])
                }
                return try JSONDecoder().decode(RemoteBrowserFrame.self, from: data)
            }
        }
        throw RemoteError.timedOut
    }

    private func runBrowserScript(_ browser: WKWebView, _ script: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            browser.evaluateJavaScript(script) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func metadata(
        target: TerminalTarget,
        hostID: UUID,
        runtimeID: UUID
    ) -> MessageMetadata {
        MessageMetadata(
            requestID: UUID(),
            hostID: hostID,
            runtimeID: runtimeID,
            sessionID: target.sessionID,
            workspaceID: target.workspaceID,
            groupID: target.groupID,
            tabID: target.tabID
        )
    }

    private func terminalTarget(in projection: RemoteWorkspaceProjection) throws -> TerminalTarget {
        for workspace in projection.workspaces {
            for group in workspace.groups {
                for tab in group.tabs where tab.kind == .terminal {
                    if let sessionID = tab.terminalSessionID?.rawValue {
                        return TerminalTarget(
                            workspaceID: workspace.id.rawValue,
                            groupID: group.id.rawValue,
                            tabID: tab.id.rawValue,
                            sessionID: sessionID
                        )
                    }
                }
            }
        }
        throw RemoteError.offline
    }

    private func sendInput(
        _ value: String,
        leaseID: UUID,
        generation: UUID,
        metadata: MessageMetadata,
        connection: PhoneConnection
    ) async throws {
        try await connection.channel.send(
            .input(
                metadata,
                InputParameters(
                    leaseID: leaseID,
                    generation: generation,
                    bytes: Data(value.utf8)
                )
            ),
            destinationConnectionID: RelayFrame.broadcastDestination,
            over: connection.socket
        )
    }

    private func authenticate(
        socket: RelayWebSocketClient,
        reader: RelayEventReader,
        endpoint: RelayEndpoint,
        fixture: RelayFixture,
        hostIdentity: CompanionHostIdentity,
        clientAgreementKey: P256.KeyAgreement.PrivateKey,
        clientSigningKey: P256.Signing.PrivateKey
    ) async throws -> PhoneConnection {
        let challenge = HelloHandshake.challenge(
            deviceID: fixture.clientDeviceID,
            agreementKey: clientAgreementKey.publicKey,
            notificationSigningKey: clientSigningKey.publicKey,
            capabilities: ["workspace-v1", "terminal-checkpoint-v1", "control-lease-v1"]
        )
        let helloChannel = SecureRelayChannel(
            identity: clientAgreementKey,
            pinnedPeer: hostIdentity.agreementKey.publicKey,
            outboundBinding: ChannelBinding(
                relay: endpoint,
                accountID: fixture.accountID,
                hostID: hostIdentity.hostID,
                runtimeID: nil,
                epoch: challenge.generation,
                senderID: fixture.clientDeviceID,
                recipientID: hostIdentity.hostID,
                purpose: .hello,
                direction: .clientToHost
            ),
            inboundBinding: ChannelBinding(
                relay: endpoint,
                accountID: fixture.accountID,
                hostID: hostIdentity.hostID,
                runtimeID: nil,
                epoch: challenge.generation,
                senderID: hostIdentity.hostID,
                recipientID: fixture.clientDeviceID,
                purpose: .hello,
                direction: .hostToClient
            )
        )
        try await helloChannel.send(
            .hello(MessageMetadata(hostID: hostIdentity.hostID), challenge),
            destinationConnectionID: RelayFrame.broadcastDestination,
            over: socket
        )
        let responsePacket = try await requireApplication(reader)
        let responseMessage = try await helloChannel.open(responsePacket)
        guard case .hello(let metadata, let response) = responseMessage,
              let runtimeID = metadata.runtimeID,
              let epoch = response.applicationEpoch else {
            throw RemoteError.invalidMessage
        }
        try HelloHandshake.validate(
            response: response,
            to: challenge,
            pinnedHostAgreementKey: hostIdentity.agreementKey.publicKey,
            pinnedHostNotificationSigningKey: hostIdentity.notificationSigningKey.publicKey
        )
        let acknowledgement = try HelloHandshake.acknowledgement(to: response, client: challenge)
        try await helloChannel.send(
            .hello(
                MessageMetadata(hostID: hostIdentity.hostID, runtimeID: runtimeID),
                acknowledgement
            ),
            destinationConnectionID: RelayFrame.broadcastDestination,
            over: socket
        )
        let applicationChannel = SecureRelayChannel(
            identity: clientAgreementKey,
            pinnedPeer: hostIdentity.agreementKey.publicKey,
            outboundBinding: ChannelBinding(
                relay: endpoint,
                accountID: fixture.accountID,
                hostID: hostIdentity.hostID,
                runtimeID: runtimeID,
                epoch: epoch,
                senderID: fixture.clientDeviceID,
                recipientID: hostIdentity.hostID,
                purpose: .application,
                direction: .clientToHost
            ),
            inboundBinding: ChannelBinding(
                relay: endpoint,
                accountID: fixture.accountID,
                hostID: hostIdentity.hostID,
                runtimeID: runtimeID,
                epoch: epoch,
                senderID: hostIdentity.hostID,
                recipientID: fixture.clientDeviceID,
                purpose: .application,
                direction: .hostToClient
            )
        )
        return PhoneConnection(
            socket: socket,
            reader: reader,
            channel: applicationChannel,
            runtimeID: runtimeID
        )
    }

    private func makeAuthenticatedConnection(
        endpoint: RelayEndpoint,
        fixture: RelayFixture,
        session: URLSession,
        hostIdentity: CompanionHostIdentity,
        clientAgreementKey: P256.KeyAgreement.PrivateKey,
        clientSigningKey: P256.Signing.PrivateKey
    ) async throws -> PhoneConnection {
        let socket = RelayWebSocketClient(
            endpoint: endpoint,
            hostID: hostIdentity.hostID,
            role: .client,
            session: session
        )
        let reader = RelayEventReader(try await socket.connect(accessToken: fixture.clientToken))
        _ = try await requireReady(reader)
        return try await authenticate(
            socket: socket,
            reader: reader,
            endpoint: endpoint,
            fixture: fixture,
            hostIdentity: hostIdentity,
            clientAgreementKey: clientAgreementKey,
            clientSigningKey: clientSigningKey
        )
    }

    private func requireWorkspaceProjection(
        _ connection: PhoneConnection
    ) async throws -> RemoteWorkspaceProjection {
        while true {
            let packet = try await requireApplication(connection.reader)
            let message = try await connection.channel.open(packet)
            if case .workspaces(_, let workspaces) = message {
                XCTAssertEqual(workspaces.generation, connection.runtimeID)
                return try JSONDecoder().decode(RemoteWorkspaceProjection.self, from: workspaces.model)
            }
        }
    }

    private func requireCheckpoint(
        _ connection: PhoneConnection,
        sessionID: UUID
    ) async throws -> AssembledCheckpoint {
        let assembler = CheckpointAssembler()
        while true {
            let packet = try await requireApplication(connection.reader)
            let message = try await connection.channel.open(packet)
            if case .checkpointChunk(let metadata, let chunk) = message,
               metadata.sessionID == sessionID,
               let assembled = try await assembler.ingest(metadata: metadata, chunk: chunk) {
                return assembled
            }
        }
    }

    private func requireControlState(
        _ connection: PhoneConnection,
        matching predicate: (ControlStateParameters) -> Bool
    ) async throws -> ControlStateParameters {
        while true {
            let packet = try await requireApplication(connection.reader)
            let message = try await connection.channel.open(packet)
            if case .controlState(_, let state) = message, predicate(state) { return state }
        }
    }

    private func requireControlStateMessage(
        _ connection: PhoneConnection,
        matching predicate: (MessageMetadata, ControlStateParameters) -> Bool
    ) async throws -> (metadata: MessageMetadata, state: ControlStateParameters) {
        while true {
            let packet = try await requireApplication(connection.reader)
            let message = try await connection.channel.open(packet)
            if case .controlState(let metadata, let state) = message,
               predicate(metadata, state) {
                return (metadata, state)
            }
        }
    }

    private func requireError(
        _ connection: PhoneConnection,
        code: String
    ) async throws -> (metadata: MessageMetadata, error: ErrorParameters) {
        while true {
            let packet = try await requireApplication(connection.reader)
            let message = try await connection.channel.open(packet)
            if case .error(let metadata, let error) = message, error.code == code {
                return (metadata, error)
            }
        }
    }

    private func requireOutput(
        _ connection: PhoneConnection,
        containing marker: String
    ) async throws {
        var bytes = Data()
        while !String(decoding: bytes, as: UTF8.self).contains(marker) {
            let packet = try await requireApplication(connection.reader)
            let message = try await connection.channel.open(packet)
            if case .output(_, let output) = message {
                bytes.append(output.bytes)
                if bytes.count > 256 * 1_024 { throw RemoteError.messageTooLarge }
            }
        }
    }

    private func requireReady(_ reader: RelayEventReader) async throws -> RelayReady {
        while true {
            guard let event = try await next(reader) else { throw RemoteError.disconnected }
            if case .ready(let ready) = event { return ready }
        }
    }

    private func requireApplication(_ reader: RelayEventReader) async throws -> Data {
        while true {
            guard let event = try await next(reader) else { throw RemoteError.disconnected }
            if case .application(_, let payload) = event { return payload }
        }
    }

    private func requireDisconnect(_ reader: RelayEventReader) async throws {
        do {
            while let event = try await next(reader) {
                if case .application = event { continue }
            }
        } catch {
            guard error as? RemoteError != .timedOut else { throw error }
        }
    }

    private func next(_ reader: RelayEventReader) async throws -> RelayTransportEvent? {
        try await reader.next()
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<320 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw RemoteError.timedOut
    }

    private func waitUntilAsync(
        _ predicate: @escaping @MainActor () async -> Bool
    ) async throws {
        for _ in 0..<320 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw RemoteError.timedOut
    }

    private func fixtureSession(
        fixture: RelayFixture,
        endpoint: RelayEndpoint,
        diagnostics: FixtureNetworkDiagnostics
    ) throws -> URLSession {
        let pem = try String(
            contentsOf: URL(fileURLWithPath: fixture.certificatePath),
            encoding: .utf8
        )
        guard let bodyStart = pem.range(of: "-----BEGIN CERTIFICATE-----\n")?.upperBound,
              let bodyEnd = pem.range(of: "\n-----END CERTIFICATE-----")?.lowerBound,
              let certificateData = Data(
                  base64Encoded: String(pem[bodyStart..<bodyEnd])
                    .replacingOccurrences(of: "\n", with: "")
              ),
              let certificate = SecCertificateCreateWithData(nil, certificateData as CFData)
        else { throw RemoteError.invalidResponse }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let delegate = FixtureTrustDelegate(
            certificate: certificate,
            endpoint: endpoint,
            diagnostics: diagnostics
        )
        guard delegate.responds(to: FixtureTrustDelegate.challengeSelector) else {
            diagnostics.record("TLS challenge selector unavailable")
            throw NSError(
                domain: "RelayFixtureTLSDelegate",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "The fixture URLSession delegate does not expose its TLS challenge selector.",
                ]
            )
        }
        return URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
    }

    private func launchRelayFixture() async throws -> (
        process: Process,
        tempDirectory: URL,
        fixture: RelayFixture,
        serverLogURL: URL
    ) {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("myterm-host-integration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let relayDirectory = repository.appendingPathComponent("Services/relay", isDirectory: true)
        let binaryURL = tempDirectory.appendingPathComponent("relay-test-fixture")
        let buildLogURL = tempDirectory.appendingPathComponent("build.log")
        let serverLogURL = tempDirectory.appendingPathComponent("server.log")
        var runningProcess: Process?
        do {
            let build = Process()
            build.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            build.arguments = [
                "go", "build", "-o", binaryURL.path, "./cmd/relay-test-fixture",
            ]
            build.currentDirectoryURL = relayDirectory
            let buildLog = try fixtureLogHandle(at: buildLogURL)
            build.standardOutput = buildLog
            build.standardError = buildLog
            do { try build.run() }
            catch {
                try? buildLog.close()
                throw error
            }
            try buildLog.close()
            let buildCompleted = try await waitForFixtureProcess(build, iterations: 3_600)
            if buildCompleted { build.waitUntilExit() }
            guard buildCompleted, build.terminationStatus == 0 else {
                throw fixtureProcessError(
                    phase: buildCompleted ? "build exited with status \(build.terminationStatus)" : "build timed out",
                    logURL: buildLogURL,
                    code: Int(build.terminationStatus)
                )
            }

            let process = Process()
            process.executableURL = binaryURL
            process.arguments = ["--temp-dir", tempDirectory.path]
            process.currentDirectoryURL = relayDirectory
            let serverLog = try fixtureLogHandle(at: serverLogURL)
            process.standardOutput = serverLog
            process.standardError = serverLog
            do { try process.run() }
            catch {
                try? serverLog.close()
                throw error
            }
            runningProcess = process
            try serverLog.close()

            let readyURL = tempDirectory.appendingPathComponent("ready.json")
            for _ in 0..<200 {
                if FileManager.default.fileExists(atPath: readyURL.path) {
                    if let data = try? Data(contentsOf: readyURL),
                       let fixture = try? JSONDecoder().decode(RelayFixture.self, from: data) {
                        return (process, tempDirectory, fixture, serverLogURL)
                    }
                }
                guard process.isRunning else {
                    process.waitUntilExit()
                    throw fixtureProcessError(
                        phase: "server exited with status \(process.terminationStatus)",
                        logURL: serverLogURL,
                        code: Int(process.terminationStatus)
                    )
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            throw fixtureProcessError(
                phase: "server readiness timed out",
                logURL: serverLogURL,
                code: Int(process.terminationStatus)
            )
        } catch {
            if let runningProcess {
                if runningProcess.isRunning { runningProcess.terminate() }
                runningProcess.waitUntilExit()
            }
            try? FileManager.default.removeItem(at: tempDirectory)
            throw error
        }
    }

    private func waitForFixtureProcess(
        _ process: Process,
        iterations: Int
    ) async throws -> Bool {
        for _ in 0..<iterations {
            if !process.isRunning { return true }
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch {
                if process.isRunning { process.terminate() }
                process.waitUntilExit()
                throw error
            }
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        return false
    }

    private func fixtureLogHandle(at url: URL) throws -> FileHandle {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return try FileHandle(forWritingTo: url)
    }

    private func fixtureProcessError(phase: String, logURL: URL, code: Int) -> NSError {
        let log = sanitizedFixtureLog(at: logURL)
        return NSError(
            domain: "RelayFixture",
            code: code,
            userInfo: [
                NSLocalizedDescriptionKey: "Relay fixture \(phase).\n\(log)",
            ]
        )
    }

    private func fixtureIntegrationError(
        stage: String,
        underlying: any Error,
        serverLogURL: URL,
        networkDiagnostics: FixtureNetworkDiagnostics
    ) -> NSError {
        var details = [
            "Companion host integration failed during: \(stage).",
            "Underlying error: \(underlying.localizedDescription)",
        ]
        let network = networkDiagnostics.summary
        if !network.isEmpty { details.append("URLSession diagnostics: \(network)") }
        let server = sanitizedFixtureLog(at: serverLogURL)
        if !server.isEmpty { details.append("Relay server log:\n\(server)") }
        return NSError(
            domain: "CompanionHostIntegration",
            code: (underlying as NSError).code,
            userInfo: [NSLocalizedDescriptionKey: details.joined(separator: "\n")]
        )
    }

    private func sanitizedFixtureLog(at url: URL) -> String {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let end = try handle.seekToEnd()
            let maximumBytes: UInt64 = 32 * 1_024
            try handle.seek(toOffset: end > maximumBytes ? end - maximumBytes : 0)
            let text = String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
            let sensitive = ["authorization", "bearer", "token", "secret", "password"]
            return text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
                let lowercase = line.lowercased()
                return sensitive.contains(where: lowercase.contains)
                    ? "[redacted sensitive fixture log line]"
                    : String(line)
            }.joined(separator: "\n")
        } catch {
            return "Unable to read fixture log (\((error as NSError).domain) code \((error as NSError).code))."
        }
    }
}

private extension URLProtectionSpace {
    var protectionSpaceURL: URL? {
        var components = URLComponents()
        components.scheme = `protocol`
        components.host = host
        components.port = port
        return components.url
    }
}
