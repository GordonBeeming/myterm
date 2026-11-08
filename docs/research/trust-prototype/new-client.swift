// Throwaway native Apple endpoint. Secrets travel through stdin, never argv or stdout.
import Foundation

func input() throws -> String {
    guard let line = readLine(strippingNewline: true), line.utf8.count <= 8192,
          line.utf8.allSatisfy({ $0 > 0 && $0 < 128 }) else {
        throw ProbeError.invalidInput
    }
    return line
}
enum ProbeError: Error { case invalidInput, handshake }
func emit(_ text: String) {
    print(text)
    fflush(stdout)
}

do {
    let code = try input()
    let binding = try input()
    var message = [CChar](repeating: 0, count: 1024)
    guard let context = mt_start(0, code, binding, &message, message.count) else {
        throw ProbeError.handshake
    }
    defer { mt_free(context) }
    emit(String(cString: message))
    let peerMessage = try input()
    var proof = [CChar](repeating: 0, count: 1024)
    guard mt_finish(context, peerMessage, &proof, proof.count) == 1 else {
        throw ProbeError.handshake
    }
    emit(String(cString: proof))
    emit(mt_verify(context, try input()) == 1 ? "PEER_VERIFIED" : "REJECT")
} catch {
    emit("REJECT")
    exit(1)
}
