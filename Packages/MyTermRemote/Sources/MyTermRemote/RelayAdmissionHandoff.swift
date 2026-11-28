import CryptoKit
import Foundation

/// A candidate's possession proof, carried directly to an already trusted endpoint.
public struct RelayAdmissionRequest: Sendable {
    private struct Payload: Codable, Sendable {
        let origin: String
        let accountID: UUID
        let signingKey: String
        let nonce: String
        let issuedAt: Int64
    }

    private static let prefix = "myterm-relay-request-v1."
    private let envelope: AdmissionEnvelope<Payload>
    public let code: String

    public var signingKey: String { envelope.payload.signingKey }

    public let endpointID: String

    public init(relay: RelayEndpoint, accountID: UUID,
                signer: Curve25519.Signing.PrivateKey, now: Date = .now) throws {
        let nonce = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64URL }
        let payload = Payload(
            origin: relay.canonicalOrigin, accountID: accountID,
            signingKey: signer.publicKey.rawRepresentation.base64URL, nonce: nonce,
            issuedAt: try AdmissionEncoding.timestamp(now)
        )
        envelope = try AdmissionEnvelope(payload: payload, signer: signer, prefix: Self.prefix)
        code = try envelope.encode(prefix: Self.prefix)
        endpointID = AdmissionEncoding.endpointID(signer.publicKey)
    }

    public init(code: String) throws {
        envelope = try AdmissionEnvelope(code: code, prefix: Self.prefix)
        endpointID = try AdmissionEncoding.endpointID(AdmissionEncoding.publicKey(envelope.payload.signingKey))
        self.code = code
    }

    public func verify(relay: RelayEndpoint, accountID: UUID, now: Date = .now) throws {
        let payload = envelope.payload
        guard payload.origin == relay.canonicalOrigin, payload.accountID == accountID else { throw RemoteError.wrongPeer }
        _ = try AdmissionEncoding.bytes(payload.nonce, count: 32)
        try AdmissionEncoding.checkTime(payload.issuedAt, now: now)
        try envelope.verify(signer: AdmissionEncoding.publicKey(payload.signingKey), prefix: Self.prefix)
    }

    fileprivate var digest: String {
        Data(SHA256.hash(data: Data(code.utf8))).base64URL
    }
}

public struct RelayAdmissionPins: Sendable {
    public let anchor: String
    public let serverSigningKey: String
    public let approverSigningKey: String
    public let pairingURL: URL?
}

/// An approval to deliver directly to the candidate. An out-of-band transfer from the trusted
/// endpoint authenticates the approver key. A relay lookup cannot establish that trust.
public struct RelayAdmissionApproval: Sendable {
    private struct Payload: Codable, Sendable {
        let origin: String
        let accountID: UUID
        let requestDigest: String
        let anchor: String
        let serverSigningKey: String
        let approverSigningKey: String
        let pairingURL: URL?
        let issuedAt: Int64
    }

    private static let prefix = "myterm-relay-approval-v1."
    private let envelope: AdmissionEnvelope<Payload>
    public let code: String

    /// Create only after the person approves the device and the Worker accepts the signed admission.
    public init(request: RelayAdmissionRequest, relay: RelayEndpoint, accountID: UUID, anchor: String,
                serverSigningKey: Curve25519.Signing.PublicKey, approver: Curve25519.Signing.PrivateKey,
                pairingURL: URL? = nil, now: Date = .now) throws {
        try request.verify(relay: relay, accountID: accountID, now: now)
        guard AdmissionEncoding.validAnchor(anchor) else { throw RemoteError.invalidMessage }
        if let pairingURL, try PairingTicket.decode(qrURL: pairingURL, now: now).relay != relay {
            throw RemoteError.wrongPeer
        }
        let payload = Payload(
            origin: relay.canonicalOrigin, accountID: accountID, requestDigest: request.digest, anchor: anchor,
            serverSigningKey: serverSigningKey.rawRepresentation.base64URL,
            approverSigningKey: approver.publicKey.rawRepresentation.base64URL,
            pairingURL: pairingURL,
            issuedAt: try AdmissionEncoding.timestamp(now)
        )
        envelope = try AdmissionEnvelope(payload: payload, signer: approver, prefix: Self.prefix)
        code = try envelope.encode(prefix: Self.prefix)
    }

