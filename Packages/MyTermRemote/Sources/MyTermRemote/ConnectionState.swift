import Foundation

public enum ApplicationReachability: Equatable, Sendable {
    case disconnected
    case transportOnly(connectionID: UUID)
    case authenticated(connectionID: UUID, generation: UUID, peerDeviceID: UUID)
}

public struct ConnectionGenerationState: Equatable, Sendable {
    public private(set) var reachability: ApplicationReachability = .disconnected

    public init() {}

    public mutating func transportConnected(connectionID: UUID) {
        reachability = .transportOnly(connectionID: connectionID)
    }

    public mutating func authenticatedHello(connectionID: UUID, generation: UUID,
                                            peerDeviceID: UUID) throws {
        guard case .transportOnly(let expected) = reachability, expected == connectionID else {
            throw RemoteError.wrongPeer
        }
        reachability = .authenticated(connectionID: connectionID, generation: generation,
                                      peerDeviceID: peerDeviceID)
    }

    public mutating func transportDisconnected(connectionID: UUID) {
        switch reachability {
        case .transportOnly(let current) where current == connectionID,
             .authenticated(let current, _, _) where current == connectionID:
            reachability = .disconnected
        default: break
        }
    }

    public func accepts(generation: UUID, connectionID: UUID) -> Bool {
        guard case .authenticated(let currentConnection, let currentGeneration, _) = reachability else {
            return false
        }
        return currentConnection == connectionID && currentGeneration == generation
    }
}

public struct ControllerLease: Equatable, Sendable {
    public let leaseID: UUID
    public let connectionID: UUID
    public let expiresAt: Date
}

public struct ControllerLeaseState: Equatable, Sendable {
    public let duration: TimeInterval
    public private(set) var lease: ControllerLease?

    public init(duration: TimeInterval = 30) {
        self.duration = max(1, duration)
    }

    @discardableResult
    public mutating func acquire(connectionID: UUID, now: Date = .now) throws -> ControllerLease {
        discardExpired(now: now)
        if let lease {
            guard lease.connectionID == connectionID else { throw RemoteError.controlDenied }
            let renewed = ControllerLease(leaseID: lease.leaseID, connectionID: connectionID,
                                          expiresAt: now.addingTimeInterval(duration))
            self.lease = renewed
            return renewed
        }
        let created = ControllerLease(leaseID: UUID(), connectionID: connectionID,
                                      expiresAt: now.addingTimeInterval(duration))
        lease = created
        return created
    }

    @discardableResult
    public mutating func takeover(connectionID: UUID, now: Date = .now) -> ControllerLease {
        let created = ControllerLease(leaseID: UUID(), connectionID: connectionID,
                                      expiresAt: now.addingTimeInterval(duration))
        lease = created
        return created
    }

    @discardableResult
    public mutating func renew(leaseID: UUID, connectionID: UUID,
                              now: Date = .now) throws -> ControllerLease {
        discardExpired(now: now)
        guard let current = lease, current.leaseID == leaseID,
              current.connectionID == connectionID else { throw RemoteError.controlDenied }
        let renewed = ControllerLease(leaseID: leaseID, connectionID: connectionID,
                                      expiresAt: now.addingTimeInterval(duration))
        lease = renewed
        return renewed
    }

    public mutating func release(leaseID: UUID, connectionID: UUID, now: Date = .now) throws {
        discardExpired(now: now)
        guard let current = lease, current.leaseID == leaseID,
              current.connectionID == connectionID else { throw RemoteError.controlDenied }
        lease = nil
    }

    public mutating func authorizes(leaseID: UUID, connectionID: UUID, now: Date = .now) -> Bool {
        discardExpired(now: now)
        return lease?.leaseID == leaseID && lease?.connectionID == connectionID
    }

    public mutating func revoke(connectionID: UUID) {
        if lease?.connectionID == connectionID { lease = nil }
    }

    private mutating func discardExpired(now: Date) {
        if let lease, lease.expiresAt <= now { self.lease = nil }
    }
}
