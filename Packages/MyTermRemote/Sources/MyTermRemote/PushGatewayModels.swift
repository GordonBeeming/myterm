import CryptoKit
import Foundation

public struct PushEnrollmentChallenge: Equatable, Sendable {
    public let enrollmentID: UUID
    public let challenge: Data
    public let expiresAt: Date
}

public struct PushAttestationSubmission: Sendable {
    public let keyID: String
    public let attestationObject: Data
    public let devicePublicKey: Data
    public let apnsToken: Data

    public init(keyID: String, attestationObject: Data, devicePublicKey: Data,
                apnsToken: Data) throws {
        guard !keyID.isEmpty, !attestationObject.isEmpty, devicePublicKey.count == 65,
              !apnsToken.isEmpty else { throw RemoteError.invalidMessage }
        _ = try P256.Signing.PublicKey(x963Representation: devicePublicKey)
        self.keyID = keyID
        self.attestationObject = attestationObject
        self.devicePublicKey = devicePublicKey
        self.apnsToken = apnsToken
    }
}

public struct PushRecipientSession: Codable, Equatable, Sendable {
    public let gatewayOrigin: RelayEndpoint
    public let recipientID: UUID
    public let deviceSessionToken: String

    public init(gatewayOrigin: RelayEndpoint, recipientID: UUID,
                deviceSessionToken: String) throws {
        guard !deviceSessionToken.isEmpty, !deviceSessionToken.contains(where: { $0.isWhitespace }) else {
            throw RemoteError.invalidMessage
        }
        self.gatewayOrigin = gatewayOrigin
        self.recipientID = recipientID
        self.deviceSessionToken = deviceSessionToken
    }

    public func validate() throws {
        guard !deviceSessionToken.isEmpty,
              !deviceSessionToken.contains(where: { $0.isWhitespace }) else {
            throw RemoteError.invalidResponse
        }
    }
}

public struct NotificationGrantRegistration: Codable, Equatable, Sendable {
    public let gatewayOrigin: RelayEndpoint
    public let recipientID: UUID
    public let grantID: UUID
    public let grantToken: String
    public let recipientEncryptionPublicKey: Data

    public init(gatewayOrigin: RelayEndpoint, recipientID: UUID, grantID: UUID,
                grantToken: String, recipientEncryptionPublicKey: Data) throws {
        guard !grantToken.isEmpty, !grantToken.contains(where: { $0.isWhitespace }),
              recipientEncryptionPublicKey.count == 65 else { throw RemoteError.invalidMessage }
        _ = try P256.KeyAgreement.PublicKey(x963Representation: recipientEncryptionPublicKey)
        self.gatewayOrigin = gatewayOrigin
        self.recipientID = recipientID
        self.grantID = grantID
        self.grantToken = grantToken
        self.recipientEncryptionPublicKey = recipientEncryptionPublicKey
    }

    public func validate() throws {
        guard !grantToken.isEmpty, !grantToken.contains(where: { $0.isWhitespace }) else {
            throw RemoteError.invalidResponse
        }
        _ = try P256.KeyAgreement.PublicKey(x963Representation: recipientEncryptionPublicKey)
    }
}

public struct PushNotificationPlaintext: Codable, Equatable, Sendable {
    public let title: String
    public let body: String
    public let hostID: UUID
    public let workspaceID: UUID?
    public let tabID: UUID?
    public let sessionID: UUID?

    public init(title: String, body: String, hostID: UUID, workspaceID: UUID? = nil,
                tabID: UUID? = nil, sessionID: UUID? = nil) throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.utf8.count <= 128, !body.isEmpty, body.utf8.count <= 512 else {
            throw RemoteError.messageTooLarge
        }
        self.title = title
        self.body = body
        self.hostID = hostID
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.sessionID = sessionID
    }

    public func validate() throws {
        guard !title.isEmpty, title.utf8.count <= 128,
              !body.isEmpty, body.utf8.count <= 512 else { throw RemoteError.messageTooLarge }
    }
}

public struct PushNotificationContext: Equatable, Sendable {
    public let gatewayOrigin: RelayEndpoint
    public let relayOrigin: RelayEndpoint
    public let hostID: UUID
    public let grantID: UUID
    public let recipientID: UUID
    public let eventID: UUID
    public let timestamp: Int64

