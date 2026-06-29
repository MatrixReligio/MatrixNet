/// Reconstructs the originating app, true domain (SNI), and true byte volume of
/// flows that a TUN proxy routes through a tunnel interface (where the kernel's
/// `NetworkStatistics` reports a synthetic fake-IP destination and 0 bytes).
///
/// The outbound leg (app → tunnel) carries the real app PID and the cleartext
/// SNI; the inbound leg (written back by the proxy) is matched by the
/// direction-insensitive `FlowKey`, so both directions accumulate into one flow.
/// Non-tunnel packets are ignored here — they belong to the proxy's upstream
/// relay on the physical interface, deduplicated separately.
public struct TunneledFlowReconstructor: Sendable {
    /// One captured packet seen on a tunnel (or physical) interface, abstracted
    /// from the PKTAP layer so this unit stays pure and testable.
    public struct TunneledPacket: Sendable {
        public let onTunnel: Bool
        public let pid: Int32
        public let outbound: Bool
        public let fiveTuple: FiveTuple
        public let payloadLength: Int
        public let sni: String?

        public init(
            onTunnel: Bool,
            pid: Int32,
            outbound: Bool,
            fiveTuple: FiveTuple,
            payloadLength: Int,
            sni: String?
        ) {
            self.onTunnel = onTunnel
            self.pid = pid
            self.outbound = outbound
            self.fiveTuple = fiveTuple
            self.payloadLength = payloadLength
            self.sni = sni
        }
    }

    /// A reconstructed tunneled flow: who, where (domain + fake handle), how much.
    public struct ReconstructedFlow: Sendable, Equatable {
        public let flowKey: FlowKey
        public var pid: Int32
        public var domain: String?
        public var fakeDestination: Endpoint
        public var bytesOut: UInt64
        public var bytesIn: UInt64
    }

    private var flowsByKey: [FlowKey: ReconstructedFlow] = [:]

    public init() {}

    /// Folds a packet into its flow. Outbound packets are authoritative for the
    /// app PID, domain (SNI), and the fake destination; both directions add to
    /// the byte totals.
    public mutating func ingest(_ packet: TunneledPacket) {
        guard packet.onTunnel else { return }
        let key = packet.fiveTuple.flowKey
        let bytes = UInt64(max(0, packet.payloadLength))

        if var flow = flowsByKey[key] {
            if packet.outbound {
                flow.bytesOut &+= bytes
                flow.pid = packet.pid
                if let sni = packet.sni { flow.domain = sni }
                flow.fakeDestination = packet.fiveTuple.destination
            } else {
                flow.bytesIn &+= bytes
            }
            flowsByKey[key] = flow
        } else {
            flowsByKey[key] = ReconstructedFlow(
                flowKey: key,
                pid: packet.pid,
                domain: packet.outbound ? packet.sni : nil,
                fakeDestination: packet.outbound ? packet.fiveTuple.destination : packet.fiveTuple.source,
                bytesOut: packet.outbound ? bytes : 0,
                bytesIn: packet.outbound ? 0 : bytes
            )
        }
    }

    /// All reconstructed flows seen so far.
    public func flows() -> [ReconstructedFlow] {
        Array(flowsByKey.values)
    }
}
