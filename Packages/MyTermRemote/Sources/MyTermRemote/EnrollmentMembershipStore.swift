import Foundation

public struct EnrollmentMembershipCheckpoint: Codable, Equatable, Sendable {
    public let sequence: Int64
    public let digest: String
}

public enum ServerEnrollmentMembership: String, Codable, Equatable, Sendable {
    case provisional
    case canonical
    case freshApprovalRequired
}

public struct EnrolledServer: Codable, Equatable, Sendable {
    public let request: ServerEnrollmentRequest
    public let membership: ServerEnrollmentMembership
    let enrollmentDigest: String
}

public actor EnrollmentMembershipStore {
    private static let persistenceLock = NSLock()

    private struct State: Codable {
        var checkpoint: EnrollmentMembershipCheckpoint
        var credentials: [String: ServerEnrollmentCredential] = [:]
        var revoked: Set<String> = []
        var removed: Set<String> = []
        var servers: [String: EnrolledServer] = [:]
        var observedTime: Int64 = 0
    }

    private let secrets: any SecretStore
    private let storageAccount: String
    private let binding: EnrollmentAccountBinding
    private let authority: EnrollmentSigningIdentity
    private let firstClient: EnrollmentSigningIdentity
    private let openedAt = ContinuousClock.now
    private let clockFloor: Int64
    private var state: State
    private var snapshot: Data?

    public init(secrets: any SecretStore, binding: EnrollmentAccountBinding, pinnedAnchor: String) throws {
        self.secrets = secrets
        self.binding = binding
        authority = try binding.verifiedAuthority(pinnedAnchor: pinnedAnchor)
        firstClient = try binding.genesis.read(EnrollmentAccountGenesis.self).firstClient
        storageAccount = "enrollment-membership-v1-\(pinnedAnchor)"
        snapshot = try secrets.read(account: storageAccount)
        if let saved = snapshot {
            state = try JSONDecoder().decode(State.self, from: saved)
        } else {
            state = State(checkpoint: EnrollmentMembershipCheckpoint(sequence: 0, digest: pinnedAnchor))
        }
        clockFloor = max(state.observedTime, Int64(Date().timeIntervalSince1970))
    }

    public var checkpoint: EnrollmentMembershipCheckpoint { state.checkpoint }

    public func servers() throws -> [EnrolledServer] {
        try requireCurrentSnapshot()
        return state.servers.sorted { $0.key < $1.key }.map(\.value)
    }

    public func apply(_ page: [SignedAccountEnrollment]) throws {
        try requireCurrentSnapshot()
        guard page.count <= 128 else { throw AccountEnrollmentError.invalidCheckpoint }
        var next = state
        for signed in page {
            let event = try signed.verify(EnrollmentMembershipEvent.self, signer: authority)
            let digest = try signed.digest(EnrollmentMembershipEvent.self)
            guard event.account == binding.anchor else { throw AccountEnrollmentError.wrongAccount }
            if event.sequence == next.checkpoint.sequence, digest == next.checkpoint.digest { continue }
            guard next.checkpoint.sequence < Int64.max, event.sequence == next.checkpoint.sequence + 1,
                  event.previous == next.checkpoint.digest else {
                throw AccountEnrollmentError.invalidCheckpoint
            }
            try apply(event.change, into: &next)
            next.checkpoint = EnrollmentMembershipCheckpoint(sequence: event.sequence, digest: digest)
        }
        if next.checkpoint != state.checkpoint { try persist(next) }
    }

    public func observe(_ presentation: ServerEnrollmentPresentation) throws -> EnrolledServer {
        let elapsed = openedAt.duration(to: .now).components.seconds
        let (projected, overflow) = clockFloor.addingReportingOverflow(elapsed)
        guard !overflow else { throw AccountEnrollmentError.invalidArtifact }
        return try observe(presentation, at: max(projected, Int64(Date().timeIntervalSince1970)))
    }

    func observe(_ presentation: ServerEnrollmentPresentation, at now: Int64) throws -> EnrolledServer {
        try requireCurrentSnapshot()
        let verified = try presentation.verified(binding: binding, pinnedAnchor: binding.anchor)
        let request = verified.request
        let credential = verified.credential
        let serverID = try request.server.id
        let digest = try presentation.request.digest(ServerEnrollmentRequest.self)
        var next = state
        try checkServerRole(request.server, credential: credential, in: next)
        if now > next.observedTime { next.observedTime = now }
        if let prior = next.servers[serverID] {
            guard prior.enrollmentDigest == digest else { throw AccountEnrollmentError.identityConflict }
            if next.observedTime != state.observedTime { try persist(next) }
            return prior
        }
        if let issued = next.credentials[credential.id], issued != credential {
            throw AccountEnrollmentError.invalidArtifact
        }
        guard credential.mode == .reusable, !next.revoked.contains(credential.id),
              next.observedTime >= credential.issuedAt, next.observedTime < credential.expiresAt else {
            if next.observedTime != state.observedTime { try persist(next) }
            throw AccountEnrollmentError.freshApprovalRequired
        }
        let server = EnrolledServer(request: request, membership: .provisional, enrollmentDigest: digest)
        next.servers[serverID] = server
        try persist(next)
        return server
    }

    private func checkServerRole(
        _ server: EnrollmentSigningIdentity, credential: ServerEnrollmentCredential, in next: State
    ) throws {
        if try next.removed.contains(server.id) { throw AccountEnrollmentError.identityRemoved }
        guard server != authority, server != firstClient, server != credential.holder,
              !next.credentials.values.contains(where: { $0.holder == server }) else {
            throw AccountEnrollmentError.identityConflict
        }
    }

    private func apply(_ change: EnrollmentMembershipChange, into next: inout State) throws {
        switch change {
        case .issue(let credential):
            try credential.validate()
            guard credential.account == binding.anchor, next.credentials[credential.id] == nil else {
                throw AccountEnrollmentError.invalidArtifact
            }
            next.credentials[credential.id] = credential
        case .revokeCredential(let id):
            guard next.credentials[id] != nil else { throw AccountEnrollmentError.invalidArtifact }
            next.revoked.insert(id)
            for (serverID, server) in next.servers where server.request.credential == id && server.membership == .provisional {
                next.servers[serverID] = EnrolledServer(request: server.request, membership: .freshApprovalRequired,
                                                       enrollmentDigest: server.enrollmentDigest)
            }
        case .removeIdentity(let identity):
            let id = try identity.id
            next.removed.insert(id)
            next.servers.removeValue(forKey: id)
        case .admit(let admission):
            let request = admission.request
            let id = try request.server.id
            try request.validate()
            guard request.account == binding.anchor, let credential = next.credentials[request.credential],
                  try SignedAccountEnrollment.digest(of: request) == admission.enrollmentDigest else {
                throw AccountEnrollmentError.invalidArtifact
            }
            try checkServerRole(request.server, credential: credential, in: next)
            if let confirmer = admission.confirmedBy {
                let actor = try confirmer.id
                guard !next.removed.contains(actor),
                      confirmer == firstClient || next.servers[actor]?.membership == .canonical else {
                    throw AccountEnrollmentError.invalidArtifact
                }
            } else if next.revoked.contains(request.credential) {
                throw AccountEnrollmentError.invalidCheckpoint
            }
            if let prior = next.servers[id], prior.enrollmentDigest != admission.enrollmentDigest {
                throw AccountEnrollmentError.identityConflict
            }
            next.servers[id] = EnrolledServer(request: request, membership: .canonical,
                                              enrollmentDigest: admission.enrollmentDigest)
        case .freshApprove:
            throw AccountEnrollmentError.invalidArtifact
        }
    }

    private func requireCurrentSnapshot() throws {
        guard try secrets.read(account: storageAccount) == snapshot else {
            throw AccountEnrollmentError.invalidCheckpoint
        }
    }

    private func persist(_ next: State) throws {
        let encoded = try JSONEncoder().encode(next)
        let expected = snapshot
        let secrets = self.secrets
        let account = storageAccount
        try Self.persistenceLock.withLock {
            guard try secrets.read(account: account) == expected else {
                throw AccountEnrollmentError.invalidCheckpoint
            }
            try secrets.write(encoded, account: account)
        }
        snapshot = encoded
        state = next
    }
}
