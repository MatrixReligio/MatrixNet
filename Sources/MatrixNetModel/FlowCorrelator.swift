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
    /// All live connection ids per PID, most recent last. Keeping every live id
    /// (not just the latest) means removing one connection never blinds the PID
    /// fallback to the process's other still-open connections.
    private var connectionIDsByPID: [Int32: [UUID]] = [:]
    private var hostnamesByIP: [IPAddress: String] = [:]

    public init() {}

    /// Registers or replaces a connection. A newer connection sharing a flow key
    /// (e.g. port reuse) takes over that key for future packet lookups.
    public func register(_ connection: Connection) {
        let isNew = connectionsByID[connection.id] == nil
        connectionsByID[connection.id] = connection
        connectionIDByFlowKey[connection.fiveTuple.flowKey] = connection.id
        if isNew {
            connectionIDsByPID[connection.app.pid, default: []].append(connection.id)
        }
    }

    /// Removes a connection and any index entry that still points to it.
    public func remove(connectionID: UUID) {
        guard let connection = connectionsByID.removeValue(forKey: connectionID) else { return }
        if connectionIDByFlowKey[connection.fiveTuple.flowKey] == connectionID {
            connectionIDByFlowKey[connection.fiveTuple.flowKey] = nil
        }
        let pid = connection.app.pid
        if var ids = connectionIDsByPID[pid] {
            ids.removeAll { $0 == connectionID }
            connectionIDsByPID[pid] = ids.isEmpty ? nil : ids
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
        if let pid, let ids = connectionIDsByPID[pid] {
            // Most recent live connection for this PID.
            return ids.last { connectionsByID[$0] != nil }
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

    /// The full IP→hostname table observed so far (SNI + DNS enrichment).
    public func allHostnames() -> [IPAddress: String] {
        hostnamesByIP
    }

    /// All currently tracked connections.
    public var allConnections: [Connection] {
        Array(connectionsByID.values)
    }
}
