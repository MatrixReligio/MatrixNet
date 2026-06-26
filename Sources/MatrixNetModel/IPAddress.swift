import Darwin
import Foundation

/// An IP address, either IPv4 or IPv6.
///
/// Parsing and formatting delegate to the system's `inet_pton`/`inet_ntop`, which
/// implement the canonical text representations (RFC 5952 zero-compression for
/// IPv6) and reject malformed input. The value is stored as a packed integer in
/// big-endian (network) order so that two equal addresses always compare and
/// hash identically regardless of how they were created.
public enum IPAddress: Hashable, Sendable {
    /// An IPv4 address packed big-endian into a single 32-bit value.
    case v4(UInt32)
    /// An IPv6 address stored as the high and low 64-bit halves, big-endian.
    case v6(high: UInt64, low: UInt64)

    /// Parses a textual IPv4 or IPv6 address. Returns `nil` for malformed input.
    ///
    /// IPv4 is attempted first, then IPv6, so unambiguous text maps to the
    /// expected family. Leading/trailing whitespace and out-of-range octets are
    /// rejected by `inet_pton`.
    public init?(_ string: String) {
        var v4Bytes = [UInt8](repeating: 0, count: 4)
        if inet_pton(AF_INET, string, &v4Bytes) == 1 {
            self = .v4(Self.packV4(v4Bytes))
            return
        }
        var v6Bytes = [UInt8](repeating: 0, count: 16)
        if inet_pton(AF_INET6, string, &v6Bytes) == 1 {
            let (high, low) = Self.packV6(v6Bytes)
            self = .v6(high: high, low: low)
            return
        }
        return nil
    }

    /// Builds an address from raw network-order bytes (4 for IPv4, 16 for IPv6).
    public init?(bytes: [UInt8]) {
        switch bytes.count {
        case 4:
            self = .v4(Self.packV4(bytes))
        case 16:
            let (high, low) = Self.packV6(bytes)
            self = .v6(high: high, low: low)
        default:
            return nil
        }
    }

    /// The address as raw network-order bytes (4 for IPv4, 16 for IPv6).
    public var bytes: [UInt8] {
        switch self {
        case let .v4(value):
            return (0 ..< 4).map { UInt8(truncatingIfNeeded: value >> UInt32((3 - $0) * 8)) }
        case let .v6(high, low):
            let highBytes = (0 ..< 8).map { UInt8(truncatingIfNeeded: high >> UInt64((7 - $0) * 8)) }
            let lowBytes = (0 ..< 8).map { UInt8(truncatingIfNeeded: low >> UInt64((7 - $0) * 8)) }
            return highBytes + lowBytes
        }
    }

    /// Whether this is an IPv6 address.
    public var isIPv6: Bool {
        if case .v6 = self { return true }
        return false
    }

    private static func packV4(_ bytes: [UInt8]) -> UInt32 {
        var value: UInt32 = 0
        for byte in bytes {
            value = (value << 8) | UInt32(byte)
        }
        return value
    }

    private static func packV6(_ bytes: [UInt8]) -> (high: UInt64, low: UInt64) {
        var high: UInt64 = 0
        var low: UInt64 = 0
        for byte in bytes[0 ..< 8] {
            high = (high << 8) | UInt64(byte)
        }
        for byte in bytes[8 ..< 16] {
            low = (low << 8) | UInt64(byte)
        }
        return (high, low)
    }
}

extension IPAddress: CustomStringConvertible {
    public var description: String {
        let family = isIPv6 ? AF_INET6 : AF_INET
        var rawBytes = bytes
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(family, &rawBytes, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else {
            // Unreachable for an internally valid address; surface a visible
            // sentinel rather than silently corrupting logs/UI/pcapng output.
            return "<invalid-address>"
        }
        let utf8 = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(bytes: utf8, encoding: .utf8) ?? "<invalid-address>"
    }
}
