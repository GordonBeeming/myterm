import CryptoKit
import Foundation

public enum AccountEnrollmentError: LocalizedError, Sendable, Equatable {
    case invalidArtifact
    case invalidSignature
    case wrongAccount
    case freshApprovalRequired
    case identityConflict
    case identityRemoved
    case invalidCheckpoint
    case localAuthorityFailed

    public var errorDescription: String? {
        switch self {
        case .invalidArtifact: "The server sent invalid enrollment information."
        case .invalidSignature: "MyTerm could not verify the enrollment signature."
        case .wrongAccount: "This enrollment belongs to a different personal account."
        case .freshApprovalRequired: "This MyTerm server needs fresh approval from a trusted endpoint."
        case .identityConflict: "This server identity is already bound to a different enrollment."
        case .identityRemoved: "This MyTerm server was removed from the personal account."
        case .invalidCheckpoint: "MyTerm could not verify the order of the membership update."
        case .localAuthorityFailed: "The local MyTerm enrollment authority could not complete the request."
        }
    }
}

public protocol AccountEnrollmentStatement: Codable, Sendable {
    static var signingPurpose: String { get }
}

public struct SignedAccountEnrollment: Codable, Sendable, Equatable {
    private static let maximumStatement = 16 * 1024
    private let statement: String
    private let signature: String

    public init<T: AccountEnrollmentStatement>(_ value: T, signer: Curve25519.Signing.PrivateKey) throws {
        let bytes = try Self.encode(value)
        statement = bytes.enrollmentBase64
        signature = try signer.signature(for: Self.message(bytes, type: T.self)).enrollmentBase64
    }

    func read<T: AccountEnrollmentStatement>(_ type: T.Type) throws -> T {
        try decode(Self.statementBytes(statement), type: type)
    }

    public func verify<T: AccountEnrollmentStatement>(_ type: T.Type, signer: EnrollmentSigningIdentity) throws -> T {
        let bytes = try Self.statementBytes(statement)
        guard signature.utf8.count == 86,
              let signatureBytes = Data(enrollmentBase64: signature, byteCount: 64),
              try signer.publicKey().isValidSignature(signatureBytes, for: Self.message(bytes, type: type)) else {
            throw AccountEnrollmentError.invalidSignature
        }
        return try decode(bytes, type: type)
    }

    public func digest<T: AccountEnrollmentStatement>(_ type: T.Type) throws -> String {
        let bytes = try Self.statementBytes(statement)
        return SHA256.hash(data: try Self.message(bytes, type: type)).enrollmentHex
    }

    static func digest<T: AccountEnrollmentStatement>(of value: T) throws -> String {
        SHA256.hash(data: try message(encode(value), type: T.self)).enrollmentHex
    }

    private func decode<T: AccountEnrollmentStatement>(_ bytes: Data, type: T.Type) throws -> T {
        let value = try JSONDecoder().decode(type, from: bytes)
        // Foundation's decoder can ignore unknown fields and accept duplicate keys.
        guard try Self.encode(value) == bytes else { throw AccountEnrollmentError.invalidArtifact }
        return value
    }

    private static func encode<T: AccountEnrollmentStatement>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func statementBytes(_ statement: String) throws -> Data {
        let maximumEncoded = ((maximumStatement + 2) / 3) * 4
        guard statement.utf8.count <= maximumEncoded,
              let bytes = Data(enrollmentBase64: statement),
              bytes.count <= maximumStatement else {
            throw AccountEnrollmentError.invalidArtifact
        }
        return bytes
    }

    private static func message<T: AccountEnrollmentStatement>(_ bytes: Data, type: T.Type) throws -> Data {
        guard bytes.count <= maximumStatement else { throw AccountEnrollmentError.invalidArtifact }
        return Data("myterm-account-v1:\(type.signingPurpose)\u{0}".utf8) + bytes
    }
}

public struct EnrollmentSigningIdentity: Codable, Sendable, Equatable {
    private let value: String

    public init(_ publicKey: Curve25519.Signing.PublicKey) {
        value = publicKey.rawRepresentation.enrollmentBase64
    }

    public init(from decoder: any Decoder) throws {
        value = try decoder.singleValueContainer().decode(String.self)
        _ = try publicKey()
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    public var id: String {
        get throws { SHA256.hash(data: try publicKey().rawRepresentation).enrollmentHex }
    }

    func publicKey() throws -> Curve25519.Signing.PublicKey {
        guard let bytes = Data(enrollmentBase64: value, byteCount: 32) else {
            throw AccountEnrollmentError.invalidArtifact
        }
        return try Curve25519.Signing.PublicKey(rawRepresentation: bytes)
    }
}

public struct EnrollmentAccountGenesis: AccountEnrollmentStatement {
    public static let signingPurpose = "genesis"
    public let firstClient: EnrollmentSigningIdentity
    public let authority: EnrollmentSigningIdentity
    private let nonce: String

