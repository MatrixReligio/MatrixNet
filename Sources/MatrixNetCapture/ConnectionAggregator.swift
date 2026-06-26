import Foundation
import MatrixNetModel

/// Maintains the live set of connections from a `ConnectionMonitoring` event
/// stream, and correlates dissected packets back to connections via the shared
/// `FlowCorrelator`. Both the connection-event source and the packet source feed
/// it concurrently, so it is an `actor`.
public actor ConnectionAggregator {
    private var connections: [UUID: Connection] = [:]
    private let correlator: FlowCorrelator

    public init(correlator: FlowCorrelator = FlowCorrelator()) {
        self.correlator = correlator
    }

    /// Applies a single connection event.
    public func apply(_ event: ConnectionEvent) async {
        switch event {
        case let .added(connection):
            connections[connection.id] = connection
            await correlator.register(connection)

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

        case let .removed(id):
            if var connection = connections[id] {
                connection.state = .closed
                connections[id] = connection
            }
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
