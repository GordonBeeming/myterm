import CryptoKit
import Foundation
import os
import Testing
@testable import MyTermRemote

@Test func enrollmentRejectsAmbiguousSignedJSON() throws {
    let key = Curve25519.Signing.PrivateKey()
    let signer = EnrollmentSigningIdentity(key.publicKey)
    let invalid = [
        #"{"enrollmentDigest":"first","enrollmentDigest":"second"}"#,
        #"{ "enrollmentDigest":"first"}"#,
        #"{"enrollmentDigest":"first","unrecognized":"field"}"#,
    ]
    for json in invalid {
        let statement = Data(json.utf8)
        let input = Data("myterm-account-v1:server-enrollment-holder-proof\u{0}".utf8) + statement
        let signature = try key.signature(for: input)
        let envelope = try JSONSerialization.data(withJSONObject: [
            "statement": base64URL(statement), "signature": base64URL(signature),
        ])
        let signed = try JSONDecoder().decode(SignedAccountEnrollment.self, from: envelope)
        #expect(throws: (any Error).self) {
            try signed.verify(EnrollmentHolderProof.self, signer: signer)
        }
    }
}

#if os(macOS)
@Test(.enabled(if: ProcessInfo.processInfo.environment["MYTERM_ENROLLMENT_RUST_BINARY"] != nil))
func enrollmentSwiftAndRustAgreeAcrossPrivateLocalProvisioning() async throws {
    let binary = try #require(ProcessInfo.processInfo.environment["MYTERM_ENROLLMENT_RUST_BINARY"])
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
    defer {
        do { try FileManager.default.removeItem(at: temporary) }
        catch { Issue.record("Could not remove temporary enrollment state: \(error)") }
    }
    let authorityDirectory = temporary.appendingPathComponent("authority", isDirectory: true)
    let serverDirectory = temporary.appendingPathComponent("server", isDirectory: true)
    let endpoint = Curve25519.Signing.PrivateKey()
    let holder = Curve25519.Signing.PrivateKey()
    let endpointIdentity = EnrollmentSigningIdentity(endpoint.publicKey)

    let localAuthority = LocalEnrollmentAuthorityClient(executable: URL(fileURLWithPath: binary), stateDirectory: authorityDirectory)
    let binding = try await localAuthority.bootstrap(firstClient: endpoint)
    let authorityIdentity = try binding.verifiedAuthority(pinnedAnchor: binding.anchor)
    let reopened = LocalEnrollmentAuthorityClient(executable: URL(fileURLWithPath: binary), stateDirectory: authorityDirectory)
    #expect(try await reopened.bootstrap(firstClient: endpoint) == binding)
    // An interrupted first run can have the database but no published binding yet.
    try FileManager.default.removeItem(at: authorityDirectory.appendingPathComponent("account.json"))
    #expect(try await reopened.bootstrap(firstClient: endpoint) == binding)
    await #expect(throws: AccountEnrollmentError.wrongAccount) {
        try await reopened.bootstrap(firstClient: Curve25519.Signing.PrivateKey())
    }

    let issue = IssueEnrollmentCredential(account: binding.anchor, creator: endpointIdentity,
                                          holder: EnrollmentSigningIdentity(holder.publicKey), mode: .reusable)
    let issueEnvelope = try SignedAccountEnrollment(issue, signer: endpoint)
    let certificate = try await localAuthority.issue(issueEnvelope)
    let verified = try ServerEnrollmentCredential.verified(certificate, binding: binding, pinnedAnchor: binding.anchor)
    #expect(verified.expiresAt - verified.issuedAt == 30 * 86_400)
    #expect(verified.status(at: verified.expiresAt - 7 * 86_400) == .expiresWithinSevenDays)
    #expect(verified.status(at: verified.expiresAt - 86_400) == .expiresWithinOneDay)
    #expect(verified.status(at: verified.expiresAt) == .expired)
    #expect(throws: AccountEnrollmentError.wrongAccount) {
        try ServerEnrollmentCredential.verified(certificate, binding: binding, pinnedAnchor: String(repeating: "0", count: 64))
    }

    let secretInput = ProvisioningInput(
        binding: binding, pinnedAnchor: binding.anchor, credential: certificate,
        name: "Mac build / Café", holderSeed: base64URL(holder.rawRepresentation)
    )
    let mismatched = ProvisioningInput(binding: binding, pinnedAnchor: String(repeating: "0", count: 64),
                                       credential: certificate, name: secretInput.name, holderSeed: secretInput.holderSeed)
    let rejected = try enrollmentProcess(binary, "prepare-server", serverDirectory, input: mismatched)
    #expect(rejected.status != 0)
    #expect(!FileManager.default.fileExists(atPath: serverDirectory.path))
    let prepared: ProvisioningStatus = try runEnrollment(binary, "prepare-server", serverDirectory, input: secretInput)
    let restarted: ProvisioningStatus = try runEnrollment(binary, "provisioning-status", serverDirectory)
    #expect(prepared == restarted)
    let presentation = try prepared.presentation.verified(binding: binding, pinnedAnchor: binding.anchor)
    #expect(presentation.request.server == prepared.server)
    #expect(presentation.request.name == "Mac build / Café")
    #expect(!presentation.request.relayAccess)
    #expect(prepared.expiryWarning == .active)
    let replacementDirectory = temporary.appendingPathComponent("replacement", isDirectory: true)
    let replacementInput = ProvisioningInput(binding: binding, pinnedAnchor: binding.anchor, credential: certificate,
                                             name: secretInput.name, relayAccess: true, holderSeed: secretInput.holderSeed)
    let replacement: ProvisioningStatus = try runEnrollment(binary, "prepare-server", replacementDirectory, input: replacementInput)
    let replacementRequest = try replacement.presentation.verified(binding: binding, pinnedAnchor: binding.anchor).request
    #expect(replacement.server != prepared.server)
    #expect(replacementRequest.name == presentation.request.name)
    #expect(replacementRequest.relayAccess)

    let receipt = try await localAuthority.redeem(prepared.presentation)
    let event = try receipt.verify(EnrollmentMembershipEvent.self, signer: authorityIdentity)
    #expect(event.account == binding.anchor)
    #expect(event.sequence == 2)
    guard case let .admit(admission) = event.change else {
        Issue.record("Expected a signed server admission")
        return
    }
    #expect(admission.request == presentation.request)
    #expect(admission.confirmedBy == nil)

    let revocation = ManageServerEnrollment(account: binding.anchor, actor: endpointIdentity,
                                            change: .revokeCredential(verified.id))
    let revoked = try await localAuthority.manage(SignedAccountEnrollment(revocation, signer: endpoint))
    #expect(try revoked.verify(EnrollmentMembershipEvent.self, signer: authorityIdentity).change == .revokeCredential(verified.id))
    let retry = try await localAuthority.redeem(prepared.presentation)
    #expect(retry == receipt)
    let membership = try EnrollmentMembershipStore(secrets: EnrollmentTestSecretStore(), binding: binding, pinnedAnchor: binding.anchor)
    try await membership.apply(localAuthority.events(after: 0))
    #expect(await membership.checkpoint.sequence == 3)
    #expect(try await membership.servers().map(\.request) == [presentation.request])

    let database = authorityDirectory.appendingPathComponent("authority/enrollment.sqlite3")
    try FileManager.default.removeItem(at: database)
    await #expect(throws: AccountEnrollmentError.localAuthorityFailed) {
        try await reopened.bootstrap(firstClient: endpoint)
    }
    #expect(!FileManager.default.fileExists(atPath: database.path))
}

