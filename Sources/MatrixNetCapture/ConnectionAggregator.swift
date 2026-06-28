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

    /// Session-cumulative traffic bucketed by app, keyed by display name. Built
    /// from the same positive deltas as the global session totals, so it stays
    /// meaningful even though most live connections report 0 instantaneous bytes
    /// (idle keep-alives) and high-traffic flows are short-lived. This is what
    /// the Overview and widget "top talkers" read — summing the live snapshot's
    /// instantaneous per-connection bytes would show ~0 for everything.
    private var trafficByApp: [String: AppTraffic] = [:]

    /// Packet-derived byte totals, populated only while packet capture is active.
    /// Captured at the data-link layer (PKTAP), these see real per-flow bytes even
    /// when a transparent proxy/VPN hides them from `NetworkStatistics` — so the
    /// connections table and top talkers show true figures while capturing.
    private var packetBytesByConn: [UUID: (inBytes: UInt64, outBytes: UInt64)] = [:]
    private var packetTrafficByApp: [String: AppTraffic] = [:]

    /// Monotonic per-(app, destination address) packet byte totals for the Usage
    /// tab. Unlike `packetBytesByConn`, these are NOT dropped on `.removed`, so a
    /// short-lived flow that opens and closes between Usage polls is still
    /// accounted for. Keyed by `"app\u{1F}address"`.
    private var usageByFlow: [String: UsageFlowTotal] = [:]

    /// NStat-derived per-(app, address) usage, accumulated from connection-counter
    /// deltas so the Usage tab works during ordinary passive monitoring (when
    /// packet capture is not running). Packet-derived `usageByFlow` is preferred
    /// when capturing; this is the always-on fallback.
    private var nstatUsageByFlow: [String: UsageFlowTotal] = [:]

    /// Set of JA4 TLS client fingerprints observed per app (display name).
    /// Populated only while packet capture is active (a ClientHello is required);
    /// de-duplicated by app + fingerprint.
    private var fingerprintsByApp: [String: Set<String>] = [:]

    /// One `FlowQualityTracker` per live flow, fed segment-by-segment while
    /// capturing. Keyed by `FlowKey` (direction-insensitive) so both directions
    /// of a flow accumulate into the same tracker.
    private var qualityByFlow: [FlowKey: FlowQualityTracker] = [:]
    /// The app + destination a flow's quality belongs to, captured at record time
    /// so the snapshot survives the connection's removal from the live set.
    private var qualityApp: [FlowKey: (app: String, address: IPAddress)] = [:]

    /// The passively measured quality of one app's flow to a destination.
    public struct AppFlowQuality: Sendable, Equatable {
        public let app: String
        public let address: IPAddress
        public let quality: FlowQuality
    }

    /// A monotonic byte total for one app talking to one destination address.
    public struct UsageFlowTotal: Sendable {
        public let app: String
        public let address: IPAddress
        public var bytesIn: UInt64
        public var bytesOut: UInt64
    }

    /// A captured packet attributed to a flow, handed in by the packet pipeline.
    public struct PacketAttribution: Sendable {
        public let flowKey: FlowKey
        public let pid: Int32
        public let inbound: Bool
        public let bytes: Int
        public init(flowKey: FlowKey, pid: Int32, inbound: Bool, bytes: Int) {
            self.flowKey = flowKey
            self.pid = pid
            self.inbound = inbound
            self.bytes = bytes
        }
    }

    public init(correlator: FlowCorrelator = FlowCorrelator()) {
        self.correlator = correlator
    }

    /// Attributes captured packets to their connections (by flow key, with a PID
    /// fallback) and accumulates real byte totals per connection and per app.
    public func attributePackets(_ packets: [PacketAttribution]) async {
        for packet in packets {
            guard let id = await correlator.connectionID(forPacketFlow: packet.flowKey, pid: packet.pid) else {
                continue
            }
            let bytes = UInt64(max(0, packet.bytes))
            var conn = packetBytesByConn[id] ?? (inBytes: 0, outBytes: 0)
            if packet.inbound { conn.inBytes &+= bytes } else { conn.outBytes &+= bytes }
            packetBytesByConn[id] = conn

            guard let connection = connections[id] else { continue }
            let key = connection.app.displayName
            var traffic = packetTrafficByApp[key] ?? AppTraffic(app: connection.app)
            traffic.app = connection.app
            if packet.inbound { traffic.bytesIn &+= bytes } else { traffic.bytesOut &+= bytes }
            packetTrafficByApp[key] = traffic

            // Monotonic per-(app, address) usage that survives the connection's
            // removal, so the Usage tab can account for short-lived flows.
            let address = connection.fiveTuple.destination.address
            let usageKey = "\(connection.app.displayName)\u{1F}\(address.description)"
            var flow = usageByFlow[usageKey]
                ?? UsageFlowTotal(app: connection.app.displayName, address: address, bytesIn: 0, bytesOut: 0)
            if packet.inbound { flow.bytesIn &+= bytes } else { flow.bytesOut &+= bytes }
            usageByFlow[usageKey] = flow
        }
    }

    /// Monotonic per-(app, address) usage totals for the Usage tab (these survive
    /// connection close, unlike the per-connection map). Prefers packet-derived
    /// figures while capturing (accurate under a proxy); otherwise falls back to
    /// the NStat-derived totals so usage accrues during ordinary monitoring.
    public func usageSnapshot() -> [UsageFlowTotal] {
        usageByFlow.isEmpty ? Array(nstatUsageByFlow.values) : Array(usageByFlow.values)
    }

    /// Accumulates the positive growth of a connection's counters into the global
    /// session totals and the per-app totals. The first call for a connection
    /// only records a baseline (so pre-existing lifetime bytes are not counted).
    private func accumulateSession(for connection: Connection) {
        let id = connection.id
        var deltaIn: UInt64 = 0
        var deltaOut: UInt64 = 0
        if let last = lastSeenIn[id], connection.bytesIn > last { deltaIn = connection.bytesIn - last }
        if let last = lastSeenOut[id], connection.bytesOut > last { deltaOut = connection.bytesOut - last }
        lastSeenIn[id] = connection.bytesIn
        lastSeenOut[id] = connection.bytesOut

        guard deltaIn > 0 || deltaOut > 0 else { return }
        sessionBytesIn &+= deltaIn
        sessionBytesOut &+= deltaOut

        let key = connection.app.displayName
        var traffic = trafficByApp[key] ?? AppTraffic(app: connection.app)
        traffic.app = connection.app // keep the latest pid/path for icon lookup
        traffic.bytesIn &+= deltaIn
        traffic.bytesOut &+= deltaOut
        trafficByApp[key] = traffic

        // Mirror the per-app delta into a per-(app, address) total so the Usage
        // tab has data even without packet capture (survives connection close).
        let address = connection.fiveTuple.destination.address
        let flowKey = "\(connection.app.displayName)\u{1F}\(address.description)"
        var flow = nstatUsageByFlow[flowKey]
            ?? UsageFlowTotal(app: connection.app.displayName, address: address, bytesIn: 0, bytesOut: 0)
        flow.bytesIn &+= deltaIn
        flow.bytesOut &+= deltaOut
        nstatUsageByFlow[flowKey] = flow
    }

    /// Session-cumulative byte totals (monotonic; survive connection removal).
    public func sessionTotals() -> (bytesIn: UInt64, bytesOut: UInt64) {
        (sessionBytesIn, sessionBytesOut)
    }

    /// Session-cumulative per-app traffic (monotonic; survives connection removal).
    /// Prefers packet-derived figures while capturing (accurate under a proxy),
    /// falling back to the `NetworkStatistics`-derived totals otherwise.
    public func appTraffic() -> [AppTraffic] {
        packetTrafficByApp.isEmpty ? Array(trafficByApp.values) : Array(packetTrafficByApp.values)
    }

    /// Clears all live and session state so a stopped-then-restarted monitor
    /// starts from a clean slate (the monitor reassigns ids on restart, so old
    /// entries would otherwise never receive `.removed` and linger as ghosts).
    public func reset() {
        connections.removeAll()
        lastSeenIn.removeAll()
        lastSeenOut.removeAll()
        trafficByApp.removeAll()
        packetBytesByConn.removeAll()
        packetTrafficByApp.removeAll()
        usageByFlow.removeAll()
        nstatUsageByFlow.removeAll()
        fingerprintsByApp.removeAll()
        qualityByFlow.removeAll()
        qualityApp.removeAll()
        sessionBytesIn = 0
        sessionBytesOut = 0
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
            accumulateSession(for: resolved)
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
            accumulateSession(for: connection)

        case let .removed(id):
            // Drop closed flows from the live snapshot so the view shows current
            // connections (nettop/Activity Monitor semantics). Historical flows
            // are the persistence layer's concern. Session totals deliberately
            // retain this connection's contribution; only its per-id baseline is
            // released so the maps don't grow unbounded.
            connections[id] = nil
            lastSeenIn[id] = nil
            lastSeenOut[id] = nil
            // The per-app packet total already captured this flow's bytes; drop
            // the per-connection tally so the map doesn't grow without bound.
            packetBytesByConn[id] = nil
            await correlator.remove(connectionID: id)
        }
    }

    /// Drains an event stream until it finishes.
    public func consume(_ stream: AsyncStream<ConnectionEvent>) async {
        for await event in stream {
            await apply(event)
        }
    }

    /// A snapshot of all currently tracked connections. While packet capture is
    /// active, a connection's byte counters are replaced with the packet-derived
    /// totals so the table shows real figures even under a proxy.
    public func snapshot() -> [Connection] {
        connections.values.map { connection in
            guard let packet = packetBytesByConn[connection.id] else { return connection }
            var merged = connection
            merged.bytesIn = packet.inBytes
            merged.bytesOut = packet.outBytes
            return merged
        }
    }

    /// Resolves a dissected packet to its owning connection id.
    public func connectionID(forPacketFlow flowKey: FlowKey, pid: Int32?) async -> UUID? {
        await correlator.connectionID(forPacketFlow: flowKey, pid: pid)
    }

    /// Records a DNS- or SNI-observed hostname for later enrichment.
    public func recordHostname(_ hostname: String, for ip: IPAddress) async {
        await correlator.recordHostname(hostname, for: ip)
    }

    /// The full IP→hostname table observed from SNI and DNS, for enriching the
    /// connection snapshot (preferred over reverse DNS).
    public func hostnameSnapshot() async -> [IPAddress: String] {
        await correlator.allHostnames()
    }

    /// Records a TLS client fingerprint (JA4) against the app that owns `flowKey`.
    /// Dropped when the flow cannot be resolved to a tracked connection.
    public func recordFingerprint(_ ja4: String, flowKey: FlowKey, pid: Int32) async {
        guard let id = await correlator.connectionID(forPacketFlow: flowKey, pid: pid),
              let connection = connections[id] else { return }
        fingerprintsByApp[connection.app.displayName, default: []].insert(ja4)
    }

    /// All observed (app, JA4) pairs.
    public func fingerprintSnapshot() -> [AppFingerprintObservation] {
        fingerprintsByApp.flatMap { app, fingerprints in
            fingerprints.map { AppFingerprintObservation(app: app, ja4: $0) }
        }
    }

    /// Feeds one observed TCP segment into the quality tracker for its flow.
    /// Dropped when the flow cannot be resolved to a tracked connection.
    public func recordTCP(
        _ segment: TCPSegment,
        timestampMicros: UInt64,
        inbound: Bool,
        flowKey: FlowKey,
        pid: Int32
    ) async {
        guard let id = await correlator.connectionID(forPacketFlow: flowKey, pid: pid),
              let connection = connections[id] else { return }
        var tracker = qualityByFlow[flowKey] ?? FlowQualityTracker()
        tracker.ingest(timestampMicros: timestampMicros, inbound: inbound, segment: segment)
        qualityByFlow[flowKey] = tracker
        qualityApp[flowKey] = (connection.app.displayName, connection.fiveTuple.destination.address)
    }

    /// A snapshot of every tracked flow's quality, attributed to its app.
    public func qualitySnapshot() -> [AppFlowQuality] {
        qualityByFlow.compactMap { key, tracker in
            guard let owner = qualityApp[key] else { return nil }
            return AppFlowQuality(app: owner.app, address: owner.address, quality: tracker.quality)
        }
    }
}
