import Darwin
import MatrixNetModel

/// Parses BSD `sockaddr` blobs (as delivered by NetworkStatistics description
/// dictionaries) into normalised `Endpoint`s.
///
/// The observed layout on macOS is `sockaddr_in` (16 bytes, family `AF_INET`)
/// or `sockaddr_in6` (28 bytes, family `AF_INET6`):
/// `[sa_len][sa_family][port BE][...address...]`. IPv4-mapped IPv6 addresses are
/// normalised to plain IPv4 so they correlate with PKTAP's IPv4 view.
public enum SocketAddress {
    /// Parses a sockaddr byte blob into an endpoint, or `nil` if malformed or an
    /// unsupported address family.
    public static func endpoint(fromSockaddr bytes: [UInt8]) -> Endpoint? {
        guard bytes.count >= 2 else { return nil }

        switch Int32(bytes[1]) {
        case AF_INET:
            guard bytes.count >= 8 else { return nil }
            let port = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
            guard let address = IPAddress(bytes: Array(bytes[4 ..< 8])) else { return nil }
            return Endpoint(address: address.unmappedIPv4, port: port)
        case AF_INET6:
            guard bytes.count >= 24 else { return nil }
            let port = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
            guard let address = IPAddress(bytes: Array(bytes[8 ..< 24])) else { return nil }
            return Endpoint(address: address.unmappedIPv4, port: port)
        default:
            return nil
        }
    }
}
