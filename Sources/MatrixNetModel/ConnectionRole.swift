/// Whether the local host is acting as the client (it initiated the connection)
/// or the server (it accepted one) for a flow. The kernel does not record which
/// side called `connect()`, so this is a port-based heuristic: reliable for the
/// common ephemeral↔service shape, deliberately `unknown` when ambiguous (e.g.
/// peer-to-peer or two ephemeral ports).
public enum ConnectionRole: String, Sendable {
    case client
    case server
    case unknown

    /// A short English label (UI renders its own localized text per case).
    public var label: String {
        switch self {
        case .client: "Client"
        case .server: "Server"
        case .unknown: "—"
        }
    }
}

public extension FiveTuple {
    /// macOS draws ephemeral source ports from the IANA dynamic range.
    private static let ephemeralPorts: ClosedRange<UInt16> = 49152 ... 65535

    /// Infers whether the local end is the client or server side. `source` is
    /// the local endpoint and `destination` the remote, per MatrixNet's
    /// convention for kernel-reported connections.
    var role: ConnectionRole {
        guard proto == .tcp || proto == .udp else { return .unknown }
        let local = source.port
        let remote = destination.port
        guard local != 0, remote != 0 else { return .unknown }

        let localEphemeral = Self.ephemeralPorts.contains(local)
        let remoteEphemeral = Self.ephemeralPorts.contains(remote)
        if localEphemeral, !remoteEphemeral { return .client }
        if remoteEphemeral, !localEphemeral { return .server }
        if !localEphemeral, !remoteEphemeral, local != remote {
            // Two registered/well-known ports: the lower one is the service.
            return local < remote ? .server : .client
        }
        return .unknown
    }
}
