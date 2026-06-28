import Testing
@testable import MatrixNetModel

@Suite("FlowQualityTracker")
struct FlowQualityTrackerTests {
    private let syn = TCPSegment(flags: .syn, sequence: 100, acknowledgement: 0, payloadLength: 0)

    @Test("TCPFlags decompose a raw 16-bit field")
    func flags() {
        let flagSet: TCPFlags = [.syn, .ack]
        #expect(flagSet.contains(.syn))
        #expect(flagSet.contains(.ack))
        #expect(!flagSet.contains(.fin))
        #expect(flagSet.rawValue == 0x012)
    }

    @Test("handshake RTT is the SYN to SYN-ACK gap in milliseconds")
    func handshakeRTT() {
        var tracker = FlowQualityTracker()
        tracker.ingest(timestampMicros: 1_000_000, inbound: false, segment: syn)
        let synAck = TCPSegment(flags: [.syn, .ack], sequence: 5000, acknowledgement: 101, payloadLength: 0)
        tracker.ingest(timestampMicros: 1_020_000, inbound: true, segment: synAck)
        #expect(tracker.quality.handshakeRTTms == 20.0)
    }

    @Test("a re-sent data segment counts as a retransmit")
    func retransmit() {
        var tracker = FlowQualityTracker()
        let first = TCPSegment(flags: [.ack, .psh], sequence: 1000, acknowledgement: 1, payloadLength: 100)
        tracker.ingest(timestampMicros: 0, inbound: false, segment: first)
        // Same bytes sent again (seq behind the high-water mark) → retransmit.
        tracker.ingest(timestampMicros: 1, inbound: false, segment: first)
        #expect(tracker.quality.retransmits == 1)
        #expect(tracker.quality.outOfOrder == 0)
    }

    @Test("a data segment ahead of a gap counts as out-of-order")
    func outOfOrder() {
        var tracker = FlowQualityTracker()
        let s1 = TCPSegment(flags: .ack, sequence: 1000, acknowledgement: 1, payloadLength: 100)
        let s3 = TCPSegment(flags: .ack, sequence: 1200, acknowledgement: 1, payloadLength: 100) // 1100..1200 missing
        tracker.ingest(timestampMicros: 0, inbound: true, segment: s1)
        tracker.ingest(timestampMicros: 1, inbound: true, segment: s3)
        #expect(tracker.quality.outOfOrder == 1)
        #expect(tracker.quality.retransmits == 0)
    }

    @Test("in-order advance is neither retransmit nor out-of-order")
    func inOrder() {
        var tracker = FlowQualityTracker()
        let s1 = TCPSegment(flags: .ack, sequence: 1000, acknowledgement: 1, payloadLength: 100)
        let s2 = TCPSegment(flags: .ack, sequence: 1100, acknowledgement: 1, payloadLength: 100)
        tracker.ingest(timestampMicros: 0, inbound: true, segment: s1)
        tracker.ingest(timestampMicros: 1, inbound: true, segment: s2)
        #expect(tracker.quality.retransmits == 0)
        #expect(tracker.quality.outOfOrder == 0)
    }

    @Test("setup time is SYN to first outbound payload")
    func setup() {
        var tracker = FlowQualityTracker()
        let synAck = TCPSegment(flags: [.syn, .ack], sequence: 5000, acknowledgement: 101, payloadLength: 0)
        // Client sends its first request 5ms after the handshake completes.
        let request = TCPSegment(flags: [.ack, .psh], sequence: 101, acknowledgement: 5001, payloadLength: 517)
        tracker.ingest(timestampMicros: 1_000_000, inbound: false, segment: syn)
        tracker.ingest(timestampMicros: 1_020_000, inbound: true, segment: synAck)
        tracker.ingest(timestampMicros: 1_025_000, inbound: false, segment: request)
        #expect(tracker.quality.setupMs == 25.0)
    }

    @Test("no SYN observed yields nil handshake/setup but still counts retransmits")
    func midStream() {
        var tracker = FlowQualityTracker()
        let seg = TCPSegment(flags: .ack, sequence: 9000, acknowledgement: 1, payloadLength: 50)
        tracker.ingest(timestampMicros: 0, inbound: true, segment: seg)
        tracker.ingest(timestampMicros: 1, inbound: true, segment: seg) // retransmit
        #expect(tracker.quality.handshakeRTTms == nil)
        #expect(tracker.quality.setupMs == nil)
        #expect(tracker.quality.retransmits == 1)
    }

    @Test("sequence comparison handles 32-bit wraparound")
    func wraparound() {
        var tracker = FlowQualityTracker()
        let near = TCPSegment(flags: .ack, sequence: 0xFFFF_FF00, acknowledgement: 1, payloadLength: 0x200)
        tracker.ingest(timestampMicros: 0, inbound: false, segment: near) // end wraps past 0
        // Next in-order segment starts at the wrapped end (0x100) — not a retransmit.
        let afterWrap = TCPSegment(flags: .ack, sequence: 0x0000_0100, acknowledgement: 1, payloadLength: 0x100)
        tracker.ingest(timestampMicros: 1, inbound: false, segment: afterWrap)
        #expect(tracker.quality.retransmits == 0)
        #expect(tracker.quality.outOfOrder == 0)
    }

    @Test("a SYN carrying data (TCP Fast Open) consumes one sequence number")
    func synWithPayload() {
        var tracker = FlowQualityTracker()
        // TFO SYN with 100 bytes of early data; data occupies ISN+1 ... ISN+100.
        let tfoSyn = TCPSegment(flags: .syn, sequence: 1000, acknowledgement: 0, payloadLength: 100)
        // The next in-order segment therefore starts at ISN+1+100 = 1101.
        let nextData = TCPSegment(flags: [.ack, .psh], sequence: 1101, acknowledgement: 0, payloadLength: 200)
        tracker.ingest(timestampMicros: 0, inbound: false, segment: tfoSyn)
        tracker.ingest(timestampMicros: 1, inbound: false, segment: nextData)
        #expect(tracker.quality.outOfOrder == 0)
        #expect(tracker.quality.retransmits == 0)
    }

    @Test("a FIN carrying data consumes one sequence number")
    func finWithPayload() {
        var tracker = FlowQualityTracker()
        // FIN segment carrying its last 100 data bytes; it consumes one extra
        // sequence number for the FIN itself, so the high-water mark is seq+len+1.
        let finData = TCPSegment(flags: [.ack, .fin], sequence: 1000, acknowledgement: 0, payloadLength: 100)
        let afterFin = TCPSegment(flags: .ack, sequence: 1101, acknowledgement: 0, payloadLength: 20)
        tracker.ingest(timestampMicros: 0, inbound: true, segment: finData)
        tracker.ingest(timestampMicros: 1, inbound: true, segment: afterFin)
        #expect(tracker.quality.outOfOrder == 0)
        #expect(tracker.quality.retransmits == 0)
    }
}
