/// The structured TCP header fields needed for passive flow-quality analysis,
/// decoded once by the dissector so downstream consumers never re-parse bytes.
public struct TCPSegment: Sendable, Equatable {
    public let flags: TCPFlags
    public let sequence: UInt32
    public let acknowledgement: UInt32
    /// Number of application bytes carried by this segment (0 for a pure ACK).
    public let payloadLength: Int

    public init(flags: TCPFlags, sequence: UInt32, acknowledgement: UInt32, payloadLength: Int) {
        self.flags = flags
        self.sequence = sequence
        self.acknowledgement = acknowledgement
        self.payloadLength = payloadLength
    }
}

/// The TCP control bits (RFC 9293) as an option set.
public struct TCPFlags: OptionSet, Sendable, Equatable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let fin = TCPFlags(rawValue: 0x001)
    public static let syn = TCPFlags(rawValue: 0x002)
    public static let rst = TCPFlags(rawValue: 0x004)
    public static let psh = TCPFlags(rawValue: 0x008)
    public static let ack = TCPFlags(rawValue: 0x010)
    public static let urg = TCPFlags(rawValue: 0x020)
}
