import CryptoKit
import Foundation

public enum HelloHandshake {
    public static func challenge(deviceID: UUID,
                                 agreementKey: P256.KeyAgreement.PublicKey,
                                 notificationSigningKey: P256.Signing.PublicKey,
                                 capabilities: [String]) -> HelloParameters {
        HelloParameters(
            phase: .challenge, generation: UUID(), deviceID: deviceID,
            agreementPublicKey: agreementKey.x963Representation,
            notificationSigningPublicKey: notificationSigningKey.x963Representation,
            applicationEpoch: nil, challenge: randomChallenge(), response: nil,
            capabilities: capabilities
        )
    }

    public static func response(to client: HelloParameters, hostDeviceID: UUID,
                                agreementKey: P256.KeyAgreement.PublicKey,
                                notificationSigningKey: P256.Signing.PublicKey,
                                capabilities: [String]) throws -> HelloParameters {
        guard client.phase == .challenge, let clientChallenge = client.challenge,
              clientChallenge.count == 32, client.response == nil else {
            throw RemoteError.invalidMessage
        }
        return HelloParameters(
            phase: .response, generation: client.generation, deviceID: hostDeviceID,
            agreementPublicKey: agreementKey.x963Representation,
            notificationSigningPublicKey: notificationSigningKey.x963Representation,
            applicationEpoch: UUID(), challenge: randomChallenge(),
            response: clientChallenge, capabilities: capabilities
        )
    }

    public static func validate(response: HelloParameters, to client: HelloParameters,
                                pinnedHostAgreementKey: P256.KeyAgreement.PublicKey,
                                pinnedHostNotificationSigningKey: P256.Signing.PublicKey) throws {
        guard client.phase == .challenge, response.phase == .response,
              response.generation == client.generation,
              response.response == client.challenge,
              response.challenge?.count == 32,
              response.applicationEpoch != nil,
              response.agreementPublicKey == pinnedHostAgreementKey.x963Representation,
              response.notificationSigningPublicKey == pinnedHostNotificationSigningKey.x963Representation else {
            throw RemoteError.wrongPeer
        }
    }

    public static func acknowledgement(to host: HelloParameters,
                                       client: HelloParameters) throws -> HelloParameters {
        guard host.phase == .response, client.phase == .challenge,
              host.generation == client.generation,
              host.response == client.challenge,
              let hostChallenge = host.challenge, hostChallenge.count == 32 else {
            throw RemoteError.wrongPeer
        }
        return HelloParameters(
            phase: .acknowledgement, generation: client.generation,
            deviceID: client.deviceID, agreementPublicKey: client.agreementPublicKey,
            notificationSigningPublicKey: client.notificationSigningPublicKey,
            applicationEpoch: host.applicationEpoch, challenge: nil,
            response: hostChallenge, capabilities: client.capabilities
        )
    }

    public static func validate(acknowledgement: HelloParameters,
                                to host: HelloParameters,
                                pinnedClientAgreementKey: P256.KeyAgreement.PublicKey,
                                pinnedClientNotificationSigningKey: P256.Signing.PublicKey) throws {
        guard host.phase == .response, acknowledgement.phase == .acknowledgement,
              acknowledgement.generation == host.generation,
              acknowledgement.response == host.challenge,
              acknowledgement.applicationEpoch == host.applicationEpoch,
              acknowledgement.challenge == nil,
              acknowledgement.agreementPublicKey == pinnedClientAgreementKey.x963Representation,
              acknowledgement.notificationSigningPublicKey == pinnedClientNotificationSigningKey.x963Representation else {
            throw RemoteError.wrongPeer
        }
    }

    private static func randomChallenge() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }
}
