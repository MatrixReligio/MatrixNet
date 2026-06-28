/// Passively measured quality of one TCP flow. All measurements are best-effort:
/// a value is `nil` when the packets needed to compute it were not observed (for
/// example, the connection was already open before capture started, so no SYN was
/// seen). Times are in milliseconds.
public struct FlowQuality: Sendable, Equatable {
    /// SYN → SYN-ACK round trip — at the client this is the full client↔server
    /// path RTT (Wireshark's iRTT). `nil` if the handshake was not captured.
    public let handshakeRTTms: Double?
    /// Count of data segments that re-sent already-seen bytes — a sign of loss.
    public let retransmits: Int
    /// Count of data segments that arrived ahead of a sequence-number gap —
    /// reordering or loss-then-recovery (most meaningful on the inbound side).
    public let outOfOrder: Int
    /// SYN → first outbound payload byte — how long until the app sent its first
    /// request. `nil` if either was not captured.
    public let setupMs: Double?

    public init(handshakeRTTms: Double?, retransmits: Int, outOfOrder: Int, setupMs: Double?) {
        self.handshakeRTTms = handshakeRTTms
        self.retransmits = retransmits
        self.outOfOrder = outOfOrder
        self.setupMs = setupMs
    }
}

/// Accumulates per-segment observations for a single TCP flow into a `FlowQuality`.
/// Pure and incremental: feed every segment (either direction) with its capture
/// timestamp; read `quality` at any time. Sequence comparisons are 32-bit
/// wraparound-aware (`Int32(bitPattern:)`), matching `StreamReassembler`.
public struct FlowQualityTracker: Sendable {
    private var synTs: UInt64?
    private var synAckTs: UInt64?
    private var firstOutboundDataTs: UInt64?
    private var maxSeqEnd: [Bool: UInt32] = [:]
    private var retransmits = 0
    private var outOfOrder = 0

    public init() {}

    public mutating func ingest(timestampMicros: UInt64, inbound: Bool, segment: TCPSegment) {
        if segment.flags.contains(.syn) {
            if segment.flags.contains(.ack) {
                if synAckTs == nil { synAckTs = timestampMicros }
            } else if synTs == nil {
                synTs = timestampMicros
            }
        }

        guard segment.payloadLength > 0 else { return }
        if !inbound, firstOutboundDataTs == nil { firstOutboundDataTs = timestampMicros }

        // SYN and FIN each consume one sequence number (RFC 9293 §3.4), so a
        // segment that carries payload alongside a SYN (TCP Fast Open) or FIN
        // advances the next expected sequence by one extra. Without this the
        // following in-order segment looks like it skipped a byte and would be
        // miscounted as out-of-order.
        let controlBytes = UInt32((segment.flags.contains(.syn) ? 1 : 0) + (segment.flags.contains(.fin) ? 1 : 0))
        let end = segment.sequence &+ UInt32(segment.payloadLength) &+ controlBytes
        if let prior = maxSeqEnd[inbound] {
            let delta = Int32(bitPattern: segment.sequence &- prior)
            if delta < 0 {
                retransmits += 1
            } else if delta > 0 {
                outOfOrder += 1
            }
            if Int32(bitPattern: end &- prior) > 0 { maxSeqEnd[inbound] = end }
        } else {
            maxSeqEnd[inbound] = end
        }
    }

    public var quality: FlowQuality {
        FlowQuality(
            handshakeRTTms: handshakeRTT,
            retransmits: retransmits,
            outOfOrder: outOfOrder,
            setupMs: setup
        )
    }

    private var handshakeRTT: Double? {
        guard let synTs, let synAckTs, synAckTs >= synTs else { return nil }
        return Double(synAckTs - synTs) / 1000.0
    }

    private var setup: Double? {
        guard let synTs, let firstOutboundDataTs, firstOutboundDataTs >= synTs else { return nil }
        return Double(firstOutboundDataTs - synTs) / 1000.0
    }
}
