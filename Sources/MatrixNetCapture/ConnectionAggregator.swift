import Foundation
import MatrixNetModel

/// Maintains the live set of connections from a `ConnectionMonitoring` event
/// stream, and correlates dissected packets back to connections via the shared
/// `FlowCorrelator`. Both the connection-event source and the packet source feed
/// it concurrently, so it is an `actor`.
public actor ConnectionAggregator {
    private var connections: [UUID: Connection] = [:]
    private let correlator: FlowCorrelator

    /// Session-cumulative byte totals. Unlike the live snapshot (which drops a
    /// connection the moment it closes), these only ever grow, so the Overview
    /// and widget can show meaningful "traffic since launch" and a throughput
    /// rate even when high-traffic flows are short-lived. We add the positive
    /// delta of each connection's monotonic counters as they advance; a
    /// connection's first sighting establishes a baseline so pre-existing
    /// lifetime bytes are not counted as session traffic.
    private var sessionBytesIn: UInt64 = 0
    private var sessionBytesOut: UInt64 = 0
    private var lastSeenIn: [UUID: UInt64] = [:]
    private var lastSeenOut: [UUID: UInt64] = [:]

    public init(correlator: FlowCorrelator = FlowCorrelator()) {
        self.correlator = correlator
    }

    /// Accumulates the positive growth of a connection's counters into the
    /// session totals. The first call for an id only records a baseline.
    private func accumulateSession(id: UUID, bytesIn: UInt64, bytesOut: UInt64) {
        if let last = lastSeenIn[id], bytesIn > last { sessionBytesIn &+= bytesIn - last }
        if let last = lastSeenOut[id], bytesOut > last { sessionBytesOut &+= bytesOut - last }
        lastSeenIn[id] = bytesIn
        lastSeenOut[id] = bytesOut
    }

    /// Session-cumulative byte totals (monotonic; survive connection removal).
    public func sessionTotals() -> (bytesIn: UInt64, bytesOut: UInt64) {
        (sessionBytesIn, sessionBytesOut)
    }

    /// Applies a single connection event.
    public func apply(_ event: ConnectionEvent) async {
        switch event {
        case let .added(connection):
            // A re-described connection refreshes identity/state but must not
            // regress its (monotonic) byte/packet counters.
            let existing = connections[connection.id]
            var resolved = connection
            if let existing {
                resolved.bytesIn = max(connection.bytesIn, existing.bytesIn)
                resolved.bytesOut = max(connection.bytesOut, existing.bytesOut)
                resolved.packetsIn = max(connection.packetsIn, existing.packetsIn)
                resolved.packetsOut = max(connection.packetsOut, existing.packetsOut)
            }
            connections[connection.id] = resolved
            accumulateSession(id: resolved.id, bytesIn: resolved.bytesIn, bytesOut: resolved.bytesOut)
            // Only (re)register new connections for packet correlation; the flow
            // key is stable, so re-describes need no extra cross-actor work.
            if existing == nil {
                await correlator.register(resolved)
            }

        case let .counts(id, counts):
            guard var connection = connections[id] else { return }
            connection.updateCumulativeCounts(
                bytesIn: counts.bytesIn,
                bytesOut: counts.bytesOut,
                packetsIn: counts.packetsIn,
                packetsOut: counts.packetsOut,
                at: counts.timestamp
            )
            connections[id] = connection
            accumulateSession(id: id, bytesIn: connection.bytesIn, bytesOut: connection.bytesOut)

        case let .removed(id):
            // Drop closed flows from the live snapshot so the view shows current
            // connections (nettop/Activity Monitor semantics). Historical flows
            // are the persistence layer's concern. Session totals deliberately
            // retain this connection's contribution; only its per-id baseline is
            // released so the maps don't grow unbounded.
            connections[id] = nil
            lastSeenIn[id] = nil
            lastSeenOut[id] = nil
            await correlator.remove(connectionID: id)
        }
    }

    /// Drains an event stream until it finishes.
    public func consume(_ stream: AsyncStream<ConnectionEvent>) async {
        for await event in stream {
            await apply(event)
        }
    }

    /// A snapshot of all currently tracked connections.
    public func snapshot() -> [Connection] {
        Array(connections.values)
    }

    /// Resolves a dissected packet to its owning connection id.
    public func connectionID(forPacketFlow flowKey: FlowKey, pid: Int32?) async -> UUID? {
        await correlator.connectionID(forPacketFlow: flowKey, pid: pid)
    }

    /// Records a DNS-observed hostname for later enrichment.
    public func recordHostname(_ hostname: String, for ip: IPAddress) async {
        await correlator.recordHostname(hostname, for: ip)
    }
}
