/// Dissects a TCP header (RFC 9293), decoding the flag bits and honouring the
/// data-offset field for the payload boundary.
enum TCPDissector {
    static func dissect(_ bytes: [UInt8], at start: Int) throws -> TransportLayerResult {
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

        let fields = [
            DissectionField(name: "Source Port", value: "\(sourcePort)", byteRange: start ..< start + 2),
            DissectionField(name: "Destination Port", value: "\(destinationPort)", byteRange: start + 2 ..< start + 4),
            DissectionField(name: "Sequence Number", value: "\(sequence)", byteRange: start + 4 ..< start + 8),
            DissectionField(name: "Acknowledgement", value: "\(acknowledgement)", byteRange: start + 8 ..< start + 12),
            DissectionField(name: "Flags", value: tcpFlagsDescription(flags), byteRange: start + 12 ..< start + 14),
            DissectionField(name: "Window", value: "\(window)", byteRange: start + 14 ..< start + 16)
        ]
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
            payloadOffset: start + headerLength
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

    static func dissect(_ bytes: [UInt8], at start: Int) throws -> TransportLayerResult {
        var reader = ByteReader(bytes, offset: start)
        let sourcePort = try reader.readUInt16()
        let destinationPort = try reader.readUInt16()
        let length = try reader.readUInt16()
        _ = try reader.readUInt16() // checksum (not validated)

        let fields = [
            DissectionField(name: "Source Port", value: "\(sourcePort)", byteRange: start ..< start + 2),
            DissectionField(name: "Destination Port", value: "\(destinationPort)", byteRange: start + 2 ..< start + 4),
            DissectionField(name: "Length", value: "\(length)", byteRange: start + 4 ..< start + 6)
        ]
        let node = DissectionNode(
            label: "User Datagram Protocol",
            shortName: "UDP",
            fields: fields,
            byteRange: start ..< start + headerLength
        )
        return TransportLayerResult(
            node: node,
            sourcePort: sourcePort,
            destinationPort: destinationPort,
            payloadOffset: start + headerLength
        )
    }
}
