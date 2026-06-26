/// Reassembles one direction of a TCP byte stream from (possibly out-of-order,
/// duplicated, or overlapping) segments, using sequence numbers with correct
/// 32-bit wraparound handling. The first segment's sequence number anchors the
/// stream; bytes are produced contiguously up to the first gap.
public struct StreamReassembler {
    /// Earliest sequence number seen (wraparound-aware), anchoring the stream.
    private var base: UInt32?
    /// Absolute sequence number -> payload. Keyed by sequence so retransmissions
    /// of the same segment collapse; ordering is resolved at assembly time.
    private var segments: [UInt32: [UInt8]] = [:]

    public init() {}

    /// Adds a segment. Empty payloads (pure ACKs) are ignored. Segments may
    /// arrive out of order; the earliest sequence number re-anchors the stream.
    public mutating func add(sequenceNumber: UInt32, payload: [UInt8]) {
        guard !payload.isEmpty else { return }
        // Keep the longest payload seen at this sequence (retransmit/overlap).
        if let existing = segments[sequenceNumber], existing.count >= payload.count {
            // keep existing
        } else {
            segments[sequenceNumber] = payload
        }
        if let current = base {
            // Re-anchor if this segment is earlier than the current base.
            if Int32(bitPattern: sequenceNumber &- current) < 0 { base = sequenceNumber }
        } else {
            base = sequenceNumber
        }
    }

    /// The contiguous reassembled bytes from the stream start up to the first gap.
    public var bytes: [UInt8] {
        assemble().bytes
    }

    /// Whether any received data lies beyond a gap (i.e. data is missing).
    public var hasGaps: Bool {
        guard let base else { return false }
        let end = assemble().end
        return segments.keys.contains { ($0 &- base) > end }
    }

    /// Walks segments in stream order (offsets relative to `base`), returning the
    /// contiguous bytes and the offset just past them.
    private func assemble() -> (bytes: [UInt8], end: UInt32) {
        guard let base else { return ([], 0) }
        var result = [UInt8]()
        var cursor: UInt32 = 0
        let ordered = segments
            .map { (offset: $0.key &- base, payload: $0.value) }
            .sorted { $0.offset < $1.offset }
        for (offset, payload) in ordered {
            if offset > cursor { break } // gap
            let span = UInt32(payload.count)
            if offset == cursor {
                result += payload
                cursor = cursor &+ span
            } else {
                let overlap = cursor &- offset
                if overlap < span {
                    result += payload[Int(overlap)...]
                    cursor = offset &+ span
                }
            }
        }
        return (result, cursor)
    }
}