    public init(code: String) throws {
        envelope = try AdmissionEnvelope(code: code, prefix: Self.prefix)
        self.code = code
    }

    public func verify(request: RelayAdmissionRequest, relay: RelayEndpoint, accountID: UUID,
                       now: Date = .now) throws -> RelayAdmissionPins {
        try request.verify(relay: relay, accountID: accountID, now: now)
        let payload = envelope.payload
        guard payload.origin == relay.canonicalOrigin, payload.accountID == accountID,
              payload.requestDigest == request.digest else { throw RemoteError.wrongPeer }
        guard AdmissionEncoding.validAnchor(payload.anchor) else { throw RemoteError.invalidMessage }
        try AdmissionEncoding.checkTime(payload.issuedAt, now: now)
        try envelope.verify(signer: AdmissionEncoding.publicKey(payload.approverSigningKey), prefix: Self.prefix)
        _ = try AdmissionEncoding.publicKey(payload.serverSigningKey)
        if let pairingURL = payload.pairingURL, try PairingTicket.decode(qrURL: pairingURL, now: now).relay != relay {
            throw RemoteError.wrongPeer
        }
        return RelayAdmissionPins(anchor: payload.anchor, serverSigningKey: payload.serverSigningKey,
                                  approverSigningKey: payload.approverSigningKey, pairingURL: payload.pairingURL)
    }
}

private struct AdmissionEnvelope<Payload: Codable & Sendable>: Codable, Sendable {
    let payload: Payload
    let signature: String

    init(payload: Payload, signer: Curve25519.Signing.PrivateKey, prefix: String) throws {
        self.payload = payload
        signature = try signer.signature(for: Self.message(payload, prefix: prefix)).base64URL
    }

    init(code: String, prefix: String) throws {
        guard code.utf8.count <= 4096, code.hasPrefix(prefix),
              let data = Data(base64URL: String(code.dropFirst(prefix.count))),
              let envelope = try? JSONDecoder().decode(Self.self, from: data),
              try envelope.encode(prefix: prefix) == code else { throw RemoteError.invalidMessage }
        self = envelope
    }

    func encode(prefix: String) throws -> String {
        try prefix + AdmissionEncoding.encoder().encode(self).base64URL
    }

    func verify(signer: Curve25519.Signing.PublicKey, prefix: String) throws {
        let bytes = try AdmissionEncoding.bytes(signature, count: 64)
        guard try signer.isValidSignature(bytes, for: Self.message(payload, prefix: prefix)) else {
            throw RemoteError.wrongPeer
        }
    }

    private static func message(_ payload: Payload, prefix: String) throws -> Data {
        try Data((prefix + "\u{0}").utf8) + AdmissionEncoding.encoder().encode(payload)
    }
}

private enum AdmissionEncoding {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func bytes(_ encoded: String, count: Int) throws -> Data {
        guard let data = Data(base64URL: encoded), data.count == count,
              data.base64URL == encoded else { throw RemoteError.invalidMessage }
        return data
    }

    static func publicKey(_ encoded: String) throws -> Curve25519.Signing.PublicKey {
        try Curve25519.Signing.PublicKey(rawRepresentation: bytes(encoded, count: 32))
    }

    static func endpointID(_ key: Curve25519.Signing.PublicKey) -> String {
        SHA256.hash(data: key.rawRepresentation).map { String(format: "%02x", $0) }.joined()
    }

    static func validAnchor(_ anchor: String) -> Bool {
        anchor.utf8.count == 64 && anchor.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func timestamp(_ now: Date) throws -> Int64 {
        guard let seconds = Int64(exactly: now.timeIntervalSince1970.rounded(.down)) else {
            throw RemoteError.invalidMessage
        }
        return seconds
    }

    static func checkTime(_ issuedAt: Int64, now: Date) throws {
        let age = now.timeIntervalSince1970 - Double(issuedAt)
        guard age >= -30, age < 300 else { throw RemoteError.expiredPairing }
    }
}
