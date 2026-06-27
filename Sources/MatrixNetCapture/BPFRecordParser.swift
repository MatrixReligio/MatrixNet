/// Splits a BPF read() buffer into its individual packet records.
///
/// Each record is `struct bpf_hdr` (BPF_TIMEVAL `bh_tstamp` (8) + `bh_caplen`
/// (u32) + `bh_datalen` (u32) + `bh_hdrlen` (u16)) followed by the captured
/// bytes. The next record starts at `BPF_WORDALIGN(bh_hdrlen + bh_caplen)`.
/// Values are host byte order. Malformed/truncated buffers stop cleanly.
public enum BPFRecordParser {
    private enum Offset {
        static let timestampSeconds = 0 // bh_tstamp.tv_sec: int32
        static let timestampMicros = 4 // bh_tstamp.tv_usec: int32
        static let capturedLength = 8 // bh_caplen: uint32
        static let headerLength = 16 // bh_hdrlen: uint16
        static let minimum = 18 // smallest bpf_hdr
    }

    /// One captured packet plus its kernel capture time. `bh_tstamp` carries
    /// microsecond resolution, so packets in the same `read()` are distinguished.
    public struct Record: Equatable, Sendable {
        public let timestamp: Double // seconds since the Unix epoch
        public let bytes: [UInt8]
        public init(timestamp: Double, bytes: [UInt8]) {
            self.timestamp = timestamp
            self.bytes = bytes
        }
    }

    static func wordAlign(_ value: Int) -> Int {
        (value + 3) & ~3
    }

    /// Returns each captured packet with its per-record `bh_tstamp` timestamp.
    public static func records(in buffer: [UInt8], count: Int) -> [Record] {
        let limit = min(count, buffer.count)
        var records = [Record]()
        var offset = 0

        while offset + Offset.minimum <= limit {
            let seconds = u32(buffer, offset + Offset.timestampSeconds)
            let micros = u32(buffer, offset + Offset.timestampMicros)
            let timestamp = Double(seconds) + Double(micros) / 1_000_000
            let capturedLength = Int(u32(buffer, offset + Offset.capturedLength))
            let headerLength = Int(u16(buffer, offset + Offset.headerLength))
            guard headerLength >= Offset.minimum else { break }

            // capturedLength is a UInt32 promoted to Int (always >= 0). Check the
            // bound in overflow-safe form so a huge value can't wrap.
            let packetStart = offset + headerLength
            guard capturedLength <= limit - packetStart else { break } // truncated record
            let packetEnd = packetStart + capturedLength

            records.append(Record(timestamp: timestamp, bytes: Array(buffer[packetStart ..< packetEnd])))

            let stride = wordAlign(headerLength + capturedLength)
            guard stride > 0 else { break } // guard against a zero-length stride
            offset += stride
        }
        return records
    }

    /// Returns just each captured packet's bytes (timestamps discarded).
    public static func packets(in buffer: [UInt8], count: Int) -> [[UInt8]] {
        records(in: buffer, count: count).map(\.bytes)
    }

    private static func u32(_ buffer: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(buffer[offset]) | UInt32(buffer[offset + 1]) << 8
            | UInt32(buffer[offset + 2]) << 16 | UInt32(buffer[offset + 3]) << 24
    }

    private static func u16(_ buffer: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(buffer[offset]) | UInt16(buffer[offset + 1]) << 8
    }
}
