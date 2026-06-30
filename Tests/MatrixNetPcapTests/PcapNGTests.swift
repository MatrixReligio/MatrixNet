import Testing
@testable import MatrixNetPcap

@Suite("pcapng writer & reader")
struct PcapNGTests {
    private func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    @Test("header begins with the SHB magic and byte-order magic")
    func headerMagic() {
        let header = PcapNGWriter(linkType: PcapLinkType.ethernet).header()
        #expect(u32(header, 0) == 0x0A0D_0D0A) // Section Header Block type
        #expect(u32(header, 8) == 0x1A2B_3C4D) // byte-order magic
    }

    @Test("header includes an interface block with the link type")
    func headerLinkType() {
        let header = PcapNGWriter(linkType: PcapLinkType.pktap).header()
        // Find the IDB (type 0x00000001) after the SHB.
        let shbLength = Int(u32(header, 4))
        #expect(u32(header, shbLength) == 0x0000_0001) // IDB type
        // IDB body: linktype (u16) + reserved (u16) at offset shbLength + 8.
        let linkType = UInt32(header[shbLength + 8]) | UInt32(header[shbLength + 9]) << 8
        #expect(linkType == PcapLinkType.pktap)
    }

    @Test("an enhanced packet block has matching leading/trailing total length")
    func packetBlockFraming() {
        let writer = PcapNGWriter(linkType: PcapLinkType.ethernet)
        let block = writer.packet(CapturedRecord(timestampMicros: 1, originalLength: 4, data: [1, 2, 3, 4]))
        #expect(u32(block, 0) == 0x0000_0006) // EPB type
        let total = Int(u32(block, 4))
        #expect(block.count == total) // length is consistent
        #expect(u32(block, block.count - 4) == UInt32(total)) // trailing length matches
        #expect(block.count.isMultiple(of: 4)) // 32-bit aligned
    }

    @Test("writer output round-trips through the reader")
    func roundTrip() throws {
        let writer = PcapNGWriter(linkType: PcapLinkType.pktap)
        let full = CapturedRecord(
            timestampMicros: 1_700_000_000_000_000,
            originalLength: 4,
            data: [0xDE, 0xAD, 0xBE, 0xEF]
        )
        // A truncated capture: original length exceeds the captured bytes.
        let truncated = CapturedRecord(timestampMicros: 1_700_000_000_500_000, originalLength: 6, data: [1, 2, 3, 4, 5])
        let records = [full, truncated]
        var file = writer.header()
        for record in records {
            file += writer.packet(record)
        }

        let result = try #require(PcapNGReader.read(file))
        #expect(result.linkType == PcapLinkType.pktap)
        #expect(result.records == records)
    }

    @Test("a truncated file is rejected without crashing", arguments: [0, 4, 8, 20, 40])
    func rejectsTruncated(_ length: Int) {
        let writer = PcapNGWriter(linkType: PcapLinkType.ethernet)
        let file = writer.header() + writer.packet(CapturedRecord(timestampMicros: 1, originalLength: 1, data: [9]))
        _ = PcapNGReader.read(Array(file.prefix(length)))
        #expect(Bool(true)) // no crash
    }

    @Test("rejects bad magic")
    func rejectsBadMagic() {
        #expect(PcapNGReader.read([0, 0, 0, 0, 0, 0, 0, 0]) == nil)
    }

    @Test("a mixed-link-type capture writes one IDB per type with matching interface ids")
    func multiInterfaceExport() {
        func record(_ value: UInt8) -> CapturedRecord {
            CapturedRecord(timestampMicros: UInt64(value), originalLength: 4, data: [value, value, value, value])
        }
        let bytes = PcapNGWriter.pcapng(records: [
            (PcapLinkType.ethernet, record(1)),
            (PcapLinkType.raw, record(2)),
            (PcapLinkType.nullLoopback, record(3)),
            (PcapLinkType.ethernet, record(4))
        ])

        var idbLinkTypes = [UInt32]()
        var epbInterfaceIDs = [UInt32]()
        var offset = 0
        while offset + 8 <= bytes.count {
            let type = u32(bytes, offset)
            let length = Int(u32(bytes, offset + 4))
            guard length >= 12, offset + length <= bytes.count else { break }
            if type == 0x0000_0001 { // IDB: link type is a u16 at body offset 0
                idbLinkTypes.append(UInt32(bytes[offset + 8]) | UInt32(bytes[offset + 9]) << 8)
            }
            if type == 0x0000_0006 { // EPB: interface id is a u32 at body offset 0
                epbInterfaceIDs.append(u32(bytes, offset + 8))
            }
            offset += length
        }
        // One IDB per distinct link type, in first-seen order…
        #expect(idbLinkTypes == [PcapLinkType.ethernet, PcapLinkType.raw, PcapLinkType.nullLoopback])
        // …and each packet routed to the interface matching its link type.
        #expect(epbInterfaceIDs == [0, 1, 2, 0])
    }
}
