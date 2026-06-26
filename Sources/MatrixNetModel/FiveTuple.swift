/// A transport-layer protocol carried over IP.
public enum TransportProtocol: Hashable, Sendable {
    case tcp
    case udp
    case icmpv4
    case icmpv6
    /// Any other IP protocol number not modelled explicitly.
    case other(UInt8)

    /// The IANA IP protocol number.
    public var ipProtocolNumber: UInt8 {
        switch self {
        case .tcp: 6
        case .udp: 17
        case .icmpv4: 1
        case .icmpv6: 58
        case let .other(number): number
        }
    }

    /// Builds a protocol from its IANA IP protocol number.
    public init(ipProtocolNumber number: UInt8) {
        switch number {
        case 6: self = .tcp
        case 17: self = .udp
        case 1: self = .icmpv4
        case 58: self = .icmpv6
        default: self = .other(number)
        }
    }
}

/// One endpoint of a flow: an address and a port. Port is 0 for protocols
/// without ports (e.g. ICMP).
public struct Endpoint: Hashable, Sendable {
    public let address: IPAddress
    public let port: UInt16

    public init(address: IPAddress, port: UInt16) {
        self.address = address
        self.port = port
    }

    /// A total ordering used to canonicalise the two endpoints of a flow:
    /// IPv4 sorts before IPv6, then by address bytes, then by port.
    static func orderedPair(_ first: Endpoint, _ second: Endpoint) -> (low: Endpoint, high: Endpoint) {
        isLess(first, second) ? (first, second) : (second, first)
    }

    private static func isLess(_ first: Endpoint, _ second: Endpoint) -> Bool {
        let firstBytes = first.address.bytes
        let secondBytes = second.address.bytes
        if firstBytes.count != secondBytes.count {
            return firstBytes.count < secondBytes.count
        }
        for (lhs, rhs) in zip(firstBytes, secondBytes) where lhs != rhs {
            return lhs < rhs
        }
        return first.port < second.port
    }
}

/// A directed flow identifier: protocol + source + destination.
public struct FiveTuple: Hashable, Sendable {
    public let proto: TransportProtocol
    public let source: Endpoint
    public let destination: Endpoint

    public init(proto: TransportProtocol, source: Endpoint, destination: Endpoint) {
        self.proto = proto
        self.source = source
        self.destination = destination
    }

    /// A direction-insensitive key for correlating the two halves of a flow
    /// (e.g. a captured packet against a kernel-reported connection, regardless
    /// of which side is "source").
    public var flowKey: FlowKey {
        let pair = Endpoint.orderedPair(source, destination)
        return FlowKey(proto: proto, low: pair.low, high: pair.high)
    }
}

/// A direction-insensitive flow key. Two `FiveTuple`s that describe the same
/// flow in opposite directions produce equal `FlowKey`s.
public struct FlowKey: Hashable, Sendable {
    let proto: TransportProtocol
    let low: Endpoint
    let high: Endpoint
}
