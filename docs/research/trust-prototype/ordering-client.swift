// Throwaway native client for signed removal requests and receipt verification.
import CryptoKit
import Foundation

enum ClientError: Error { case malformedInput }
func encodeHex(_ bytes: some Sequence<UInt8>) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}
func decodeHex(_ text: String) throws -> Data {
    let bytes = Array(text.utf8)
    guard bytes.count % 2 == 0, bytes.count <= 32768 else { throw ClientError.malformedInput }
    func digit(_ c: UInt8) throws -> UInt8 {
        if c >= 48 && c <= 57 { return c - 48 }
        if c >= 97 && c <= 102 { return c - 87 }
        throw ClientError.malformedInput
    }
    return try Data(stride(from: 0, to: bytes.count, by: 2).map {
        try (digit(bytes[$0]) << 4) | digit(bytes[$0 + 1])
    })
}
func emit(_ line: String) {
    print(line)
    fflush(stdout)
}
do {
    let key = Curve25519.Signing.PrivateKey()
    emit("KEY|" + encodeHex(key.publicKey.rawRepresentation))
    while let line = readLine() {
        guard line.utf8.count <= 32768, line.utf8.allSatisfy({ $0 > 0 && $0 < 128 }) else {
            throw ClientError.malformedInput
        }
        let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 2 && parts[0] == "SIGN" {
            emit("SIGNATURE|" + encodeHex(try key.signature(for: decodeHex(parts[1]))))
        } else if parts.count == 4 && parts[0] == "VERIFY" {
            let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: decodeHex(parts[1]))
            let message = try decodeHex(parts[2])
            let signature = try decodeHex(parts[3])
            let valid = publicKey.isValidSignature(signature, for: message)
            emit(valid ? "VALID" : "INVALID")
        } else {
            throw ClientError.malformedInput
        }
    }
} catch {
    emit("ERROR|malformed-input")
    exit(1)
}