    public init(firstClient: EnrollmentSigningIdentity, authority: EnrollmentSigningIdentity) {
        self.firstClient = firstClient
        self.authority = authority
        var generator = SystemRandomNumberGenerator()
        nonce = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }).enrollmentBase64
    }

    public static func binding(from signed: SignedAccountEnrollment) throws -> EnrollmentAccountBinding {
        let unverified = try signed.read(Self.self)
        let verified = try signed.verify(Self.self, signer: unverified.firstClient)
        guard verified.firstClient != verified.authority,
              Data(enrollmentBase64: verified.nonce, byteCount: 32) != nil else {
            throw AccountEnrollmentError.invalidArtifact
        }
        return try EnrollmentAccountBinding(anchor: signed.digest(Self.self), genesis: signed)
    }
}

public struct EnrollmentAccountBinding: Codable, Sendable, Equatable {
    public let anchor: String
    public let genesis: SignedAccountEnrollment

    public init(anchor: String, genesis: SignedAccountEnrollment) {
        self.anchor = anchor
        self.genesis = genesis
    }

    public func verifiedAuthority(pinnedAnchor: String) throws -> EnrollmentSigningIdentity {
        guard anchor == pinnedAnchor, try EnrollmentAccountGenesis.binding(from: genesis).anchor == anchor else {
            throw AccountEnrollmentError.wrongAccount
        }
        return try genesis.read(EnrollmentAccountGenesis.self).authority
    }
}

public enum EnrollmentCredentialMode: String, Codable, Sendable {
    case singleUse = "single-use"
    case reusable
}

public struct IssueEnrollmentCredential: AccountEnrollmentStatement {
    public static let signingPurpose = "issue-enrollment-credential"
    public let account: String
    public let operation: String
    public let creator: EnrollmentSigningIdentity
    public let holder: EnrollmentSigningIdentity
    public let mode: EnrollmentCredentialMode
    public let lifetimeSeconds: Int64?

    public init(
        account: String, operation: UUID = UUID(), creator: EnrollmentSigningIdentity,
        holder: EnrollmentSigningIdentity, mode: EnrollmentCredentialMode = .singleUse, lifetimeSeconds: Int64? = nil
    ) {
        self.account = account
        self.operation = operation.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        self.creator = creator
        self.holder = holder
        self.mode = mode
        self.lifetimeSeconds = lifetimeSeconds
    }
}

public enum EnrollmentCredentialStatus: String, Codable, Sendable {
    case active
    case expiresWithinSevenDays = "expires-within-seven-days"
    case expiresWithinOneDay = "expires-within-one-day"
    case expired
}

public struct ServerEnrollmentCredential: AccountEnrollmentStatement, Equatable {
    public static let signingPurpose = "server-enrollment-credential"
    public let account: String
    public let id: String
    public let creator: EnrollmentSigningIdentity
    public let holder: EnrollmentSigningIdentity
    public let mode: EnrollmentCredentialMode
    public let issuedAt: Int64
    public let expiresAt: Int64

    public static func verified(
        _ signed: SignedAccountEnrollment, binding: EnrollmentAccountBinding, pinnedAnchor: String
    ) throws -> Self {
        let signer = try binding.verifiedAuthority(pinnedAnchor: pinnedAnchor)
        let certificate = try signed.verify(Self.self, signer: signer)
        guard certificate.account == pinnedAnchor else { throw AccountEnrollmentError.wrongAccount }
        try certificate.validate()
        return certificate
    }

    func validate() throws {
        guard id.isEnrollmentHex(byteCount: 32), issuedAt > 0, expiresAt > issuedAt,
              mode == .reusable || expiresAt - issuedAt <= 1_800 else {
            throw AccountEnrollmentError.invalidArtifact
        }
    }

    public func status(at time: Int64) -> EnrollmentCredentialStatus {
        guard time < expiresAt else { return .expired }
        let (remaining, overflow) = expiresAt.subtractingReportingOverflow(time)
        if overflow { return .active }
        switch remaining {
        case ...86_400: return .expiresWithinOneDay
        case ...604_800: return .expiresWithinSevenDays
        default: return .active
        }
    }
}

public struct ServerEnrollmentRequest: AccountEnrollmentStatement, Equatable {
    public static let signingPurpose = "server-enrollment-request"
    public let account: String
    public let credential: String
    public let server: EnrollmentSigningIdentity
    public let name: String
    public let relayAccess: Bool

    public static func verified(_ signed: SignedAccountEnrollment, pinnedAnchor: String) throws -> Self {
        let unverified = try signed.read(Self.self)
        let request = try signed.verify(Self.self, signer: unverified.server)
        guard request.account == pinnedAnchor else { throw AccountEnrollmentError.wrongAccount }
        try request.validate()
        return request
    }