private struct ProvisioningInput: Encodable {
    let binding: EnrollmentAccountBinding
    let pinnedAnchor: String
    let credential: SignedAccountEnrollment
    let name: String
    var relayAccess: Bool? = nil
    let holderSeed: String
}

private struct ProvisioningStatus: Decodable, Equatable {
    let server: EnrollmentSigningIdentity
    let expiryWarning: EnrollmentCredentialStatus
    let presentation: ServerEnrollmentPresentation
}

private func runEnrollment<Output: Decodable>(
    _ binary: String, _ operation: String, _ directory: URL, input: (any Encodable)? = nil
) throws -> Output {
    let result = try enrollmentProcess(binary, operation, directory, input: input)
    try #require(result.status == 0)
    return try JSONDecoder().decode(Output.self, from: result.response)
}

private func enrollmentProcess(
    _ binary: String, _ operation: String, _ directory: URL, input: (any Encodable)?
) throws -> (status: Int32, response: Data) {
    let process = Process()
    let request = Pipe()
    let response = Pipe()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = ["enrollment", operation, directory.path]
    process.standardInput = request
    process.standardOutput = response
    try process.run()
    if let input {
        try request.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(input))
    }
    try request.fileHandleForWriting.close()
    let data = response.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, data)
}
#endif

private func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

