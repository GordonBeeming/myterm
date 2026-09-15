import CryptoKit
import Foundation

public enum InnerMessageKind: String, Codable, CaseIterable, Sendable {
    case hello
    case workspaceRequest = "workspace_request"
    case workspaces
    case command
    case commandResult = "command_result"
    case attach
    case detach
    case checkpointChunk = "checkpoint_chunk"
    case output
    case input
    case resize
    case controlRequest = "control_request"
    case controlState = "control_state"
    case activity
    case error
}

public struct MessageMetadata: Codable, Equatable, Sendable {
    public let requestID: UUID?
    public let hostID: UUID
    public let runtimeID: UUID?
    public let sessionID: UUID?
    public let workspaceID: UUID?
    public let folderID: UUID?
    public let groupID: UUID?
    public let tabID: UUID?

    public init(requestID: UUID? = nil, hostID: UUID, runtimeID: UUID? = nil,
                sessionID: UUID? = nil, workspaceID: UUID? = nil,
                folderID: UUID? = nil, groupID: UUID? = nil, tabID: UUID? = nil) {
        self.requestID = requestID
        self.hostID = hostID
        self.runtimeID = runtimeID
        self.sessionID = sessionID
        self.workspaceID = workspaceID
        self.folderID = folderID
        self.groupID = groupID
        self.tabID = tabID
    }
}

public struct HelloParameters: Codable, Equatable, Sendable {
    public let phase: HelloPhase
    public let generation: UUID
    public let deviceID: UUID
    public let agreementPublicKey: Data
    public let notificationSigningPublicKey: Data
    public let applicationEpoch: UUID?
    public let challenge: Data?
    public let response: Data?
    public let capabilities: [String]

    public init(phase: HelloPhase, generation: UUID, deviceID: UUID,
                agreementPublicKey: Data, notificationSigningPublicKey: Data,
                applicationEpoch: UUID? = nil, challenge: Data?, response: Data?,
                capabilities: [String]) {
        self.phase = phase
        self.generation = generation
        self.deviceID = deviceID
        self.agreementPublicKey = agreementPublicKey
        self.notificationSigningPublicKey = notificationSigningPublicKey
        self.applicationEpoch = applicationEpoch
        self.challenge = challenge
        self.response = response
        self.capabilities = capabilities
    }
}

public enum HelloPhase: String, Codable, Sendable {
    case challenge
    case response
    case acknowledgement
}

public struct WorkspaceRequestParameters: Codable, Equatable, Sendable {
    public let afterRevision: UInt64?
    public init(afterRevision: UInt64? = nil) { self.afterRevision = afterRevision }
}

public enum CommandOperation: String, Codable, CaseIterable, Sendable {
    case workspaceCreate = "workspace_create"
    case workspaceRename = "workspace_rename"
    case workspaceClose = "workspace_close"
    case workspaceReorder = "workspace_reorder"
    case workspaceMove = "workspace_move"
    case workspacePin = "workspace_pin"
    case workspaceColor = "workspace_color"
    case folderCreate = "folder_create"
    case folderRename = "folder_rename"
    case folderClose = "folder_close"
    case folderReorder = "folder_reorder"
    case folderPin = "folder_pin"
    case folderColor = "folder_color"
    case tabCreate = "tab_create"
    case tabRename = "tab_rename"
    case tabClose = "tab_close"
    case tabReorder = "tab_reorder"
    case tabPin = "tab_pin"
    case tabColor = "tab_color"
    case tabMove = "tab_move"
    case tabSplit = "tab_split"
    case settingsUpdate = "settings_update"
    case markRead = "mark_read"
    case terminalPasteImage = "terminal_paste_image"
    case terminalPasteImageChunk = "terminal_paste_image_chunk"
    case notificationRegister = "notification_register"
    case notificationRevoke = "notification_revoke"
}

