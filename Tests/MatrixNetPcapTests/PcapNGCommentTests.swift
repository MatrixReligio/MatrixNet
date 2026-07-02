import Testing
@testable import MatrixNetPcap

@Suite("PcapNG comments")
struct PcapNGCommentTests {
    @Test("a packet comment round-trips through write then read")
    func roundTrip() throws {
        let writer = PcapNGWriter(linkType: PcapLinkType.ethernet)
        var bytes = writer.header()
        let record = CapturedRecord(
            timestampMicros: 1_000_000,
            originalLength: 4,
            data: [0xDE, 0xAD, 0xBE, 0xEF],
            comment: "Safari (pid 42)"
        )
        bytes += writer.packet(record)

        let result = try #require(PcapNGReader.read(bytes))
        #expect(result.records.count == 1)
        #expect(result.records.first?.comment == "Safari (pid 42)")
        #expect(result.records.first?.data == [0xDE, 0xAD, 0xBE, 0xEF])
    }

    @Test("no comment writes a plain block that reads back nil")
    func noComment() throws {
        let writer = PcapNGWriter(linkType: PcapLinkType.ethernet)
        var bytes = writer.header()
        bytes += writer.packet(CapturedRecord(timestampMicros: 5, originalLength: 2, data: [1, 2]))

        let result = try #require(PcapNGReader.read(bytes))
        #expect(result.records.first?.comment == nil)
        #expect(result.records.first?.data == [1, 2])
    }

    @Test("an oversized comment truncates to the declared TLV length, keeping the file parseable")
    func oversizedComment() throws {
        let writer = PcapNGWriter(linkType: PcapLinkType.ethernet)
        var bytes = writer.header()
        let long = String(repeating: "a", count: 70_000)
        bytes += writer.packet(CapturedRecord(
            timestampMicros: 1,
            originalLength: 4,
            data: [1, 2, 3, 4],
            comment: long
        ))
        bytes += writer.packet(CapturedRecord(timestampMicros: 2, originalLength: 2, data: [9, 9]))

        let result = try #require(PcapNGReader.read(bytes))
        #expect(result.records.count == 2)
        #expect(result.records.first?.comment == String(repeating: "a", count: 65535))
        #expect(result.records.last?.data == [9, 9])
    }

    @Test("out-of-range original lengths clamp instead of trapping")
    func extremeOriginalLength() throws {
        let writer = PcapNGWriter(linkType: PcapLinkType.ethernet)
        var bytes = writer.header()
        bytes += writer.packet(CapturedRecord(timestampMicros: 1, originalLength: Int.max, data: [1]))
        bytes += writer.packet(CapturedRecord(timestampMicros: 2, originalLength: -1, data: [2]))

        let result = try #require(PcapNGReader.read(bytes))
        #expect(result.records.first?.originalLength == Int(UInt32.max))
        #expect(result.records.last?.originalLength == 0)
    }

    @Test("a comment length running past the block does not read across the boundary")
    func corruptCommentLength() throws {
        let writer = PcapNGWriter(linkType: PcapLinkType.ethernet)
        var bytes = writer.header()
        bytes += writer.packet(CapturedRecord(
            timestampMicros: 1,
            originalLength: 4,
            data: [0, 0, 0, 0],
            comment: "abcd"
        ))
        // A second plain block follows, so an over-long comment would otherwise
        // read into it.
        bytes += writer.packet(CapturedRecord(timestampMicros: 2, originalLength: 2, data: [9, 9]))

        // Corrupt the opt_comment length (2 bytes before the "abcd" value) to 0xFFFF.
        let value: [UInt8] = Array("abcd".utf8)
        let valueStart = try #require((0 ..< bytes.count - value.count).first {
            Array(bytes[$0 ..< $0 + value.count]) == value
        })
        bytes[valueStart - 2] = 0xFF
        bytes[valueStart - 1] = 0xFF

        // Must not crash, must not surface a bogus comment from the next block.
        let result = try #require(PcapNGReader.read(bytes))
        #expect(result.records.first?.comment == nil)
    }
}
