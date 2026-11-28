import CryptoKit
import Foundation
import MyTermRemote
import Testing

@Test func relayAdmissionHandoffAuthenticatesAnExactCandidateAndServer() throws {
    let relay = try RelayEndpoint(#require(URL(string: "https://relay.example.test")))
    let otherRelay = try RelayEndpoint(#require(URL(string: "https://other.example.test")))
    let accountID = UUID()
    let phone = Curve25519.Signing.PrivateKey()
    let tablet = Curve25519.Signing.PrivateKey()
    let approver = Curve25519.Signing.PrivateKey()
    let server = Curve25519.Signing.PrivateKey()
    let now = Date(timeIntervalSince1970: 10_000)
    let anchor = String(repeating: "a3", count: 32)
    let original = try RelayAdmissionRequest(relay: relay, accountID: accountID, signer: phone, now: now)
    let request = try RelayAdmissionRequest(code: original.code)
    #expect(request.endpointID.count == 64)
    #expect(request.signingKey == phone.publicKey.rawRepresentation.base64URL)
    try request.verify(relay: relay, accountID: accountID, now: now)

    let approval = try RelayAdmissionApproval(
        request: request, relay: relay, accountID: accountID, anchor: anchor,
        serverSigningKey: server.publicKey, approver: approver, now: now.addingTimeInterval(10)
    )
    let imported = try RelayAdmissionApproval(code: approval.code)
    let verified = try imported.verify(request: original, relay: relay, accountID: accountID,
                                       now: now.addingTimeInterval(11))
    #expect(verified.anchor == anchor)
    #expect(verified.serverSigningKey == server.publicKey.rawRepresentation.base64URL)
    #expect(verified.approverSigningKey == approver.publicKey.rawRepresentation.base64URL)

    let differentRequest = try RelayAdmissionRequest(relay: relay, accountID: accountID, signer: tablet, now: now)
    #expect(throws: RemoteError.wrongPeer) {
        try imported.verify(request: differentRequest, relay: relay, accountID: accountID, now: now)
    }
    #expect(throws: RemoteError.wrongPeer) {
        try imported.verify(request: original, relay: otherRelay, accountID: accountID, now: now)
    }
    #expect(throws: RemoteError.wrongPeer) {
        try imported.verify(request: original, relay: relay, accountID: UUID(), now: now)
    }
    #expect(throws: RemoteError.expiredPairing) {
        try imported.verify(request: original, relay: relay, accountID: accountID, now: now.addingTimeInterval(300))
    }
    #expect(throws: RemoteError.expiredPairing) {
        try request.verify(relay: relay, accountID: accountID, now: now.addingTimeInterval(-60))
    }
}

@Test func relayAdmissionHandoffRejectsAlteredSignedPayloads() throws {
    let relay = try RelayEndpoint(#require(URL(string: "https://relay.example.test")))
    let accountID = UUID()
    let now = Date(timeIntervalSince1970: 10_000)
    let request = try RelayAdmissionRequest(relay: relay, accountID: accountID,
        signer: Curve25519.Signing.PrivateKey(), now: now)
    let approval = try RelayAdmissionApproval(request: request, relay: relay, accountID: accountID,
        anchor: String(repeating: "ab", count: 32), serverSigningKey: Curve25519.Signing.PrivateKey().publicKey,
        approver: Curve25519.Signing.PrivateKey(), now: now)
    let version = "myterm-relay-approval-v1."
    #expect(approval.code.hasPrefix(version))
    let payload = try #require(Data(base64URL: String(approval.code.dropFirst(version.count))))
    let altered = String(decoding: payload, as: UTF8.self)
        .replacingOccurrences(of: String(repeating: "ab", count: 32), with: String(repeating: "ba", count: 32))
    #expect(altered != String(decoding: payload, as: UTF8.self))
    let invalid = try RelayAdmissionApproval(code: version + Data(altered.utf8).base64URL)
    #expect(throws: RemoteError.wrongPeer) {
        try invalid.verify(request: request, relay: relay, accountID: accountID, now: now)
    }
}
