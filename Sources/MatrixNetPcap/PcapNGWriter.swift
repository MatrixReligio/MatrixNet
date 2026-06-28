/// Writes the pcapng blocks needed to interoperate with Wireshark/tshark:
/// a Section Header Block, one Interface Description Block, and an Enhanced
/// Packet Block per captured packet. All values are little-endian.
public struct PcapNGWriter {
    public let linkType: UInt32
    public let snapLength: UInt32

    private static let sectionHeaderType: UInt32 = 0x0A0D_0D0A
    private static let interfaceDescriptionType: UInt32 = 0x0000_0001
    private static let enhancedPacketType: UInt32 = 0x0000_0006
    private static let byteOrderMagic: UInt32 = 0x1A2B_3C4D

    public init(linkType: UInt32, snapLength: UInt32 = 262_144) {
        self.linkType = linkType
        self.snapLength = snapLength
    }

    /// The section header + interface description that begin every pcapng file.
    public func header() -> [UInt8] {
        sectionHeaderBlock() + interfaceDescriptionBlock()
    }

    /// An Enhanced Packet Block for one captured packet (interface 0), with an
    /// optional `opt_comment` carrying the owning process.
    public func packet(_ record: CapturedRecord) -> [UInt8] {
        let paddedDataLength = (record.data.count + 3) & ~3
        let options = optionsBlock(comment: record.comment)
        // type+len(8) + interfaceID+tsHigh+tsLow+capLen+origLen(20) + data + options + trailing(4)
        let totalLength = UInt32(32 + paddedDataLength + options.count)
        var writer = LittleEndianWriter()
        writer.u32(Self.enhancedPacketType)
        writer.u32(totalLength)
        writer.u32(0) // interface ID
        writer.u32(UInt32(record.timestampMicros >> 32))
        writer.u32(UInt32(record.timestampMicros & 0xFFFF_FFFF))
        writer.u32(UInt32(record.data.count))
        writer.u32(UInt32(record.originalLength))
        writer.raw(record.data)
        writer.pad32()
        writer.raw(options)
        writer.u32(totalLength)
        return writer.bytes
    }

    /// The block options: an `opt_comment` (code 1) plus `opt_endofopt` (code 0),
    /// or empty when there is no comment (so plain blocks are byte-for-byte as
    /// before).
    private func optionsBlock(comment: String?) -> [UInt8] {
        guard let comment, !comment.isEmpty else { return [] }
        let value = Array(comment.utf8)
        var writer = LittleEndianWriter()
        writer.u16(1) // opt_comment
        writer.u16(UInt16(truncatingIfNeeded: value.count))
        writer.raw(value)
        writer.pad32()
        writer.u16(0) // opt_endofopt
        writer.u16(0)
        return writer.bytes
    }

    private func sectionHeaderBlock() -> [UInt8] {
        var writer = LittleEndianWriter()
        writer.u32(Self.sectionHeaderType)
        writer.u32(28) // total length (no options)
        writer.u32(Self.byteOrderMagic)
        writer.u16(1) // major version
        writer.u16(0) // minor version
        writer.u32(0xFFFF_FFFF) // section length: unknown (-1)
        writer.u32(0xFFFF_FFFF)
        writer.u32(28) // trailing total length
        return writer.bytes
    }

    private func interfaceDescriptionBlock() -> [UInt8] {
        var writer = LittleEndianWriter()
        writer.u32(Self.interfaceDescriptionType)
        writer.u32(20) // total length (no options)
        writer.u16(UInt16(truncatingIfNeeded: linkType))
        writer.u16(0) // reserved
        writer.u32(snapLength)
        writer.u32(20) // trailing total length
        return writer.bytes
    }
}
