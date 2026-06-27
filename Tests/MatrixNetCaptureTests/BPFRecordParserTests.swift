import Testing
@testable import MatrixNetCapture

@Suite("BPFRecordParser")
struct BPFRecordParserTests {
    /// Builds one bpf record: an 18-byte header (caplen + hdrlen set) + payload,
    /// padded to a 4-byte boundary.
    private func record(_ payload: [UInt8], headerLength: Int = 18) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: headerLength)
        let caplen = UInt32(payload.count)
        for index in 0 ..< 4 {
            bytes[8 + index] = UInt8(caplen >> (UInt32(index) * 8) & 0xFF)
        }
        bytes[16] = UInt8(headerLength & 0xFF)
        bytes[17] = UInt8(headerLength >> 8 & 0xFF)
        bytes += payload
        while !bytes.count.isMultiple(of: 4) {
            bytes.append(0)
        }
        return bytes
    }

    @Test("extracts a single packet")
    func single() {
        let buffer = record([1, 2, 3, 4, 5])
        let packets = BPFRecordParser.packets(in: buffer, count: buffer.count)
        #expect(packets == [[1, 2, 3, 4, 5]])
    }

    @Test("extracts the per-record microsecond timestamp from bh_tstamp")
    func timestamp() {
        var buffer = record([1, 2, 3])
        // bh_tstamp.tv_sec = 10 (offset 0), tv_usec = 500_000 (offset 4)
        let seconds: UInt32 = 10
        let micros: UInt32 = 500_000
        for index in 0 ..< 4 {
            buffer[index] = UInt8(seconds >> (UInt32(index) * 8) & 0xFF)
            buffer[4 + index] = UInt8(micros >> (UInt32(index) * 8) & 0xFF)
        }
        let records = BPFRecordParser.records(in: buffer, count: buffer.count)
        #expect(records.count == 1)
        #expect(records.first?.timestamp == 10.5)
        #expect(records.first?.bytes == [1, 2, 3])
    }

    @Test("extracts multiple word-aligned records")
    func multiple() {
        let buffer = record([0xAA, 0xBB, 0xCC]) + record([0xDD, 0xDD]) + record([0x01])
        let packets = BPFRecordParser.packets(in: buffer, count: buffer.count)
        #expect(packets == [[0xAA, 0xBB, 0xCC], [0xDD, 0xDD], [0x01]])
    }

    @Test("honours the count even if the buffer is larger")
    func respectsCount() {
        let first = record([1, 2, 3, 4])
        let buffer = first + record([9, 9, 9, 9])
        let packets = BPFRecordParser.packets(in: buffer, count: first.count)
        #expect(packets == [[1, 2, 3, 4]])
    }

    @Test("stops cleanly on a truncated trailing record")
    func truncated() {
        var buffer = record([1, 2, 3])
        buffer += [0, 0, 0] // a partial header, not a full record
        let packets = BPFRecordParser.packets(in: buffer, count: buffer.count)
        #expect(packets == [[1, 2, 3]])
    }

    @Test("returns nothing for an empty or sub-header buffer", arguments: [0, 4, 17])
    func tooSmall(_ count: Int) {
        #expect(BPFRecordParser.packets(in: [UInt8](repeating: 0, count: count), count: count).isEmpty)
    }
}
