import Darwin
import Foundation

/// Native pages execute on the companion. Only public destinations may receive their traffic;
/// private networks and local files require the Mac-rendered browser or a scoped artifact grant.
struct NativeBrowserDestinationPolicy: Sendable {
    enum Rejection: Error { case invalidHost, resolutionFailed, prohibitedAddress }
    typealias Lookup = @Sendable (String) async throws -> [String]
    private let lookup: Lookup
    private let interfaces: @Sendable () throws -> [String]
    private final class LookupGate: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = 0
        func acquire() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard pending < 32 else { return false }
            pending += 1
            return true
        }
        func release() { lock.lock(); pending -= 1; lock.unlock() }
    }
    private static let lookupGate = LookupGate()
    private static let lookupQueue = DispatchQueue(label: "com.gordonbeeming.myterm.native-browser-dns")

    init(lookup: @escaping Lookup = Self.lookupHost,
         interfaces: @escaping @Sendable () throws -> [String] = Self.interfaceAddresses) {
        self.lookup = lookup
        self.interfaces = interfaces
    }

    func resolve(host: String, port: UInt16) async throws -> (String, UInt16) {
        guard port > 0, !host.isEmpty, host.utf8.count <= 253,
              !host.contains("%"), !host.contains("\0") else { throw Rejection.invalidHost }
        let answers = try await lookup(host)
        try Task.checkCancellation()
        guard !answers.isEmpty, answers.count <= 64 else { throw Rejection.resolutionFailed }
        let local = Set(try interfaces().compactMap(Self.addressBytes))
        // Reject mixed answers too: selecting a public answer from a private/public set makes
        // policy depend on resolver ordering and permits rebinding during subsequent connects.
        for address in answers {
            guard Self.isPublic(address), let bytes = Self.addressBytes(address), !local.contains(bytes) else {
                throw Rejection.prohibitedAddress
            }
        }
        // Returning the numeric address pins this socket to the answer that was checked.
        // NWConnection must never receive the original hostname for a second DNS lookup.
        return (answers[0], port)
    }

    static func isPublic(_ text: String) -> Bool {
        guard let bytes = addressBytes(text) else { return false }
        if bytes.count == 4 {
            let a = bytes[0], b = bytes[1], c = bytes[2]
            if a == 0 || a == 10 || a == 127 || a >= 224 { return false }
            if a == 100 && (64...127).contains(b) { return false }
            if a == 169 && b == 254 { return false }
            if a == 172 && (16...31).contains(b) { return false }
            if a == 192 && ((b == 0 && c == 0) || (b == 0 && c == 2) || (b == 88 && c == 99) || b == 168) { return false }
            if a == 198 && ((18...19).contains(b) || (b == 51 && c == 100)) { return false }
            if a == 203 && b == 0 && c == 113 { return false }
            return true
        }
        guard bytes.count == 16, bytes[0] & 0xe0 == 0x20 else { return false }
        if bytes[0] == 0x20 && bytes[1] == 0x01 {
            if bytes[2] <= 1 { return false }
            if bytes[2] == 0x0d && bytes[3] == 0xb8 { return false }
        }
        if bytes[0] == 0x20 && bytes[1] == 0x02 { return false }
        if bytes[0] == 0x3f && bytes[1] == 0xfe { return false }
        if bytes[0] == 0x3f && bytes[1] == 0xff && bytes[2] & 0xf0 == 0 { return false }
        return true
    }

    private static func addressBytes(_ text: String) -> Data? {
        guard !text.contains("%") else { return nil }
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 { return withUnsafeBytes(of: v4) { Data($0) } }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, text, &v6) == 1 { return withUnsafeBytes(of: v6) { Data($0) } }
        return nil
    }

    private static func lookupHost(_ host: String) async throws -> [String] {
        // libc DNS cannot be cancelled once started. Keep timed-out queued/running lookups
        // counted until they finish so repeated socket retries cannot grow this queue.
        guard lookupGate.acquire() else { throw Rejection.resolutionFailed }
        return try await withCheckedThrowingContinuation { continuation in
            lookupQueue.async {
                defer { lookupGate.release() }
                var hints = addrinfo()
                hints.ai_flags = AI_ADDRCONFIG
                hints.ai_family = AF_UNSPEC
                hints.ai_socktype = SOCK_STREAM
                var result: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
                    continuation.resume(throwing: Rejection.resolutionFailed)
                    return
                }
                defer { freeaddrinfo(first) }
                var answers: [String] = []
                var current: UnsafeMutablePointer<addrinfo>? = first
                while let entry = current {
                    if let address = entry.pointee.ai_addr, let numeric = numericAddress(address, length: entry.pointee.ai_addrlen), !answers.contains(numeric) {
                        answers.append(numeric)
                    }
                    guard answers.count <= 64 else {
                        continuation.resume(throwing: Rejection.resolutionFailed)
                        return
                    }
                    current = entry.pointee.ai_next
                }
                continuation.resume(returning: answers)
            }
        }
    }

    private static func numericAddress(_ address: UnsafePointer<sockaddr>, length: socklen_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func interfaceAddresses() throws -> [String] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { throw Rejection.resolutionFailed }
        defer { freeifaddrs(first) }
        var current: UnsafeMutablePointer<ifaddrs>? = first
        var addresses: [String] = []
        while let entry = current {
            if let address = entry.pointee.ifa_addr,
               address.pointee.sa_family == UInt8(AF_INET) || address.pointee.sa_family == UInt8(AF_INET6),
               let numeric = numericAddress(address, length: socklen_t(address.pointee.sa_len)) {
                addresses.append(numeric.components(separatedBy: "%")[0])
            }
            current = entry.pointee.ifa_next
        }
        return addresses
    }
}
