import Foundation

/// The lifecycle state of a connection as observed passively.
public enum ConnectionState: Sendable, Hashable {
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
    public var totalBytes: UInt64 {
        bytesIn &+ bytesOut
    }

    /// Applies the latest cumulative counters from the kernel. Counters are
    /// clamped to be monotonic (a stale, smaller sample never lowers them) and
    /// `lastActivityAt` advances only when the counters actually grow, so idle
    /// refreshes do not mark the connection as active.
    public mutating func updateCumulativeCounts(
        bytesIn newBytesIn: UInt64,
        bytesOut newBytesOut: UInt64,
        at timestamp: Date
    ) {
        let clampedIn = max(newBytesIn, bytesIn)
        let clampedOut = max(newBytesOut, bytesOut)
        let advanced = clampedIn > bytesIn || clampedOut > bytesOut
        bytesIn = clampedIn
        bytesOut = clampedOut
        if advanced {
            lastActivityAt = timestamp
        }
    }
}
