/// Well-known pcap/pcapng link-layer types.
public enum PcapLinkType {
    public static let ethernet: UInt32 = 1
    public static let raw: UInt32 = 101
    /// Apple PKTAP — carries per-packet process metadata; Wireshark 4.6+ decodes it.
    public static let pktap: UInt32 = 258
}

/// One captured packet as written to / read from a pcapng file.
public struct CapturedRecord: Sendable, Equatable {
    /// Capture time in microseconds since the Unix epoch.
    public let timestampMicros: UInt64
    /// The original on-the-wire length (may exceed `data.count` when truncated).
    public let originalLength: Int
    /// The captured bytes (possibly truncated to the snap length).
    public let data: [UInt8]

    public init(timestampMicros: UInt64, originalLength: Int, data: [UInt8]) {
        self.timestampMicros = timestampMicros
        self.originalLength = originalLength
        self.data = data
    }
}

/// Little-endian byte accumulation helper for building pcapng blocks.
struct LittleEndianWriter {
    private(set) var bytes = [UInt8]()

    mutating func u16(_ value: UInt16) {
        bytes.append(UInt8(value & 0xFF))
        bytes.append(UInt8(value >> 8 & 0xFF))
    }

    mutating func u32(_ value: UInt32) {
        for shift in stride(from: 0, through: 24, by: 8) {
            bytes.append(UInt8(value >> UInt32(shift) & 0xFF))
        }
    }

    mutating func raw(_ data: [UInt8]) {
        bytes.append(contentsOf: data)
    }

    /// Appends zero bytes until the length is a multiple of four.
    mutating func pad32() {
        while !bytes.count.isMultiple(of: 4) {
            bytes.append(0)
        }
    }
}
