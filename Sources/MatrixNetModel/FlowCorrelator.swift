import Foundation

/// Thread-safe index that correlates the two passive capture sources:
/// kernel-reported connections (NetworkStatistics) and dissected packets
/// (PKTAP/BPF). Lookups match a packet's direction-insensitive `FlowKey`, with a
/// PID fallback, and an IP→hostname table enriches connections from observed DNS.
///
/// Isolated as an `actor` because both sources feed it concurrently at high rate.
public actor FlowCorrelator {
    private var connectionsByID: [UUID: Connection] = [:]
    private var connectionIDByFlowKey: [FlowKey: UUID] = [:]
    private var latestConnectionIDByPID: [Int32: UUID] = [:]
    private var hostnamesByIP: [IPAddress: String] = [:]

    public init() {}

    /// Registers or replaces a connection. A newer connection sharing a flow key
    /// (e.g. port reuse) takes over that key for future packet lookups.
    public func register(_ connection: Connection) {
        connectionsByID[connection.id] = connection
        connectionIDByFlowKey[connection.fiveTuple.flowKey] = connection.id
        latestConnectionIDByPID[connection.app.pid] = connection.id
    }

    /// Removes a connection and any index entry that still points to it.
    public func remove(connectionID: UUID) {
        guard let connection = connectionsByID.removeValue(forKey: connectionID) else { return }
        if connectionIDByFlowKey[connection.fiveTuple.flowKey] == connectionID {
            connectionIDByFlowKey[connection.fiveTuple.flowKey] = nil
        }
        if latestConnectionIDByPID[connection.app.pid] == connectionID {
            latestConnectionIDByPID[connection.app.pid] = nil
        }
    }

    /// The connection currently associated with a flow key, if any.
    public func connection(for flowKey: FlowKey) -> Connection? {
        guard let id = connectionIDByFlowKey[flowKey] else { return nil }
        return connectionsByID[id]
    }

    /// Resolves a dissected packet to its owning connection id: first by flow
    /// key, then by the most recent live connection for the packet's PID.
    public func connectionID(forPacketFlow flowKey: FlowKey, pid: Int32?) -> UUID? {
        if let id = connectionIDByFlowKey[flowKey] {
            return id
        }
        if let pid, let id = latestConnectionIDByPID[pid], connectionsByID[id] != nil {
            return id
        }
        return nil
    }

    /// Records an IP→hostname mapping observed in DNS traffic.
    public func recordHostname(_ hostname: String, for ip: IPAddress) {
        hostnamesByIP[ip] = hostname
    }

    /// The hostname observed for an IP, if any.
    public func hostname(for ip: IPAddress) -> String? {
        hostnamesByIP[ip]
    }

    /// All currently tracked connections.
    public var allConnections: [Connection] {
        Array(connectionsByID.values)
    }
}