public struct CommandParameters: Codable, Equatable, Sendable {
    public let operation: CommandOperation
    /// MyTermCore owns the operation-specific Codable model; this package authenticates and bounds it.
    public let payload: Data

    public init(operation: CommandOperation, payload: Data) {
        self.operation = operation
        self.payload = payload
    }
}

public struct WorkspacesParameters: Codable, Equatable, Sendable {
    public let generation: UUID
    public let revision: UInt64
    public let model: Data

    public init(generation: UUID, revision: UInt64, model: Data) {
        self.generation = generation
        self.revision = revision
        self.model = model
    }
}

public struct CommandResultParameters: Codable, Equatable, Sendable {
    public let succeeded: Bool
    public let result: Data?
    public let errorCode: String?
    public let errorMessage: String?

    public init(succeeded: Bool, result: Data? = nil, errorCode: String? = nil,
                errorMessage: String? = nil) {
        self.succeeded = succeeded
        self.result = result
        self.errorCode = errorCode
        self.errorMessage = errorMessage
    }
}

public struct AttachParameters: Codable, Equatable, Sendable {
    public let afterSequence: UInt64?
    public let requireCheckpoint: Bool

    public init(afterSequence: UInt64? = nil, requireCheckpoint: Bool = true) {
        self.afterSequence = afterSequence
        self.requireCheckpoint = requireCheckpoint
    }
}

public struct DetachParameters: Codable, Equatable, Sendable {
    public init() {}
}

public struct CheckpointChunkParameters: Codable, Equatable, Sendable {
    public let transferID: UUID
    public let generation: UUID
    public let sequence: UInt64
    public let chunkIndex: Int
    public let chunkCount: Int
    public let totalBytes: Int
    public let bytes: Data

    public init(transferID: UUID, generation: UUID, sequence: UInt64, chunkIndex: Int,
                chunkCount: Int, totalBytes: Int, bytes: Data) {
        self.transferID = transferID
        self.generation = generation
        self.sequence = sequence
        self.chunkIndex = chunkIndex
        self.chunkCount = chunkCount
        self.totalBytes = totalBytes
        self.bytes = bytes
    }
}

public struct OutputParameters: Codable, Equatable, Sendable {
    public let generation: UUID
    public let sequence: UInt64
    public let bytes: Data

    public init(generation: UUID, sequence: UInt64, bytes: Data) {
        self.generation = generation
        self.sequence = sequence
        self.bytes = bytes
    }
}

public struct InputParameters: Codable, Equatable, Sendable {
    public let leaseID: UUID
    public let generation: UUID
    public let bytes: Data

    public init(leaseID: UUID, generation: UUID, bytes: Data) {
        self.leaseID = leaseID
        self.generation = generation
        self.bytes = bytes
    }
}

public struct ResizeParameters: Codable, Equatable, Sendable {
    public let leaseID: UUID
    public let generation: UUID
    public let columns: Int
    public let rows: Int

    public init(leaseID: UUID, generation: UUID, columns: Int, rows: Int) {
        self.leaseID = leaseID
        self.generation = generation
        self.columns = columns
        self.rows = rows
    }
}

public enum ControlAction: String, Codable, Sendable {
    case acquire
    case takeover
    case renew
    case release
}

public struct ControlRequestParameters: Codable, Equatable, Sendable {
    public let action: ControlAction
    public let leaseID: UUID?

    public init(action: ControlAction, leaseID: UUID? = nil) {
        self.action = action
        self.leaseID = leaseID
    }
}

public struct ControlStateParameters: Codable, Equatable, Sendable {
    public let controllerConnectionID: UUID?
    public let leaseID: UUID?
    public let expiresAt: Date?
    public let generation: UUID
    public let columns: Int
    public let rows: Int

    public init(controllerConnectionID: UUID?, leaseID: UUID?, expiresAt: Date?,
                generation: UUID, columns: Int, rows: Int) {
        self.controllerConnectionID = controllerConnectionID
        self.leaseID = leaseID
        self.expiresAt = expiresAt
        self.generation = generation
        self.columns = columns
        self.rows = rows
    }
}

