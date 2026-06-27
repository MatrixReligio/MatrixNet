import Foundation

/// The lifecycle state of a connection as observed passively.
/// `Comparable` (active < closed, by declaration order) lets the connections
/// table sort by state.
public enum ConnectionState: Sendable, Hashable, Comparable {
    case active
    case closed
}

/// A network connection as reported by the kernel (NetworkStatistics), carrying
/// cumulative byte/packet counters and the owning process identity.
public struct Connection: Sendable, Identifiable {
    public let id: UUID
    public let fiveTuple: FiveTuple
    public var app: AppIdentity
    /// Cumulative bytes sent from the local host (transmit).
    public var bytesOut: UInt64
    /// Cumulative bytes received by the local host.
    public var bytesIn: UInt64
    public var packetsOut: UInt64
    public var packetsIn: UInt64
    public let startedAt: Date
    public var lastActivityAt: Date
    public var state: ConnectionState
    /// Resolved remote hostname (from DNS enrichment), when known.
    public var remoteHostname: String?

    public init(
        id: UUID = UUID(),
        fiveTuple: FiveTuple,
        app: AppIdentity,
        bytesOut: UInt64 = 0,
        bytesIn: UInt64 = 0,
        packetsOut: UInt64 = 0,
        packetsIn: UInt64 = 0,
        startedAt: Date,
        lastActivityAt: Date? = nil,
        state: ConnectionState = .active,
        remoteHostname: String? = nil
    ) {
        self.id = id
        self.fiveTuple = fiveTuple
        self.app = app
        self.bytesOut = bytesOut
        self.bytesIn = bytesIn
        self.packetsOut = packetsOut
        self.packetsIn = packetsIn
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt ?? startedAt
        self.state = state
        self.remoteHostname = remoteHostname
    }

    /// Total bytes transferred in both directions.
    /// Wrapping addition; in practice neither counter approaches `UInt64.max`.
    public var totalBytes: UInt64 {
        bytesIn &+ bytesOut
    }

    /// Applies the latest cumulative counters from the kernel. Byte and (optional)
    /// packet counters are clamped to be monotonic (a stale, smaller sample never
    /// lowers them) and `lastActivityAt` advances only when some counter actually
    /// grows, so idle refreshes do not mark the connection as active.
    public mutating func updateCumulativeCounts(
        bytesIn newBytesIn: UInt64,
        bytesOut newBytesOut: UInt64,
        packetsIn newPacketsIn: UInt64? = nil,
        packetsOut newPacketsOut: UInt64? = nil,
        at timestamp: Date
    ) {
        let clampedBytesIn = max(newBytesIn, bytesIn)
        let clampedBytesOut = max(newBytesOut, bytesOut)
        var advanced = clampedBytesIn > bytesIn || clampedBytesOut > bytesOut
        bytesIn = clampedBytesIn
        bytesOut = clampedBytesOut

        if let newPacketsIn {
            let clamped = max(newPacketsIn, packetsIn)
            advanced = advanced || clamped > packetsIn
            packetsIn = clamped
        }
        if let newPacketsOut {
            let clamped = max(newPacketsOut, packetsOut)
            advanced = advanced || clamped > packetsOut
            packetsOut = clamped
        }

        if advanced {
            lastActivityAt = timestamp
        }
    }
}
