/// Parses pcapng bytes produced by `PcapNGWriter` (little-endian only — enough
/// for round-tripping our own captures and verifying interop). Unknown blocks
/// are skipped; malformed input yields `nil` rather than crashing.
public enum PcapNGReader {
    public struct Result: Equatable {
        public let linkType: UInt32
        public let records: [CapturedRecord]
    }

    public static func read(_ bytes: [UInt8]) -> Result? {
        func u32(_ offset: Int) -> UInt32? {
            guard offset >= 0, offset + 4 <= bytes.count else { return nil }
            return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
        }

        // Require a Section Header Block with the little-endian byte-order magic.
        guard u32(0) == 0x0A0D_0D0A, u32(8) == 0x1A2B_3C4D else { return nil }

        var linkType: UInt32?
        var records = [CapturedRecord]()
        var offset = 0

        while let blockType = u32(offset), let blockLength = u32(offset + 4) {
            let length = Int(blockLength)
            guard length >= 12, offset + length <= bytes.count else { break }

            switch blockType {
            case 0x0000_0001: // Interface Description Block
                linkType = u32(offset + 8).map { $0 & 0xFFFF }
            case 0x0000_0006: // Enhanced Packet Block
                if let record = readEnhancedPacket(bytes, at: offset, u32: u32) {
                    records.append(record)
                }
            default:
                break // Section header and other blocks are skipped.
            }
            offset += length
        }

        guard let linkType else { return nil }
        return Result(linkType: linkType, records: records)
    }

    private static func readEnhancedPacket(
        _ bytes: [UInt8],
        at offset: Int,
        u32: (Int) -> UInt32?
    ) -> CapturedRecord? {
        guard let timestampHigh = u32(offset + 12),
              let timestampLow = u32(offset + 16),
              let capturedLength = u32(offset + 20),
              let originalLength = u32(offset + 24)
        else {
            return nil
        }
        let dataStart = offset + 28
        let captured = Int(capturedLength)
        guard dataStart + captured <= bytes.count else { return nil }
        return CapturedRecord(
            timestampMicros: UInt64(timestampHigh) << 32 | UInt64(timestampLow),
            originalLength: Int(originalLength),
            data: Array(bytes[dataStart ..< dataStart + captured])
        )
    }
}
