// Throwaway native client; BoringSSL carries TLS records over a fixture byte relay.
import CryptoKit
import Foundation

enum ChannelError: Error { case input, identity }
func hex(_ bytes: some Sequence<UInt8>) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
func unhex(_ text: String) throws -> Data {
    let bytes = Array(text.utf8)
    guard bytes.count % 2 == 0, bytes.count <= 1048576 else { throw ChannelError.input }
    func digit(_ c: UInt8) throws -> UInt8 {
        if c >= 48 && c <= 57 { return c - 48 }
        if c >= 97 && c <= 102 { return c - 87 }
        throw ChannelError.input
    }
    return try Data(stride(from: 0, to: bytes.count, by: 2).map { try (digit(bytes[$0]) << 4) | digit(bytes[$0+1]) })
}
func emit(_ text: String) { print(text); fflush(stdout) }
func frame(_ tls: OpaquePointer, _ input: Data) -> String {
    var cipher = [UInt8](repeating: 0, count: 131072)
    var plain = [UInt8](repeating: 0, count: 131072)
    var cipherLen = 0, plainLen = 0
    let valid = input.withUnsafeBytes {
        mt_tls_pump(tls, $0.bindMemory(to: UInt8.self).baseAddress, input.count,
                    &cipher, cipher.count, &cipherLen, &plain, plain.count, &plainLen)
    }
    guard valid == 1 else {
        return "FAILED|" + (mt_tls_last_error().map { String(cString: $0) } ?? "unknown")
    }
    let open = mt_tls_open(tls) == 1
    var fingerprint = [UInt8](repeating: 0, count: 32)
    if open && mt_tls_fingerprint(tls, &fingerprint, fingerprint.count) != 1 { return "FAILED" }
    return "FRAME|\(hex(cipher.prefix(cipherLen)))|\(hex(plain.prefix(plainLen)))|\(open ? 1 : 0)|\(open ? hex(fingerprint) : "")"
}
do {
    let identity = Curve25519.Signing.PrivateKey()
    emit("KEY|" + hex(identity.publicKey.rawRepresentation))
    var tls: OpaquePointer?
    defer { if let tls { mt_tls_free(tls) } }
    while let line = readLine() {
        guard line.utf8.count <= 1048576 else { throw ChannelError.input }
        let p = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        var reply: String
        if p.count == 2 && p[0] == "START" {
            if let old = tls { mt_tls_free(old); tls = nil }
            let peer = try unhex(p[1]), seed = identity.rawRepresentation
            tls = seed.withUnsafeBytes { secret in
                peer.withUnsafeBytes { pin in
                    mt_tls_new(0, secret.bindMemory(to: UInt8.self).baseAddress, seed.count,
                               pin.bindMemory(to: UInt8.self).baseAddress, peer.count)
                }
            }
            guard let tls else { throw ChannelError.identity }
            reply = frame(tls, Data())
        } else if p.count == 2 && p[0] == "PUMP", let tls {
            reply = frame(tls, try unhex(p[1]))
        } else if p.count == 2 && p[0] == "WRITE", let tls {
            let bytes = try unhex(p[1])
            let valid = bytes.withUnsafeBytes { mt_tls_write(tls, $0.bindMemory(to: UInt8.self).baseAddress, bytes.count) }
            reply = valid == 1 ? frame(tls, Data()) : "FAILED"
        } else if p.count == 1 && p[0] == "UPDATE", let tls {
            reply = mt_tls_update(tls) == 1 ? "UPDATED" : "FAILED"
        } else if p.count == 1 && p[0] == "STATS", let tls {
            reply = "STATS|\(mt_tls_updates_sent(tls))|\(mt_tls_updates_received(tls))"
        } else if ["PUMP", "WRITE", "UPDATE", "STATS"].contains(p[0]), tls == nil {
            reply = "FAILED|no-channel"
        } else if p.count == 1 && p[0] == "QUIT" { break
        } else { throw ChannelError.input }
        if reply.hasPrefix("FAILED"), let old = tls { mt_tls_free(old); tls = nil }
        emit(reply)
    }
} catch {
    emit("ERROR|channel-client")
    exit(1)
}
