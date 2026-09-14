import Darwin
import Foundation
import MyTermRemoteProtocol

/// The Mac's address on the local network, as a device on the same Wi-Fi reaches it.
///
/// A device cannot use `localhost`, so pairing has to show a real address. Loopback and interfaces
/// that are down are never candidates, and `en0` wins when several interfaces are up, because that
/// is the Wi-Fi the paired device is almost certainly on.
enum LocalNetworkAddress {
    static func current() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var candidates: [(interface: String, address: String)] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let resolved = getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard resolved == 0 else { continue }
            candidates.append((text(entry.pointee.ifa_name), text(host)))
        }

        return candidates.first { $0.interface == "en0" }?.address ?? candidates.first?.address
    }

    /// Reads a C string up to its terminator. The `String(cString:)` overloads are deprecated, and
    /// both an array buffer and a pointer arrive here.
    private static func text(_ characters: [CChar]) -> String {
        String(decoding: characters.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func text(_ pointer: UnsafeMutablePointer<CChar>) -> String {
        var bytes: [UInt8] = []
        var cursor = pointer
        while cursor.pointee != 0 {
            bytes.append(UInt8(bitPattern: cursor.pointee))
            cursor += 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The URL a device opens to connect. `ConnectionView` on the device parses exactly this shape,
    /// and iOS's own Camera app opens it, so a scanned code needs no scanner inside the app.
    static func connectURL(
        host: String,
        port: UInt16,
        token: String,
        serviceName: String?,
        relay: RelayEndpoint? = nil
    ) -> URL? {
        PairingLink(host: host, port: port, token: token, serviceName: serviceName, relay: relay).url
    }
}
