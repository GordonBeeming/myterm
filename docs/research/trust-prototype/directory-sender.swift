// Native CryptoKit sender; signing/admission and authenticated key-purpose bindings are separate work.
import CryptoKit
import Foundation
enum DirectoryError: Error { case input, state }
func hex(_ bytes: some Sequence<UInt8>) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
func unhex(_ text: String) throws -> Data {
    let b = Array(text.utf8)
    guard b.count % 2 == 0, b.count <= 8192 else { throw DirectoryError.input }
    func digit(_ c: UInt8) throws -> UInt8 {
        if c >= 48 && c <= 57 { return c-48 }
        if c >= 97 && c <= 102 { return c-87 }
        throw DirectoryError.input
    }
    return try Data(stride(from: 0, to: b.count, by: 2).map { try (digit(b[$0]) << 4) | digit(b[$0+1]) })
}
func emit(_ text: String) { print(text); fflush(stdout) }
do {
    let identity = P256.KeyAgreement.PrivateKey()
    emit("SENDER|" + hex(identity.publicKey.x963Representation))
    var key: SymmetricKey?
    var context = Data()
    var epoch: UInt64 = 0
    while let line = readLine() {
        guard line.utf8.count <= 16384 else { throw DirectoryError.input }
        let p = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        if p.count == 5 && p[0] == "EPOCH", let next = UInt64(p[1]), next > epoch {
            let account = try unhex(p[2]), checkpoint = try unhex(p[3])
            guard account.count == 32, checkpoint.count == 32 else { throw DirectoryError.input }
            let plaintext = try unhex(p[4])
            guard plaintext.count <= 2048 else { throw DirectoryError.input }
            let fresh = SymmetricKey(size: .bits256)
            context = Data("D0|\(p[2])|\(next)|\(p[3])".utf8)
            let snapshot = try AES.GCM.seal(plaintext, using: fresh, authenticating: context)
            guard let combined = snapshot.combined else { throw DirectoryError.state }
            let digest = fresh.withUnsafeBytes { hex(SHA256.hash(data: Data($0))) }
            key = fresh; epoch = next
            emit("EPOCH|\(hex(context))|\(hex(combined))|\(digest)")
        } else if p.count == 2 && p[0] == "ENVELOPE", let key {
            let recipient = try P256.KeyAgreement.PublicKey(x963Representation: unhex(p[1]))
            var info = context; info.append(Data(("|" + p[1]).utf8))
            var sender = try HPKE.Sender(recipientKey: recipient, ciphersuite: .P256_SHA256_AES_GCM_256,
                                         info: info, authenticatedBy: identity)
            let secret = key.withUnsafeBytes { Data($0) }
            let wrapped = try sender.seal(secret, authenticating: info)
            emit("ENVELOPE|\(hex(sender.encapsulatedKey))|\(hex(wrapped))")
        } else if p.count == 1 && p[0] == "QUIT" { break
        } else { throw DirectoryError.input }
    }
} catch { emit("ERROR|directory-sender"); exit(1) }