    public init(gatewayOrigin: RelayEndpoint, relayOrigin: RelayEndpoint, hostID: UUID,
                grantID: UUID, recipientID: UUID, eventID: UUID, timestamp: Int64) {
        self.gatewayOrigin = gatewayOrigin
        self.relayOrigin = relayOrigin
        self.hostID = hostID
        self.grantID = grantID
        self.recipientID = recipientID
        self.eventID = eventID
        self.timestamp = timestamp
    }

    public var authenticatedBytes: Data {
        Data("myterm-notification-v1\n\(gatewayOrigin.canonicalOrigin)\n\(relayOrigin.canonicalOrigin)\n\(hostID.lowercase)\n\(grantID.lowercase)\n\(recipientID.lowercase)\n\(eventID.lowercase)\n\(timestamp)".utf8)
    }
}

public struct PushNotificationRequest: Codable, Equatable, Sendable {
    public let eventID: UUID
    public let timestamp: Int64
    public let ciphertext: Data
    public let hostSignature: Data

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case timestamp, ciphertext
        case hostSignature = "host_signature"
    }

    public init(eventID: UUID, timestamp: Int64, ciphertext: Data, hostSignature: Data) {
        self.eventID = eventID; self.timestamp = timestamp
        self.ciphertext = ciphertext; self.hostSignature = hostSignature
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard let eventID = UUID(uuidString: try values.decode(String.self, forKey: .eventID)),
              let ciphertext = Data(base64URL: try values.decode(String.self, forKey: .ciphertext)),
              let signature = Data(base64URL: try values.decode(String.self, forKey: .hostSignature)) else {
            throw RemoteError.invalidMessage
        }
        self.eventID = eventID
        timestamp = try values.decode(Int64.self, forKey: .timestamp)
        self.ciphertext = ciphertext
        hostSignature = signature
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(eventID.uuidString.lowercased(), forKey: .eventID)
        try values.encode(timestamp, forKey: .timestamp)
        try values.encode(ciphertext.base64URL, forKey: .ciphertext)
        try values.encode(hostSignature.base64URL, forKey: .hostSignature)
    }
}

public struct PushAPNSEvent: Codable, Equatable, Sendable {
    public let version: Int
    public let grantID: UUID
    public let recipientID: UUID
    public let eventID: UUID
    public let timestamp: Int64
    public let ciphertext: Data

    enum CodingKeys: String, CodingKey {
        case version, timestamp, ciphertext
        case grantID = "grant_id"
        case recipientID = "recipient_id"
        case eventID = "event_id"
    }

    public init(grantID: UUID, recipientID: UUID, eventID: UUID,
                timestamp: Int64, ciphertext: Data) {
        version = 1; self.grantID = grantID; self.recipientID = recipientID
        self.eventID = eventID; self.timestamp = timestamp; self.ciphertext = ciphertext
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        grantID = try values.decode(UUID.self, forKey: .grantID)
        recipientID = try values.decode(UUID.self, forKey: .recipientID)
        eventID = try values.decode(UUID.self, forKey: .eventID)
        timestamp = try values.decode(Int64.self, forKey: .timestamp)
        guard version == 1,
              let data = Data(base64URL: try values.decode(String.self, forKey: .ciphertext)),
              !data.isEmpty, data.count <= 4_096 else {
            throw RemoteError.invalidMessage
        }
        ciphertext = data
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(grantID.uuidString.lowercased(), forKey: .grantID)
        try values.encode(recipientID.uuidString.lowercased(), forKey: .recipientID)
        try values.encode(eventID.uuidString.lowercased(), forKey: .eventID)
        try values.encode(timestamp, forKey: .timestamp)
        try values.encode(ciphertext.base64URL, forKey: .ciphertext)
    }

    public func context(using pin: PushRecipientGrantPin) throws -> PushNotificationContext {
        guard pin.grantID == grantID, pin.recipientID == recipientID else { throw RemoteError.wrongPeer }
        return PushNotificationContext(gatewayOrigin: pin.gatewayOrigin,
                                       relayOrigin: pin.relayOrigin, hostID: pin.hostID,
                                       grantID: grantID, recipientID: recipientID,
                                       eventID: eventID, timestamp: timestamp)
    }

    public func requestForDecryption() -> PushNotificationRequest {
        PushNotificationRequest(eventID: eventID, timestamp: timestamp,
                                ciphertext: ciphertext, hostSignature: Data())
    }
}

extension UUID {
    fileprivate var lowercase: String { uuidString.lowercased() }
}
