import Foundation

/// A protocol's share of the active connections (0...1).
public struct ProtocolShare: Equatable, Sendable {
    public let label: String
    public let share: Double

    public init(label: String, share: Double) {
        self.label = label
        self.share = share
    }
}

/// How many active connections reach a destination country. Ranked by count
/// rather than bytes because the kernel reports 0 per-connection bytes for many
/// sockets (idle keep-alives, proxied/loopback flows), which would leave the
/// bars empty.
public struct CountryActivity: Equatable, Sendable {
    public let country: String
    public let connections: Int

    public init(country: String, connections: Int) {
        self.country = country
        self.connections = connections
    }
}

/// Pure aggregations over the live connection set for the Overview dashboard.
/// Country and proxy lookups are injected so the module stays dependency-free
/// and the logic is deterministically testable.
public enum OverviewStats {
    private static func active(_ connections: [Connection]) -> [Connection] {
        connections.filter { $0.state == .active }
    }

    /// Distinct processes that currently have an active connection.
    public static func activeAppCount(_ connections: [Connection]) -> Int {
        Set(active(connections).map(\.app)).count
    }

    /// Distinct known countries among active remote addresses.
    public static func countriesReached(
        _ connections: [Connection],
        country: (IPAddress) -> String?
    ) -> Int {
        var seen = Set<String>()
        for connection in active(connections) {
            if let code = country(connection.fiveTuple.destination.address) {
                seen.insert(code)
            }
        }
        return seen.count
    }

    /// Fraction (0...1) of active traffic routed through a proxy/tunnel, weighted
    /// by bytes when byte data is available (i.e. while capturing), and falling
    /// back to the fraction of proxied *connections* when it is not (NStat-only
    /// monitoring, where proxied flows report 0 bytes — counting would otherwise
    /// collapse to 0% even with the proxy clearly in use).
    ///
    /// Relay legs — the proxy engine's own upstream connections (e.g. a
    /// `…TunnelProvider` to the remote node) — are excluded via `isRelay` so the
    /// relayed bytes are not double-counted against the apps that originated them.
    /// `routesThroughProxy` receives the full remote endpoint because proxy
    /// detection is port-sensitive (loopback + a known proxy port) and, for TUN
    /// flows, fake-IP/tunnel aware.
    public static func proxyShare(
        _ connections: [Connection],
        isRelay: (Connection) -> Bool = { _ in false },
        routesThroughProxy: (Endpoint) -> Bool
    ) -> Double {
        let considered = active(connections).filter { !isRelay($0) }
        guard !considered.isEmpty else { return 0 }

        let totalBytes = considered.reduce(UInt64(0)) { $0 &+ $1.totalBytes }
        if totalBytes > 0 {
            let proxiedBytes = considered.reduce(UInt64(0)) {
                $0 &+ (routesThroughProxy($1.fiveTuple.destination) ? $1.totalBytes : 0)
            }
            return Double(proxiedBytes) / Double(totalBytes)
        }

        // No byte data (NStat-only) → fall back to the proxied-connection fraction.
        let proxiedCount = considered.reduce(0) {
            $0 + (routesThroughProxy($1.fiveTuple.destination) ? 1 : 0)
        }
        return Double(proxiedCount) / Double(considered.count)
    }

    /// A best-effort application-protocol label from the well-known service port
    /// (checking both endpoints so server-role flows classify correctly), falling
    /// back to the transport name.
    public static func applicationProtocol(_ tuple: FiveTuple) -> String {
        let ports = [tuple.source.port, tuple.destination.port]
        if ports.contains(53) { return "DNS" }
        switch tuple.proto {
        case .tcp:
            if ports.contains(443) { return "TLS" }
            if ports.contains(80) { return "HTTP" }
        case .udp:
            if ports.contains(443) { return "QUIC" }
        default:
            break
        }
        return tuple.proto.displayName
    }

    /// Share of active connections by application protocol, most common first.
    public static func protocolMix(_ connections: [Connection]) -> [ProtocolShare] {
        let activeConnections = active(connections)
        guard !activeConnections.isEmpty else { return [] }
        var counts: [String: Int] = [:]
        for connection in activeConnections {
            counts[applicationProtocol(connection.fiveTuple), default: 0] += 1
        }
        let total = Double(activeConnections.count)
        return counts
            .map { ProtocolShare(label: $0.key, share: Double($0.value) / total) }
            .sorted { lhs, rhs in
                lhs.share != rhs.share ? lhs.share > rhs.share : lhs.label < rhs.label
            }
    }

    /// Active connections grouped by destination country, most connections first.
    public static func destinationCountries(
        _ connections: [Connection],
        country: (IPAddress) -> String?
    ) -> [CountryActivity] {
        var counts: [String: Int] = [:]
        for connection in active(connections) {
            if let code = country(connection.fiveTuple.destination.address) {
                counts[code, default: 0] += 1
            }
        }
        return counts
            .map { CountryActivity(country: $0.key, connections: $0.value) }
            .sorted { lhs, rhs in
                lhs.connections != rhs.connections ? lhs.connections > rhs.connections : lhs.country < rhs.country
            }
    }
}
