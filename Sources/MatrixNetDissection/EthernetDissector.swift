/// Dissects an Ethernet II frame header (DLT_EN10MB).
enum EthernetDissector {
    static let headerLength = 14

    struct Result {
        let node: DissectionNode
        let etherType: UInt16
        let payloadOffset: Int
    }

    static func dissect(_ bytes: [UInt8]) throws -> Result {
        var reader = ByteReader(bytes)
        let destination = try reader.readBytes(6)
        let source = try reader.readBytes(6)
        let etherType = try reader.readUInt16()

        let fields = [
            DissectionField(name: "Destination", value: HexFormat.mac(destination), byteRange: 0 ..< 6),
            DissectionField(name: "Source", value: HexFormat.mac(source), byteRange: 6 ..< 12),
            DissectionField(name: "EtherType", value: etherTypeDescription(etherType), byteRange: 12 ..< 14)
        ]
        let node = DissectionNode(
            label: "Ethernet II",
            shortName: "Ethernet",
            fields: fields,
            byteRange: 0 ..< headerLength
        )
        return Result(node: node, etherType: etherType, payloadOffset: headerLength)
    }

    private static func etherTypeDescription(_ value: UInt16) -> String {
        let name: String? = switch value {
        case 0x0800: "IPv4"
        case 0x0806: "ARP"
        case 0x86DD: "IPv6"
        case 0x8100: "802.1Q VLAN"
        default: nil
        }
        if let name {
            return "\(name) (\(HexFormat.hex16(value)))"
        }
        return HexFormat.hex16(value)
    }
}