@Test func enrollmentMembershipRejectsAStaleOrForkedCheckpointAfterRestart() async throws {
    let firstClient = Curve25519.Signing.PrivateKey()
    let authority = Curve25519.Signing.PrivateKey()
    let signer = EnrollmentSigningIdentity(authority.publicKey)
    let genesis = EnrollmentAccountGenesis(firstClient: EnrollmentSigningIdentity(firstClient.publicKey), authority: signer)
    let binding = try EnrollmentAccountGenesis.binding(from: SignedAccountEnrollment(genesis, signer: firstClient))
    let holder = EnrollmentSigningIdentity(Curve25519.Signing.PrivateKey().publicKey)
    let credential = ServerEnrollmentCredential(account: binding.anchor, id: String(repeating: "a", count: 64),
                                               creator: genesis.firstClient, holder: holder, mode: .reusable,
                                               issuedAt: 100, expiresAt: 200)
    let first = EnrollmentMembershipEvent(account: binding.anchor, sequence: 1, previous: binding.anchor, change: .issue(credential))
    let signedFirst = try SignedAccountEnrollment(first, signer: authority)
    let firstDigest = try signedFirst.digest(EnrollmentMembershipEvent.self)
    let second = EnrollmentMembershipEvent(account: binding.anchor, sequence: 2, previous: firstDigest,
                                           change: .revokeCredential(credential.id))
    let signedSecond = try SignedAccountEnrollment(second, signer: authority)
    let store = EnrollmentTestSecretStore()
    let membership = try EnrollmentMembershipStore(secrets: store, binding: binding, pinnedAnchor: binding.anchor)
    try await membership.apply([signedFirst, signedSecond])

    let restarted = try EnrollmentMembershipStore(secrets: store, binding: binding, pinnedAnchor: binding.anchor)
    #expect(await restarted.checkpoint.sequence == 2)
    await #expect(throws: AccountEnrollmentError.invalidCheckpoint) {
        try await restarted.apply([signedFirst])
    }
    let fork = EnrollmentMembershipEvent(account: binding.anchor, sequence: 3, previous: firstDigest,
                                         change: .removeIdentity(holder))
    let signedFork = try SignedAccountEnrollment(fork, signer: authority)
    await #expect(throws: AccountEnrollmentError.invalidCheckpoint) {
        try await restarted.apply([signedFork])
    }
    #expect(await restarted.checkpoint.sequence == 2)
    try await restarted.apply([signedSecond])
}

private final class EnrollmentTestSecretStore: SecretStore, Sendable {
    private let entries = OSAllocatedUnfairLock(initialState: [String: Data]())

    func read(account: String) throws -> Data? { entries.withLock { $0[account] } }
    func write(_ data: Data, account: String) throws { entries.withLock { $0[account] = data } }
    func delete(account: String) throws { entries.withLock { $0[account] = nil } }
}

