import Foundation
import MatrixNetModel

/// A cumulative byte/packet counter snapshot for a connection.
public struct ConnectionCounts: Sendable, Equatable {
    public let bytesIn: UInt64
    public let bytesOut: UInt64
    public let packetsIn: UInt64
    public let packetsOut: UInt64
    public let timestamp: Date

    public init(bytesIn: UInt64, bytesOut: UInt64, packetsIn: UInt64, packetsOut: UInt64, timestamp: Date) {
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.packetsIn = packetsIn
        self.packetsOut = packetsOut
        self.timestamp = timestamp
    }
}

/// An event from a passive connection monitor (NetworkStatistics).
public enum ConnectionEvent: Sendable {
    /// A new connection (source) was observed.
    case added(Connection)
    /// Updated cumulative byte/packet counters for a connection.
    case counts(id: UUID, ConnectionCounts)
    /// A connection was closed/removed.
    case removed(UUID)
}

/// A passive, zero-conflict source of per-app connection events.
public protocol ConnectionMonitoring: Sendable {
    /// Starts monitoring and returns a stream of connection events.
    func start() -> AsyncStream<ConnectionEvent>
    /// Stops monitoring and finishes the stream.
    func stop()
}

/// A source of dissected-ready raw packets (PKTAP/BPF via the privileged helper).
public protocol PacketCapturing: Sendable {
    /// Starts capture with an optional BPF filter and returns a stream of packets.
    func start(filter: String?) async throws -> AsyncStream<Packet>
    /// Stops capture.
    func stop() async
}
