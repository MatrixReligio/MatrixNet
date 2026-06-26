import Foundation
import MatrixNetModel

/// A packet captured via PKTAP (DLT_PKTAP): the inner packet plus the kernel's
/// per-packet process attribution.
public struct PKTAPPacket: Sendable, Equatable {
    public let pid: Int32
    public let processName: String
    public let direction: TrafficDirection
    /// DLT of the inner packet (e.g. DLT_EN10MB = 1, DLT_RAW = 12).
    public let dlt: UInt32
    /// The inner packet bytes (Ethernet frame or raw IP), ready for dissection.
    public let payload: [UInt8]
}

/// Parses the `pktap_header` (bsd/net/pktap.h) that precedes each PKTAP packet.
/// Values are host byte order (little-endian on Apple silicon). Offsets are taken
/// verbatim from the struct; `pth_length` locates the inner packet so future
/// header growth is tolerated. Any malformed buffer yields `nil`, never a crash.
public enum PKTAPParser {
    /// Field offsets within pktap_header.
    private enum Offset {
        static let length = 0 // pth_length: uint32
        static let dlt = 8 // pth_dlt: uint32
        static let flags = 36 // pth_flags: uint32
        static let pid = 52 // pth_pid: pid_t (int32)
        static let comm = 56 // pth_comm: char[17]
        static let commLength = 17
        /// Minimum bytes that must precede the inner packet for the fields we read.
        static let minimumHeader = comm + commLength
    }

    // pth_flags direction bits. Note: the header's constant names are the
    // opposite of their documented meaning — 0x1 means outgoing, 0x2 incoming.
    private static let flagOutgoing: UInt32 = 0x1
    private static let flagIncoming: UInt32 = 0x2

    public static func parse(_ bytes: [UInt8]) -> PKTAPPacket? {
        guard bytes.count >= Offset.minimumHeader else { return nil }

        func u32(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
        }

        let headerLength = Int(u32(Offset.length))
        guard headerLength >= Offset.minimumHeader, headerLength <= bytes.count else { return nil }

        let commBytes = bytes[Offset.comm ..< Offset.comm + Offset.commLength].prefix { $0 != 0 }
        let flags = u32(Offset.flags)
        let direction: TrafficDirection = if flags & flagOutgoing != 0 {
            .outbound
        } else if flags & flagIncoming != 0 {
            .inbound
        } else {
            .unknown
        }

        return PKTAPPacket(
            pid: Int32(bitPattern: u32(Offset.pid)),
            processName: String(bytes: commBytes, encoding: .utf8) ?? "",
            direction: direction,
            dlt: u32(Offset.dlt),
            payload: Array(bytes[headerLength...])
        )
    }
}
