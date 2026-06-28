import MatrixNetModel

/// Dissects an IPv4 header (RFC 791), including variable-length options.
enum IPv4Dissector {
    static func dissect(_ bytes: [UInt8], at start: Int) throws -> NetworkLayerResult {
        var reader = ByteReader(bytes, offset: start)

        let versionAndIHL = try reader.readUInt8()
        let version = versionAndIHL >> 4
        let ihl = Int(versionAndIHL & 0x0F)
        let headerLength = ihl * 4
        guard version == 4, ihl >= 5 else { throw DissectionError.malformed }

        _ = try reader.readUInt8() // DSCP/ECN
        let totalLength = try reader.readUInt16()
        let identification = try reader.readUInt16()
        let flagsAndFragment = try reader.readUInt16()
        let timeToLive = try reader.readUInt8()
        let ipProtocol = try reader.readUInt8()
        _ = try reader.readUInt16() // header checksum (not validated)
        let sourceBytes = try reader.readBytes(4)
        let destinationBytes = try reader.readBytes(4)

        // Consume any options so a bogus IHL is rejected rather than over-read.
        if headerLength > 20 { try reader.skip(headerLength - 20) }

        guard let source = IPAddress(bytes: sourceBytes),
              let destination = IPAddress(bytes: destinationBytes)
        else {
            throw DissectionError.malformed
        }

        let flags = flagsAndFragment >> 13
        let fragmentOffset = flagsAndFragment & 0x1FFF
        let transport = TransportProtocol(ipProtocolNumber: ipProtocol)

        let fields = [
            DissectionField(name: "Version", value: "4", byteRange: start ..< start + 1),
            DissectionField(name: "Header Length", value: "\(headerLength) bytes", byteRange: start ..< start + 1),
            DissectionField(name: "Total Length", value: "\(totalLength)", byteRange: start + 2 ..< start + 4),
            DissectionField(
                name: "Identification",
                value: HexFormat.hex16(identification),
                byteRange: start + 4 ..< start + 6
            ),
            DissectionField(name: "Flags", value: ipv4FlagsDescription(flags), byteRange: start + 6 ..< start + 8),
            DissectionField(name: "Fragment Offset", value: "\(fragmentOffset)", byteRange: start + 6 ..< start + 8),
            DissectionField(name: "Time to Live", value: "\(timeToLive)", byteRange: start + 8 ..< start + 9),
            DissectionField(
                name: "Protocol",
                value: "\(transport.displayName) (\(ipProtocol))",
                byteRange: start + 9 ..< start + 10
            ),
            DissectionField(name: "Source", value: source.description, byteRange: start + 12 ..< start + 16),
            DissectionField(name: "Destination", value: destination.description, byteRange: start + 16 ..< start + 20)
        ]
        let node = DissectionNode(
            label: "Internet Protocol Version 4",
            shortName: "IPv4",
            fields: fields,
            byteRange: start ..< start + headerLength
        )
        return NetworkLayerResult(
            node: node,
            ipProtocol: ipProtocol,
            payloadOffset: start + headerLength,
            payloadEnd: min(start + Int(totalLength), bytes.count),
            source: source,
            destination: destination
        )
    }

    private static func ipv4FlagsDescription(_ flags: UInt16) -> String {
        var parts = [String]()
        if flags & 0b010 != 0 { parts.append("DF") }
        if flags & 0b001 != 0 { parts.append("MF") }
        return parts.isEmpty ? "none" : parts.joined(separator: ", ")
    }
}