@Test func enrollmentRevocationReconcilesProvisionalAndCanonicalServersAcrossRestart() async throws {
    let firstClient = Curve25519.Signing.PrivateKey()
    let authority = Curve25519.Signing.PrivateKey()
    let holder = Curve25519.Signing.PrivateKey()
    let genesis = EnrollmentAccountGenesis(firstClient: EnrollmentSigningIdentity(firstClient.publicKey),
                                           authority: EnrollmentSigningIdentity(authority.publicKey))
    let binding = try EnrollmentAccountGenesis.binding(from: SignedAccountEnrollment(genesis, signer: firstClient))
    let credential = ServerEnrollmentCredential(account: binding.anchor, id: String(repeating: "b", count: 64),
                                                creator: genesis.firstClient, holder: EnrollmentSigningIdentity(holder.publicKey),
                                                mode: .reusable, issuedAt: 100, expiresAt: 200)
    let certificate = try SignedAccountEnrollment(credential, signer: authority)
    func prepare() throws -> ServerEnrollmentPresentation {
        let server = Curve25519.Signing.PrivateKey()
        let enrollment = ServerEnrollmentRequest(account: binding.anchor, credential: credential.id,
                                                 server: EnrollmentSigningIdentity(server.publicKey), name: "Build Mac",
                                                 relayAccess: false)
        let request = try SignedAccountEnrollment(enrollment, signer: server)
        let proof = try EnrollmentHolderProof(enrollmentDigest: request.digest(ServerEnrollmentRequest.self))
        return try ServerEnrollmentPresentation(credential: certificate, request: request,
                                                possession: SignedAccountEnrollment(proof, signer: holder))
    }
    func event(_ sequence: Int64, after previous: SignedAccountEnrollment?, _ change: EnrollmentMembershipChange) throws -> SignedAccountEnrollment {
        let digest = try previous?.digest(EnrollmentMembershipEvent.self) ?? binding.anchor
        return try SignedAccountEnrollment(EnrollmentMembershipEvent(account: binding.anchor, sequence: sequence,
                                                                     previous: digest, change: change), signer: authority)
    }
    let store = EnrollmentTestSecretStore()
    let membership = try EnrollmentMembershipStore(secrets: store, binding: binding, pinnedAnchor: binding.anchor)
    let stale = try EnrollmentMembershipStore(secrets: store, binding: binding, pinnedAnchor: binding.anchor)
    let canonical = try prepare()
    let provisional = try prepare()
    let late = try prepare()
    let canonicalRequest = try ServerEnrollmentRequest.verified(canonical.request, pinnedAnchor: binding.anchor)
    let issue = try event(1, after: nil, .issue(credential))
    let confirmation = try event(2, after: issue, .admit(ServerEnrollmentAdmission(
        request: canonicalRequest, enrollmentDigest: canonical.request.digest(ServerEnrollmentRequest.self), confirmedBy: nil
    )))
    #expect(try await membership.observe(provisional, at: 150).membership == .provisional)
    #expect(try await membership.observe(canonical, at: 151).membership == .provisional)
    try await membership.apply([issue, confirmation])
    await #expect(throws: AccountEnrollmentError.invalidCheckpoint) {
        try await stale.apply([issue])
    }

    let restarted = try EnrollmentMembershipStore(secrets: store, binding: binding, pinnedAnchor: binding.anchor)
    #expect(try await restarted.observe(provisional, at: 201).membership == .provisional)
    await #expect(throws: AccountEnrollmentError.freshApprovalRequired) {
        try await restarted.observe(late, at: 152)
    }
    await #expect(throws: AccountEnrollmentError.invalidCheckpoint) {
        try await membership.observe(provisional, at: 202)
    }
    let revocation = try event(3, after: confirmation, .revokeCredential(credential.id))
    try await restarted.apply([revocation])
    #expect(try await restarted.observe(canonical, at: 203).membership == .canonical)
    #expect(try await restarted.observe(provisional, at: 204).membership == .freshApprovalRequired)
    let request = try ServerEnrollmentRequest.verified(provisional.request, pinnedAnchor: binding.anchor)
    let approval = try event(4, after: revocation, .admit(ServerEnrollmentAdmission(
        request: request, enrollmentDigest: provisional.request.digest(ServerEnrollmentRequest.self), confirmedBy: genesis.firstClient
    )))
    try await restarted.apply([approval])
    #expect(try await restarted.observe(provisional, at: 205).membership == .canonical)
    let removal = try event(5, after: approval, .removeIdentity(request.server))
    try await restarted.apply([removal])
    await #expect(throws: AccountEnrollmentError.identityRemoved) {
        try await restarted.observe(provisional, at: 206)
    }
    #expect(try await restarted.servers().map(\.request.server) == [canonicalRequest.server])
}
