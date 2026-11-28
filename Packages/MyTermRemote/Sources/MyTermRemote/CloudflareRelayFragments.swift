import Foundation

/// Large native packets remain a single authenticated application message. The relay sees only
/// opaque fragments, and a receiver holds at most two maximum-size packets across all peers.
struct CloudflareRelayFragments {
    static let maximumPacketBytes = RelayFrame.maximumBytes - RelayFrame.headerBytes
    private static let first: UInt8 = 0xf0
    private static let next: UInt8 = 0xf1
    private static let maximumChunkBytes = CloudflareCompanionTransport.maximumPayloadBytes - 5

    private struct Partial {
        let length: Int
        var received: Data
        var expires: ContinuousClock.Instant
    }

    private var partials: [UUID: Partial] = [:]

    static func split(_ packet: Data) throws -> [Data] {
        guard !packet.isEmpty, packet.count <= maximumPacketBytes else { throw RemoteError.messageTooLarge }
        if packet.count <= CloudflareCompanionTransport.maximumPayloadBytes { return [packet] }
        return stride(from: 0, to: packet.count, by: maximumChunkBytes).map { offset in
            let end = min(offset + maximumChunkBytes, packet.count)
            var frame = Data([offset == 0 ? first : next])
            if offset == 0 {
                var length = UInt32(packet.count).bigEndian
                withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
            }
            frame.append(packet.dropFirst(offset).prefix(end - offset))
            return frame
        }
    }

    mutating func receive(_ frame: Data, from peer: UUID, now: ContinuousClock.Instant = .now) -> Data? {
        partials = partials.filter { $0.value.expires > now }
        guard let marker = frame.first else { return nil }
        if marker == Self.first {
            partials.removeValue(forKey: peer)
            guard frame.count == Self.maximumChunkBytes + 5 else { return nil }
            let length = frame.dropFirst().prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            let reserved = partials.values.reduce(0) { $0 + $1.length }
            guard length > CloudflareCompanionTransport.maximumPayloadBytes, length <= Self.maximumPacketBytes,
                  length + reserved <= 2 * Self.maximumPacketBytes else { return nil }
            partials[peer] = Partial(length: length, received: Data(frame.dropFirst(5)),
                                     expires: now.advanced(by: .seconds(5)))
            return nil
        }
        guard marker == Self.next else {
            partials.removeValue(forKey: peer)
            return frame
        }
        guard var partial = partials.removeValue(forKey: peer) else { return nil }
        let expected = min(Self.maximumChunkBytes, partial.length - partial.received.count)
        guard frame.count == expected + 1 else { return nil }
        partial.received.append(frame.dropFirst())
        if partial.received.count == partial.length { return partial.received }
        partial.expires = now.advanced(by: .seconds(5))
        partials[peer] = partial
        return nil
    }

    mutating func discard(peer: UUID) { partials.removeValue(forKey: peer) }
}