    func validate() throws {
        guard credential.isEnrollmentHex(byteCount: 32),
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.utf8.count <= 160,
              !name.unicodeScalars.contains(where: { (0x00...0x1F).contains($0.value) || (0x7F...0x9F).contains($0.value) }) else {
            throw AccountEnrollmentError.invalidArtifact
        }
    }
}

struct EnrollmentHolderProof: AccountEnrollmentStatement {
    static let signingPurpose = "server-enrollment-holder-proof"
    let enrollmentDigest: String
}

public struct ServerEnrollmentPresentation: Codable, Sendable, Equatable {
    public let credential: SignedAccountEnrollment
    public let request: SignedAccountEnrollment
    public let possession: SignedAccountEnrollment

    public func verified(
        binding: EnrollmentAccountBinding, pinnedAnchor: String
    ) throws -> (credential: ServerEnrollmentCredential, request: ServerEnrollmentRequest) {
        let credential = try ServerEnrollmentCredential.verified(credential, binding: binding, pinnedAnchor: pinnedAnchor)
        let requestValue = try ServerEnrollmentRequest.verified(request, pinnedAnchor: pinnedAnchor)
        guard requestValue.credential == credential.id,
              try possession.verify(EnrollmentHolderProof.self, signer: credential.holder).enrollmentDigest
                == request.digest(ServerEnrollmentRequest.self) else {
            throw AccountEnrollmentError.invalidArtifact
        }
        return (credential, requestValue)
    }
}

public struct ServerEnrollmentAdmission: Codable, Sendable, Equatable {
    public let request: ServerEnrollmentRequest
    public let enrollmentDigest: String
    public let confirmedBy: EnrollmentSigningIdentity?
}

public enum EnrollmentMembershipChange: Codable, Sendable, Equatable {
    case issue(ServerEnrollmentCredential)
    case admit(ServerEnrollmentAdmission)
    case revokeCredential(String)
    case removeIdentity(EnrollmentSigningIdentity)
    case freshApprove(SignedAccountEnrollment)

    private enum CodingKeys: String, CodingKey { case kind, value }
    private enum Kind: String, Codable {
        case issue, admit
        case revokeCredential = "revoke-credential"
        case removeIdentity = "remove-identity"
        case freshApprove = "fresh-approve"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .issue: self = .issue(try container.decode(ServerEnrollmentCredential.self, forKey: .value))
        case .admit: self = .admit(try container.decode(ServerEnrollmentAdmission.self, forKey: .value))
        case .revokeCredential: self = .revokeCredential(try container.decode(String.self, forKey: .value))
        case .removeIdentity: self = .removeIdentity(try container.decode(EnrollmentSigningIdentity.self, forKey: .value))
        case .freshApprove: self = .freshApprove(try container.decode(SignedAccountEnrollment.self, forKey: .value))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .issue(let value):
            try container.encode(Kind.issue, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .admit(let value):
            try container.encode(Kind.admit, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .revokeCredential(let value):
            try container.encode(Kind.revokeCredential, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .removeIdentity(let value):
            try container.encode(Kind.removeIdentity, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .freshApprove(let value):
            try container.encode(Kind.freshApprove, forKey: .kind)
            try container.encode(value, forKey: .value)
        }
    }
}

public struct ManageServerEnrollment: AccountEnrollmentStatement {
    public static let signingPurpose = "manage-server-enrollment"
    public let account: String
    public let operation: String
    public let actor: EnrollmentSigningIdentity
    public let change: EnrollmentMembershipChange

    public init(account: String, operation: UUID = UUID(), actor: EnrollmentSigningIdentity, change: EnrollmentMembershipChange) {
        self.account = account
        self.operation = operation.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        self.actor = actor
        self.change = change
    }
}

public struct EnrollmentMembershipEvent: AccountEnrollmentStatement {
    public static let signingPurpose = "membership-event"
    public let account: String
    public let sequence: Int64
    public let previous: String
    public let change: EnrollmentMembershipChange
}

extension Data {
    fileprivate var enrollmentBase64: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    fileprivate init?(enrollmentBase64 value: String, byteCount: Int? = nil) {
        let padding = (4 - value.utf8.count % 4) % 4
        let standard = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let decoded = Data(base64Encoded: standard + String(repeating: "=", count: padding)),
              byteCount == nil || byteCount == decoded.count, decoded.enrollmentBase64 == value else {
            return nil
        }
        self = decoded
    }
}

extension String {
    fileprivate func isEnrollmentHex(byteCount: Int) -> Bool {
        utf8.count == byteCount * 2 && utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

extension Sequence<UInt8> {
    fileprivate var enrollmentHex: String { map { String(format: "%02x", $0) }.joined() }
}
