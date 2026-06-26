import MatrixNetModel

/// Dissects a fixed IPv6 header (RFC 8200).
///
/// Phase 1 treats the Next Header field as the transport protocol directly;
/// extension-header chains are not yet walked (tracked for a later phase).
enum IPv6Dissector {
    static let headerLength = 40

    static func dissect(_ bytes: [UInt8], at start: Int) throws -> NetworkLayerResult {
        var reader = ByteReader(bytes, offset: start)

        let versionClassFlow = try reader.readUInt32()
        let version = versionClassFlow >> 28
        guard version == 6 else { throw DissectionError.malformed }

        let payloadLength = try reader.readUInt16()
        let nextHeader = try reader.readUInt8()
        let hopLimit = try reader.readUInt8()
        let sourceBytes = try reader.readBytes(16)
        let destinationBytes = try reader.readBytes(16)

        guard let source = IPAddress(bytes: sourceBytes),
              let destination = IPAddress(bytes: destinationBytes)
        else {
            throw DissectionError.malformed
        }

        let transport = TransportProtocol(ipProtocolNumber: nextHeader)
        let fields = [
            DissectionField(name: "Version", value: "6", byteRange: start ..< start + 1),
            DissectionField(name: "Payload Length", value: "\(payloadLength)", byteRange: start + 4 ..< start + 6),
            DissectionField(
                name: "Next Header",
                value: "\(transport.displayName) (\(nextHeader))",
                byteRange: start + 6 ..< start + 7
            ),
            DissectionField(name: "Hop Limit", value: "\(hopLimit)", byteRange: start + 7 ..< start + 8),
            DissectionField(name: "Source", value: source.description, byteRange: start + 8 ..< start + 24),
            DissectionField(name: "Destination", value: destination.description, byteRange: start + 24 ..< start + 40)
        ]
        let node = DissectionNode(
            label: "Internet Protocol Version 6",
            shortName: "IPv6",
            fields: fields,
            byteRange: start ..< start + headerLength
        )
        return NetworkLayerResult(
            node: node,
            ipProtocol: nextHeader,
            payloadOffset: start + headerLength,
            source: source,
            destination: destination
        )
    }
}
