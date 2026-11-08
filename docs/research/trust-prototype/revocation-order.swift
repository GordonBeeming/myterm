// Throwaway counterexample: authentic signatures do not prove issuance before revocation.
// Private identity keys are disposable fixtures, generated and kept only in this process.
import CryptoKit
import Foundation

struct Removal: Codable {
    let domain: String
    let account: String
    let issuer: String
    let target: String
    let parents: [String]
    let operation: String
}
struct Check: Codable {
    let name: String
    let passed: Bool
}
struct Report: Codable {
    let generatedAt: String
    let prototype: String
    let accountAnchor: String
    let commonCheckpoint: String
    let publicKeyA: String
    let publicKeyB: String
    let aRemovesBPayload: String
    let bRemovesAPayload: String
    let aSignature: String
    let bSignature: String
    let genuineConcurrentHistory: [String]
    let forgedAfterRemovalHistory: [String]
    let sameSignedBytes: Bool
    let checks: [Check]
    let limitations: [String]
}
enum ProbeError: Error { case invalidEncoding, checkFailed, signingFailed }
func hex(_ data: some Sequence<UInt8>) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}
func canonical<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}
func sign(_ key: Curve25519.Signing.PrivateKey, _ message: Data) throws -> Data {
    let seed = key.rawRepresentation
    var signature = [UInt8](repeating: 0, count: 64)
    let ok = seed.withUnsafeBytes { seedBytes in
        message.withUnsafeBytes { messageBytes in
            mt_sign_removal(seedBytes.bindMemory(to: UInt8.self).baseAddress, seed.count,
                messageBytes.bindMemory(to: UInt8.self).baseAddress, message.count,
                &signature, signature.count)
        }
    }
    guard ok == 1 else { throw ProbeError.signingFailed }
    return Data(signature)
}

do {
    let a = Curve25519.Signing.PrivateKey()
    let b = Curve25519.Signing.PrivateKey()
    let aPublic = hex(a.publicKey.rawRepresentation)
    let bPublic = hex(b.publicKey.rawRepresentation)
    let anchor = hex(SHA256.hash(data: try canonical([
        "domain": "myterm-prototype-account-v0", "firstClient": aPublic
    ])))
    // Both possible worlds start from the same already verified A/B membership.
    // This fixture is not an implementation of genesis or account enrollment.
    let checkpoint = hex(SHA256.hash(data: try canonical([
        "domain": "myterm-prototype-checkpoint-v0", "account": anchor,
        "members": [aPublic, bPublic].sorted().joined(separator: ",")
    ])))
    let aPayload = try canonical(Removal(domain: "myterm-prototype-removal-v0", account: anchor,
        issuer: aPublic, target: bPublic, parents: [checkpoint], operation: UUID().uuidString))
    let bPayload = try canonical(Removal(domain: "myterm-prototype-removal-v0", account: anchor,
        issuer: bPublic, target: aPublic, parents: [checkpoint], operation: UUID().uuidString))

    // World one: B signs its removal before A signs; both reference their common history.
    let concurrentB = try sign(b, bPayload)
    let concurrentA = try sign(a, aPayload)
    // World two: A removes B first. A removed/compromised B retains its own identity key
    // and can sign the same message against the old checkpoint afterward.
    let firstA = try sign(a, aPayload)
    let forgedLaterB = try sign(b, bPayload)
    let sameSignedBytes = concurrentA == firstA && concurrentB == forgedLaterB
    var changedPayload = bPayload
    changedPayload.append(0)
    let checks = [
        Check(name: "A removal verifies against A's known identity", passed: a.publicKey.isValidSignature(firstA, for: aPayload)),
        Check(name: "Concurrent B removal verifies", passed: b.publicKey.isValidSignature(concurrentB, for: bPayload)),
        Check(name: "Later B removal also verifies", passed: b.publicKey.isValidSignature(forgedLaterB, for: bPayload)),
        Check(name: "B cannot substitute A's signing identity", passed: !a.publicKey.isValidSignature(forgedLaterB, for: bPayload)),
        Check(name: "Modified signed removal is rejected", passed: !b.publicKey.isValidSignature(forgedLaterB, for: changedPayload)),
        Check(name: "Both signing orders produce the same A signature", passed: concurrentA == firstA),
        Check(name: "Both signing orders produce the same B signature", passed: concurrentB == forgedLaterB)
    ]
    guard let aText = String(data: aPayload, encoding: .utf8),
          let bText = String(data: bPayload, encoding: .utf8) else { throw ProbeError.invalidEncoding }
    let report = Report(generatedAt: ISO8601DateFormatter().string(from: Date()),
        prototype: "BoringSSL Ed25519 signer and native CryptoKit verifier; signed-history counterexample, not a membership implementation",
        accountAnchor: anchor, commonCheckpoint: checkpoint, publicKeyA: aPublic, publicKeyB: bPublic,
        aRemovesBPayload: aText, bRemovesAPayload: bText,
        aSignature: hex(firstA), bSignature: hex(forgedLaterB),
        genuineConcurrentHistory: ["B signs remove A from common checkpoint", "A signs remove B from common checkpoint", "A receives B's removal"],
        forgedAfterRemovalHistory: ["A signs remove B from common checkpoint", "Removed B signs remove A against old common checkpoint", "A receives B's removal"],
        sameSignedBytes: sameSignedBytes, checks: checks,
        limitations: [
            "Assumes B retains its private key and can choose old causal parents; local signing hardware with trusted anti-rollback state is not assumed",
            "No trusted ordering service, quorum, external witness or proof of irreversible key deletion",
            "The initial verified membership checkpoint is a fixture, not implemented admission",
            "No receiving membership state machine is executed; acceptance and two-endpoint lockout are consequences reasoned from the agreed policy",
            "B must reach a receiver that honors concurrent mutual removals instead of rejecting every event from a locally removed issuer",
            "No per-author sequence/self-parent chain is modeled; such chains can expose some equivocations but do not supply independent issuance-time evidence for an unseen branch",
            "Shows a limitation of this signed-history candidate, not an impossibility claim about every protocol",
            "No relay, terminal, TLS connection or directory encryption is exercised"
        ])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    FileHandle.standardOutput.write(try encoder.encode(report))
    FileHandle.standardOutput.write(Data([10]))
    if checks.contains(where: { !$0.passed }) || !sameSignedBytes { throw ProbeError.checkFailed }
} catch {
    FileHandle.standardError.write(Data("Revocation-order probe failed: \(error)\n".utf8))
    exit(1)
}
