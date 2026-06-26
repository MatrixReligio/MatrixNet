import Testing
@testable import MatrixNetDissection

@Suite("StreamReassembler")
struct StreamReassemblerTests {
    @Test("concatenates in-order segments")
    func inOrder() {
        var stream = StreamReassembler()
        stream.add(sequenceNumber: 1000, payload: [1, 2, 3])
        stream.add(sequenceNumber: 1003, payload: [4, 5])
        stream.add(sequenceNumber: 1005, payload: [6])
        #expect(stream.bytes == [1, 2, 3, 4, 5, 6])
        #expect(!stream.hasGaps)
    }

    @Test("reorders out-of-order segments")
    func outOfOrder() {
        var stream = StreamReassembler()
        stream.add(sequenceNumber: 1005, payload: [6])
        stream.add(sequenceNumber: 1000, payload: [1, 2, 3])
        stream.add(sequenceNumber: 1003, payload: [4, 5])
        #expect(stream.bytes == [1, 2, 3, 4, 5, 6])
    }

    @Test("deduplicates retransmitted segments")
    func retransmission() {
        var stream = StreamReassembler()
        stream.add(sequenceNumber: 1000, payload: [1, 2, 3])
        stream.add(sequenceNumber: 1000, payload: [1, 2, 3])
        stream.add(sequenceNumber: 1003, payload: [4])
        #expect(stream.bytes == [1, 2, 3, 4])
    }

    @Test("merges overlapping segments without duplicating bytes")
    func overlap() {
        var stream = StreamReassembler()
        stream.add(sequenceNumber: 1000, payload: [1, 2, 3, 4])
        stream.add(sequenceNumber: 1002, payload: [3, 4, 5, 6]) // overlaps last two
        #expect(stream.bytes == [1, 2, 3, 4, 5, 6])
    }

    @Test("stops at a gap and reports it")
    func gap() {
        var stream = StreamReassembler()
        stream.add(sequenceNumber: 1000, payload: [1, 2, 3])
        stream.add(sequenceNumber: 1010, payload: [9]) // gap between 1003 and 1010
        #expect(stream.bytes == [1, 2, 3])
        #expect(stream.hasGaps)
    }

    @Test("ignores empty (pure-ACK) segments")
    func emptySegments() {
        var stream = StreamReassembler()
        stream.add(sequenceNumber: 1000, payload: [])
        stream.add(sequenceNumber: 1000, payload: [1, 2])
        #expect(stream.bytes == [1, 2])
    }

    @Test("handles 32-bit sequence-number wraparound")
    func wraparound() {
        var stream = StreamReassembler()
        let base = UInt32.max - 1 // 0xFFFFFFFE
        stream.add(sequenceNumber: base, payload: [1, 2, 3]) // covers FFFFFFFE, FFFFFFFF, 00000000
        stream.add(sequenceNumber: 1, payload: [4, 5]) // continues at wrapped seq 1
        #expect(stream.bytes == [1, 2, 3, 4, 5])
        #expect(!stream.hasGaps)
    }
}