public struct ActivityParameters: Codable, Equatable, Sendable {
    public let state: String
    public let occurredAt: Date

    public init(state: String, occurredAt: Date) {
        self.state = state
        self.occurredAt = occurredAt
    }
}

public struct ErrorParameters: Codable, Equatable, Sendable {
    public let code: String
    public let message: String
    public let retryable: Bool

    public init(code: String, message: String, retryable: Bool) {
        self.code = code
        self.message = message
        self.retryable = retryable
    }
}

extension HelloParameters {
    enum CodingKeys: String, CodingKey {
        case phase, generation, challenge, response, capabilities
        case deviceID = "device_id"
        case agreementPublicKey = "agreement_public_key"
        case notificationSigningPublicKey = "notification_signing_public_key"
        case applicationEpoch = "application_epoch"
    }
}

extension WorkspaceRequestParameters {
    enum CodingKeys: String, CodingKey { case afterRevision = "after_revision" }
}

extension CommandParameters {
    enum CodingKeys: String, CodingKey { case operation, payload }
}

extension WorkspacesParameters {
    enum CodingKeys: String, CodingKey { case generation, revision, model }
}

extension CommandResultParameters {
    enum CodingKeys: String, CodingKey {
        case succeeded, result
        case errorCode = "error_code"
        case errorMessage = "error_message"
    }
}

extension AttachParameters {
    enum CodingKeys: String, CodingKey {
        case afterSequence = "after_sequence"
        case requireCheckpoint = "require_checkpoint"
    }
}

extension CheckpointChunkParameters {
    enum CodingKeys: String, CodingKey {
        case generation, sequence, bytes
        case transferID = "transfer_id"
        case chunkIndex = "chunk_index"
        case chunkCount = "chunk_count"
        case totalBytes = "total_bytes"
    }
}

extension OutputParameters {
    enum CodingKeys: String, CodingKey { case generation, sequence, bytes }
}

extension InputParameters {
    enum CodingKeys: String, CodingKey {
        case leaseID = "lease_id"
        case generation, bytes
    }
}

extension ResizeParameters {
    enum CodingKeys: String, CodingKey {
        case leaseID = "lease_id"
        case generation, columns, rows
    }
}

extension ControlRequestParameters {
    enum CodingKeys: String, CodingKey {
        case action
        case leaseID = "lease_id"
    }
}

extension ControlStateParameters {
    enum CodingKeys: String, CodingKey {
        case controllerConnectionID = "controller_connection_id"
        case leaseID = "lease_id"
        case expiresAt = "expires_at"
        case generation, columns, rows
    }
}

extension ActivityParameters {
    enum CodingKeys: String, CodingKey {
        case state
        case occurredAt = "occurred_at"
    }
}

extension ErrorParameters {
    enum CodingKeys: String, CodingKey { case code, message, retryable }
}

public enum InnerMessage: Equatable, Sendable {
    case hello(MessageMetadata, HelloParameters)
    case workspaceRequest(MessageMetadata, WorkspaceRequestParameters)
    case workspaces(MessageMetadata, WorkspacesParameters)
    case command(MessageMetadata, CommandParameters)
    case commandResult(MessageMetadata, CommandResultParameters)
    case attach(MessageMetadata, AttachParameters)
    case detach(MessageMetadata, DetachParameters)
    case checkpointChunk(MessageMetadata, CheckpointChunkParameters)
    case output(MessageMetadata, OutputParameters)
    case input(MessageMetadata, InputParameters)
    case resize(MessageMetadata, ResizeParameters)
    case controlRequest(MessageMetadata, ControlRequestParameters)
    case controlState(MessageMetadata, ControlStateParameters)
    case activity(MessageMetadata, ActivityParameters)
    case error(MessageMetadata, ErrorParameters)

