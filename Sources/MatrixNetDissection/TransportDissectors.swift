import MatrixNetModel

/// Dissects a TCP header (RFC 9293), decoding the flag bits and honouring the
/// data-offset field for the payload boundary.
enum TCPDissector {
    static func dissect(
        _ bytes: [UInt8],
        at start: Int,
        segmentEnd: Int,
        detailed: Bool
    ) throws -> TransportLayerResult {
        var reader = ByteReader(bytes, offset: start)
        let sourcePort = try reader.readUInt16()
        let destinationPort = try reader.readUInt16()
        let sequence = try reader.readUInt32()
        let acknowledgement = try reader.readUInt32()
        let offsetAndFlags = try reader.readUInt16()
        let dataOffsetWords = Int(offsetAndFlags >> 12)
        let flags = offsetAndFlags & 0x01FF
        let window = try reader.readUInt16()
        _ = try reader.readUInt16() // checksum (not validated)
        _ = try reader.readUInt16() // urgent pointer

        let headerLength = max(20, dataOffsetWords * 4)
        let payloadOffset = start + headerLength
        let payloadLength = max(0, segmentEnd - payloadOffset)

        let fields: [DissectionField] = detailed ? [
            DissectionField(name: "Source Port", value: "\(sourcePort)", byteRange: start ..< start + 2),
            DissectionField(name: "Destination Port", value: "\(destinationPort)", byteRange: start + 2 ..< start + 4),
            DissectionField(name: "Sequence Number", value: "\(sequence)", byteRange: start + 4 ..< start + 8),
            DissectionField(name: "Acknowledgement", value: "\(acknowledgement)", byteRange: start + 8 ..< start + 12),
            DissectionField(name: "Flags", value: tcpFlagsDescription(flags), byteRange: start + 12 ..< start + 14),
            DissectionField(name: "Window", value: "\(window)", byteRange: start + 14 ..< start + 16)
        ] : []
        let node = DissectionNode(
            label: "Transmission Control Protocol",
            shortName: "TCP",
            fields: fields,
            byteRange: start ..< start + 20
        )
        return TransportLayerResult(
            node: node,
            sourcePort: sourcePort,
            destinationPort: destinationPort,
            payloadOffset: payloadOffset,
            payloadEnd: payloadOffset + payloadLength,
            tcpSegment: TCPSegment(
                flags: TCPFlags(rawValue: flags),
                sequence: sequence,
                acknowledgement: acknowledgement,
                payloadLength: payloadLength
            )
        )
    }

    private static func tcpFlagsDescription(_ flags: UInt16) -> String {
        let names: [(UInt16, String)] = [
            (0x100, "NS"), (0x080, "CWR"), (0x040, "ECE"), (0x020, "URG"),
            (0x010, "ACK"), (0x008, "PSH"), (0x004, "RST"), (0x002, "SYN"), (0x001, "FIN")
        ]
        let set = names.filter { flags & $0.0 != 0 }.map(\.1)
        return set.isEmpty ? "none" : set.joined(separator: ", ")
    }
}

/// Dissects a UDP header (RFC 768).
enum UDPDissector {
    static let headerLength = 8

    static func dissect(
        _ bytes: [UInt8],
        at start: Int,
        segmentEnd: Int,
        detailed: Bool
    ) throws -> TransportLayerResult {
        var reader = ByteReader(bytes, offset: start)
        let sourcePort = try reader.readUInt16()
        let destinationPort = try reader.readUInt16()
        let length = try reader.readUInt16()
        _ = try reader.readUInt16() // checksum (not validated)

        let fields: [DissectionField] = detailed ? [
            DissectionField(name: "Source Port", value: "\(sourcePort)", byteRange: start ..< start + 2),
            DissectionField(name: "Destination Port", value: "\(destinationPort)", byteRange: start + 2 ..< start + 4),
            DissectionField(name: "Length", value: "\(length)", byteRange: start + 4 ..< start + 6)
        ] : []
        let node = DissectionNode(
            label: "User Datagram Protocol",
            shortName: "UDP",
            fields: fields,
            byteRange: start ..< start + headerLength
        )
        // The UDP length field covers the 8-byte header + payload. Trust it only
        // when sane, clamped to the IP datagram end (which itself is clamped to the
        // buffer); a bogus/zero length falls back to the IP payload end.
        let datagramEnd = Int(length) >= headerLength ? min(start + Int(length), segmentEnd) : segmentEnd
        return TransportLayerResult(
            node: node,
            sourcePort: sourcePort,
            destinationPort: destinationPort,
            payloadOffset: start + headerLength,
            payloadEnd: max(start + headerLength, datagramEnd),
            tcpSegment: nil
        )
    }
}
