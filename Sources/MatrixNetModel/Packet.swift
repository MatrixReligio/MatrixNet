import Foundation

/// The direction of a packet or flow relative to the local host.
public enum TrafficDirection: Sendable, Hashable {
    case outbound
    case inbound
    case unknown
}

/// A single captured packet as delivered by the capture layer (PKTAP/BPF),
/// before protocol dissection. Bytes may be truncated to the capture snap length.
public struct Packet: Sendable, Identifiable {
    /// Monotonic capture index, unique within a capture session.
    public let id: UInt64
    public let timestamp: Date
    public let direction: TrafficDirection
    /// Per-packet owning PID when PKTAP supplies it; `nil` otherwise.
    public let pid: Int32?
    /// The full on-the-wire length, which may exceed `data.count` when truncated.
    public let originalLength: Int
    /// The captured bytes (possibly truncated to the snap length).
    public let data: [UInt8]
    public let interfaceName: String?

    public init(
        id: UInt64,
        timestamp: Date,
        direction: TrafficDirection,
        pid: Int32?,
        originalLength: Int,
        data: [UInt8],
        interfaceName: String?
    ) {
        self.id = id
        self.timestamp = timestamp
        self.direction = direction
        self.pid = pid
        self.originalLength = originalLength
        self.data = data
        self.interfaceName = interfaceName
    }

    /// Whether the captured bytes are shorter than the original wire length.
    public var isTruncated: Bool {
        data.count < originalLength
    }
}
