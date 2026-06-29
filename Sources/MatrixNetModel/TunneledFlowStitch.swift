/// Stitches a kernel (NetworkStatistics) connection — which under a TUN proxy
/// reports a synthetic fake-IP destination and 0 bytes — to its reconstructed
/// tunneled flow, replacing the byte counters with the real packet-derived
/// totals and the hostname with the real SNI domain.
///
/// Matching is by the direction-insensitive `FlowKey`: under fake-IP TUN, the
/// app's socket and the captured utun packets share the same (gateway-sourced)
/// 5-tuple. If real-machine validation shows `NetworkStatistics` reports the
/// app's true local address instead of the tunnel gateway, switch the match key
/// to `(app PID + fake destination)` — see plan Task 1.0.
public enum TunneledFlowStitch {
    /// Whether `flow` is the reconstructed counterpart of `connection`.
    public static func matches(
        connection: Connection,
        flow: TunneledFlowReconstructor.ReconstructedFlow
    ) -> Bool {
        connection.fiveTuple.flowKey == flow.flowKey
    }

    /// Returns `connection` with its byte counters and hostname replaced by the
    /// reconstructed flow's real values.
    public static func merge(
        connection: Connection,
        flow: TunneledFlowReconstructor.ReconstructedFlow
    ) -> Connection {
        var merged = connection
        merged.bytesOut = flow.bytesOut
        merged.bytesIn = flow.bytesIn
        if let domain = flow.domain {
            merged.remoteHostname = domain
        }
        return merged
    }
}
