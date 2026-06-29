/// One app's connections collapsed into a single row for the app-aggregated
/// Connections / History / Usage views: the owning app, summed byte counters and
/// connection count, plus the underlying connections (busiest first) for the
/// drill-down that shows the individual flows.
public struct AppConnectionGroup: Sendable, Identifiable {
    public let app: AppIdentity
    public let connections: [Connection]

    public init(app: AppIdentity, connections: [Connection]) {
        self.app = app
        self.connections = connections
    }

    public var id: String {
        app.displayName
    }

    public var connectionCount: Int {
        connections.count
    }

    public var bytesIn: UInt64 {
        connections.reduce(0) { $0 &+ $1.bytesIn }
    }

    public var bytesOut: UInt64 {
        connections.reduce(0) { $0 &+ $1.bytesOut }
    }

    public var totalBytes: UInt64 {
        bytesIn &+ bytesOut
    }
}

/// Collapses a flat connection list into per-app groups for the aggregated views.
public enum ConnectionGrouping {
    /// Groups by display name (so a process and its helpers collapse together),
    /// busiest group first; within each group the connections are busiest first.
    public static func byApp(_ connections: [Connection]) -> [AppConnectionGroup] {
        Dictionary(grouping: connections, by: { $0.app.displayName })
            .compactMap { _, group -> AppConnectionGroup? in
                let sorted = group.sorted { $0.totalBytes > $1.totalBytes }
                guard let representative = sorted.first else { return nil }
                return AppConnectionGroup(app: representative.app, connections: sorted)
            }
            .sorted { lhs, rhs in
                if lhs.totalBytes != rhs.totalBytes { return lhs.totalBytes > rhs.totalBytes }
                if lhs.connectionCount != rhs.connectionCount { return lhs.connectionCount > rhs.connectionCount }
                return lhs.app.displayName < rhs.app.displayName
            }
    }
}
