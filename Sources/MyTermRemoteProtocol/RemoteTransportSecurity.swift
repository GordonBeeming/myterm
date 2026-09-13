import CryptoKit
import Foundation
import Network

/// Builds the TLS parameters both ends of a MyTerm Remote connection use.
///
/// The connection is authenticated and encrypted with a pre-shared key derived from the pairing
/// token, so a device that does not hold the token cannot complete a handshake, and nothing on the
/// network can read terminal bytes. A pre-shared key avoids shipping a certificate authority into
/// the app for what is a two-party link between devices the same person owns.
public enum RemoteTransportSecurity {
    /// Separates this key from any other use of the same token.
    private static let keyContext = Data("myterm-remote-psk-v1".utf8)
    private static let identity = Data("myterm-remote".utf8)
    /// TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256 (RFC 7905). Not among the named cases of
    /// `tls_ciphersuite_t`, but the stack negotiates it, and it is the one that pairs an
    /// ephemeral key exchange with the pre-shared key.
    public static let ecdhePreSharedKeySuite = tls_ciphersuite_t(rawValue: 0xCCAC)!

    public static func parameters(token: String) -> NWParameters {
        let options = NWProtocolTLS.Options()
        let key = derivedKey(token: token)

        key.withUnsafeBytes { keyBytes in
            identity.withUnsafeBytes { identityBytes in
                sec_protocol_options_add_pre_shared_key(
                    options.securityProtocolOptions,
                    DispatchData(bytes: keyBytes) as __DispatchData,
                    DispatchData(bytes: identityBytes) as __DispatchData
                )
            }
        }
        // The platform does not do TLS 1.3 with an external pre-shared key, so the handshake is
        // TLS 1.2. Its default PSK suites carry no key exchange of their own: anyone who recorded
        // the ciphertext (the relay forwards every byte) and later learned the token could read
        // every past session. This suite runs an ephemeral ECDH under the same key, so a session
        // stays unreadable after the token is known, and the key is still the authentication.
        sec_protocol_options_append_tls_ciphersuite(
            options.securityProtocolOptions,
            ecdhePreSharedKeySuite
        )
        sec_protocol_options_set_min_tls_protocol_version(
            options.securityProtocolOptions,
            .TLSv12
        )

        let parameters = NWParameters(tls: options)
        // A terminal is interactive. Coalescing keystrokes to fill a packet is the wrong trade.
        parameters.serviceClass = .responsiveData
        if let tcp = parameters.defaultProtocolStack.internetProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 30
        }
        return parameters
    }

    static func derivedKey(token: String) -> Data {
        var hasher = SHA256()
        hasher.update(data: keyContext)
        hasher.update(data: Data(token.utf8))
        return Data(hasher.finalize())
    }

    /// A fresh pairing token. 32 hexadecimal characters carry 128 bits.
    public static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
