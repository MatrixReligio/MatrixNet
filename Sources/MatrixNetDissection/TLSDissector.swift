import Foundation

/// Dissects the visible (unencrypted) portion of TLS: the record header and, for
/// a ClientHello, the Server Name Indication (SNI). This reveals the destination
/// hostname of an HTTPS flow without any decryption.
enum TLSDissector {
    struct Result {
        let node: DissectionNode
        /// The SNI host from a ClientHello, when present.
        let serverName: String?
    }

    /// Returns true if the bytes at `offset` look like a TLS record (handshake or
    /// application data with a TLS 1.x version), enabling content-based sniffing.
    static func looksLikeTLS(_ bytes: [UInt8], at offset: Int) -> Bool {
        guard offset + 2 < bytes.count else { return false }
        let contentType = bytes[offset]
        let major = bytes[offset + 1]
        return (0x14 ... 0x17).contains(contentType) && major == 0x03
    }

    static func dissect(_ bytes: [UInt8], at start: Int) throws -> Result {
        var reader = ByteReader(bytes, offset: start)
        let contentType = try reader.readUInt8()
        let recordVersion = try reader.readUInt16()
        let recordLength = try reader.readUInt16()

        var fields = [
            DissectionField(name: "Content Type", value: contentTypeName(contentType)),
            DissectionField(name: "Version", value: versionName(recordVersion)),
            DissectionField(name: "Length", value: "\(recordLength)")
        ]

        var serverName: String?
        if contentType == 0x16 { // handshake
            let handshakeType = try reader.readUInt8()
            fields.append(DissectionField(name: "Handshake Type", value: handshakeTypeName(handshakeType)))
            if handshakeType == 0x01 { // ClientHello
                serverName = try? parseClientHelloSNI(&reader)
                if let serverName {
                    fields.append(DissectionField(name: "Server Name", value: serverName))
                }
            }
        }

        let end = min(start + 5 + Int(recordLength), bytes.count)
        let node = DissectionNode(
            label: "Transport Layer Security",
            shortName: "TLS",
            fields: fields,
            byteRange: start ..< max(end, start + 5)
        )
        return Result(node: node, serverName: serverName)
    }

    /// Walks a ClientHello to the server_name extension and returns the host.
    private static func parseClientHelloSNI(_ reader: inout ByteReader) throws -> String? {
        _ = try reader.readUInt8() // handshake length (high byte)
        _ = try reader.readUInt16() // handshake length (low bytes)
        _ = try reader.readUInt16() // client_version
        try reader.skip(32) // random
        let sessionIDLength = try Int(reader.readUInt8())
        try reader.skip(sessionIDLength)
        let cipherSuitesLength = try Int(reader.readUInt16())
        try reader.skip(cipherSuitesLength)
        let compressionLength = try Int(reader.readUInt8())
        try reader.skip(compressionLength)

        guard reader.remaining >= 2 else { return nil }
        var extensionsRemaining = try Int(reader.readUInt16())

        while extensionsRemaining >= 4, reader.remaining >= 4 {
            let extensionType = try reader.readUInt16()
            let extensionLength = try Int(reader.readUInt16())
            extensionsRemaining -= 4
            guard reader.remaining >= extensionLength else { return nil }

            if extensionType == 0x0000 { // server_name
                _ = try reader.readUInt16() // server_name_list length
                let nameType = try reader.readUInt8()
                let nameLength = try Int(reader.readUInt16())
                guard nameType == 0, reader.remaining >= nameLength else { return nil }
                let nameBytes = try reader.readBytes(nameLength)
                return String(bytes: nameBytes, encoding: .utf8)
            } else {
                try reader.skip(extensionLength)
            }
            extensionsRemaining -= extensionLength
        }
        return nil
    }

    private static func contentTypeName(_ type: UInt8) -> String {
        switch type {
        case 0x14: "Change Cipher Spec"
        case 0x15: "Alert"
        case 0x16: "Handshake"
        case 0x17: "Application Data"
        default: "Unknown (\(type))"
        }
    }

    private static func handshakeTypeName(_ type: UInt8) -> String {
        switch type {
        case 0x01: "Client Hello"
        case 0x02: "Server Hello"
        case 0x0B: "Certificate"
        case 0x0C: "Server Key Exchange"
        case 0x0E: "Server Hello Done"
        case 0x10: "Client Key Exchange"
        default: "Type \(type)"
        }
    }

    private static func versionName(_ version: UInt16) -> String {
        switch version {
        case 0x0301: "TLS 1.0"
        case 0x0302: "TLS 1.1"
        case 0x0303: "TLS 1.2"
        case 0x0304: "TLS 1.3"
        default: HexFormat.hex16(version)
        }
    }
}