    public var kind: InnerMessageKind {
        switch self {
        case .hello: .hello
        case .workspaceRequest: .workspaceRequest
        case .workspaces: .workspaces
        case .command: .command
        case .commandResult: .commandResult
        case .attach: .attach
        case .detach: .detach
        case .checkpointChunk: .checkpointChunk
        case .output: .output
        case .input: .input
        case .resize: .resize
        case .controlRequest: .controlRequest
        case .controlState: .controlState
        case .activity: .activity
        case .error: .error
        }
    }

    public var metadata: MessageMetadata {
        switch self {
        case .hello(let value, _), .workspaceRequest(let value, _), .workspaces(let value, _),
             .command(let value, _), .commandResult(let value, _),
             .attach(let value, _), .detach(let value, _), .checkpointChunk(let value, _), .output(let value, _),
             .input(let value, _), .resize(let value, _), .controlRequest(let value, _),
             .controlState(let value, _), .activity(let value, _), .error(let value, _): value
        }
    }
}

extension InnerMessage: Codable {
    enum CodingKeys: String, CodingKey {
        case version, kind, parameters
        case requestID = "request_id"
        case hostID = "host_id"
        case runtimeID = "runtime_id"
        case sessionID = "session_id"
        case workspaceID = "workspace_id"
        case folderID = "folder_id"
        case groupID = "group_id"
        case tabID = "tab_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .version) == 1 else {
            throw RemoteError.unsupportedVersion
        }
        let kind = try container.decode(InnerMessageKind.self, forKey: .kind)
        let metadata = MessageMetadata(
            requestID: try container.decodeIfPresent(UUID.self, forKey: .requestID),
            hostID: try container.decode(UUID.self, forKey: .hostID),
            runtimeID: try container.decodeIfPresent(UUID.self, forKey: .runtimeID),
            sessionID: try container.decodeIfPresent(UUID.self, forKey: .sessionID),
            workspaceID: try container.decodeIfPresent(UUID.self, forKey: .workspaceID),
            folderID: try container.decodeIfPresent(UUID.self, forKey: .folderID),
            groupID: try container.decodeIfPresent(UUID.self, forKey: .groupID),
            tabID: try container.decodeIfPresent(UUID.self, forKey: .tabID)
        )
        switch kind {
        case .hello: self = .hello(metadata, try container.decode(HelloParameters.self, forKey: .parameters))
        case .workspaceRequest: self = .workspaceRequest(metadata, try container.decode(WorkspaceRequestParameters.self, forKey: .parameters))
        case .workspaces: self = .workspaces(metadata, try container.decode(WorkspacesParameters.self, forKey: .parameters))
        case .command: self = .command(metadata, try container.decode(CommandParameters.self, forKey: .parameters))
        case .commandResult: self = .commandResult(metadata, try container.decode(CommandResultParameters.self, forKey: .parameters))
        case .attach: self = .attach(metadata, try container.decode(AttachParameters.self, forKey: .parameters))
        case .detach: self = .detach(metadata, try container.decode(DetachParameters.self, forKey: .parameters))
        case .checkpointChunk: self = .checkpointChunk(metadata, try container.decode(CheckpointChunkParameters.self, forKey: .parameters))
        case .output: self = .output(metadata, try container.decode(OutputParameters.self, forKey: .parameters))
        case .input: self = .input(metadata, try container.decode(InputParameters.self, forKey: .parameters))
        case .resize: self = .resize(metadata, try container.decode(ResizeParameters.self, forKey: .parameters))
        case .controlRequest: self = .controlRequest(metadata, try container.decode(ControlRequestParameters.self, forKey: .parameters))
        case .controlState: self = .controlState(metadata, try container.decode(ControlStateParameters.self, forKey: .parameters))
        case .activity: self = .activity(metadata, try container.decode(ActivityParameters.self, forKey: .parameters))
        case .error: self = .error(metadata, try container.decode(ErrorParameters.self, forKey: .parameters))
        }
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(1, forKey: .version)
        try container.encode(kind, forKey: .kind)
        let value = metadata
        try container.encodeIfPresent(value.requestID, forKey: .requestID)
        try container.encode(value.hostID, forKey: .hostID)
        try container.encodeIfPresent(value.runtimeID, forKey: .runtimeID)
        try container.encodeIfPresent(value.sessionID, forKey: .sessionID)
        try container.encodeIfPresent(value.workspaceID, forKey: .workspaceID)
        try container.encodeIfPresent(value.folderID, forKey: .folderID)
        try container.encodeIfPresent(value.groupID, forKey: .groupID)
        try container.encodeIfPresent(value.tabID, forKey: .tabID)
        switch self {
        case .hello(_, let payload): try container.encode(payload, forKey: .parameters)
        case .workspaceRequest(_, let payload): try container.encode(payload, forKey: .parameters)
        case .workspaces(_, let payload): try container.encode(payload, forKey: .parameters)
        case .command(_, let payload): try container.encode(payload, forKey: .parameters)
        case .commandResult(_, let payload): try container.encode(payload, forKey: .parameters)
        case .attach(_, let payload): try container.encode(payload, forKey: .parameters)
        case .detach(_, let payload): try container.encode(payload, forKey: .parameters)
        case .checkpointChunk(_, let payload): try container.encode(payload, forKey: .parameters)
        case .output(_, let payload): try container.encode(payload, forKey: .parameters)
        case .input(_, let payload): try container.encode(payload, forKey: .parameters)
        case .resize(_, let payload): try container.encode(payload, forKey: .parameters)
        case .controlRequest(_, let payload): try container.encode(payload, forKey: .parameters)
        case .controlState(_, let payload): try container.encode(payload, forKey: .parameters)
        case .activity(_, let payload): try container.encode(payload, forKey: .parameters)
        case .error(_, let payload): try container.encode(payload, forKey: .parameters)
        }
    }

    public func validate() throws {
        let metadata = metadata
        switch self {
        case .hello(_, let value):
            guard value.agreementPublicKey.count == 65,
                  value.notificationSigningPublicKey.count == 65,
                  value.capabilities.count <= 64,
                  value.capabilities.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }) else {
                throw RemoteError.invalidMessage
            }
            do {
                _ = try P256.KeyAgreement.PublicKey(x963Representation: value.agreementPublicKey)
                _ = try P256.Signing.PublicKey(x963Representation: value.notificationSigningPublicKey)
            } catch { throw RemoteError.invalidMessage }
            switch value.phase {
            case .challenge:
                guard metadata.runtimeID == nil, value.challenge?.count == 32,
                      value.response == nil, value.applicationEpoch == nil else {
                    throw RemoteError.invalidMessage
                }
            case .response:
                guard metadata.runtimeID != nil, value.challenge?.count == 32,
                      value.response?.count == 32, value.applicationEpoch != nil else {
                    throw RemoteError.invalidMessage
                }
            case .acknowledgement:
                guard metadata.runtimeID != nil, value.challenge == nil,
                      value.response?.count == 32, value.applicationEpoch != nil else {
                    throw RemoteError.invalidMessage
                }
            }
        case .workspaceRequest:
            guard metadata.requestID != nil else { throw RemoteError.invalidMessage }
        case .workspaces(_, let value):
            guard metadata.runtimeID != nil, value.model.count <= InnerMessageCodec.maximumBytes else { throw RemoteError.invalidMessage }
        case .command(_, let value):
            guard metadata.requestID != nil, value.payload.count <= 256 * 1_024 else {
                throw RemoteError.invalidMessage
            }
            switch value.operation {
            case .workspaceCreate, .folderCreate, .tabCreate, .settingsUpdate,
                 .notificationRegister, .notificationRevoke:
                break
            case .workspaceRename, .workspaceClose, .workspaceReorder, .workspaceMove, .workspacePin,
                 .workspaceColor, .markRead:
                guard metadata.workspaceID != nil else { throw RemoteError.invalidMessage }
            case .folderRename, .folderClose, .folderReorder, .folderPin, .folderColor:
                guard metadata.folderID != nil else { throw RemoteError.invalidMessage }
            case .tabRename, .tabClose, .tabReorder, .tabPin, .tabColor, .tabMove, .tabSplit:
                guard metadata.tabID != nil else { throw RemoteError.invalidMessage }
            case .terminalPasteImage:
                guard metadata.runtimeID != nil, metadata.sessionID != nil,
                      metadata.workspaceID != nil, metadata.groupID != nil,
                      metadata.tabID != nil, value.payload.count <= 192 * 1_024 else {
                    throw RemoteError.invalidMessage
                }
            case .terminalPasteImageChunk:
                guard metadata.runtimeID != nil, metadata.sessionID != nil,
                      metadata.workspaceID != nil, metadata.groupID != nil,
                      metadata.tabID != nil, value.payload.count <= 96 * 1_024 else {
                    throw RemoteError.invalidMessage
                }
            }
        case .commandResult:
            guard metadata.requestID != nil else { throw RemoteError.invalidMessage }
        case .attach:
            guard metadata.requestID != nil, metadata.runtimeID != nil, metadata.sessionID != nil else { throw RemoteError.invalidMessage }
        case .detach:
            guard metadata.requestID != nil, metadata.runtimeID != nil,
                  metadata.sessionID != nil else { throw RemoteError.invalidMessage }
        case .checkpointChunk(_, let value):
            guard metadata.runtimeID != nil, metadata.sessionID != nil,
                  value.chunkCount > 0, value.chunkCount <= 65_536,
                  value.chunkIndex >= 0, value.chunkIndex < value.chunkCount,
                  value.totalBytes >= 0, value.totalBytes <= CheckpointAssembler.maximumCheckpointBytes,
                  !value.bytes.isEmpty else { throw RemoteError.invalidMessage }
        case .output(_, let value):
            guard metadata.runtimeID != nil, metadata.sessionID != nil, !value.bytes.isEmpty else { throw RemoteError.invalidMessage }
        case .input(_, let value):
            guard metadata.sessionID != nil, !value.bytes.isEmpty else { throw RemoteError.invalidMessage }
        case .resize(_, let value):
            guard metadata.sessionID != nil, (1...1_000).contains(value.columns),
                  (1...1_000).contains(value.rows) else { throw RemoteError.invalidMessage }
        case .controlRequest:
            guard metadata.requestID != nil, metadata.sessionID != nil else { throw RemoteError.invalidMessage }
        case .controlState(_, let value):
            guard metadata.sessionID != nil, (2...1_000).contains(value.columns),
                  (1...1_000).contains(value.rows) else { throw RemoteError.invalidMessage }
        case .activity(_, let value):
            guard metadata.sessionID != nil, !value.state.isEmpty,
                  value.state.utf8.count <= 64 else { throw RemoteError.invalidMessage }
        case .error(_, let value):
            guard !value.code.isEmpty, value.code.utf8.count <= 128,
                  value.message.utf8.count <= 2_048 else { throw RemoteError.invalidMessage }
        }
    }
}

public enum InnerMessageCodec {
    public static let maximumBytes = 1_048_576

    public static func encode(_ message: InnerMessage) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(message)
        guard data.count <= maximumBytes else { throw RemoteError.messageTooLarge }
        return data
    }

    public static func decode(_ data: Data) throws -> InnerMessage {
        guard !data.isEmpty, data.count <= maximumBytes else { throw RemoteError.messageTooLarge }
        let decoder = JSONDecoder()
        do { return try decoder.decode(InnerMessage.self, from: data) }
        catch let error as RemoteError { throw error }
        catch { throw RemoteError.invalidMessage }
    }
}
