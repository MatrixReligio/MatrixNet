import Foundation

/// Dissects the visible (unencrypted) portion of TLS: the record header and, for
/// a ClientHello, the Server Name Indication (SNI). This reveals the destination
/// hostname of an HTTPS flow without any decryption.
enum TLSDissector {
    struct Result {
        let node: DissectionNode
        /// The SNI host from a ClientHello, when present.
        let serverName: String?
        /// The JA4 client fingerprint from a ClientHello, when present.
        let clientFingerprint: String?
        /// The recognized TLS stack for `clientFingerprint`, when known.
        let clientFingerprintLabel: JA4Label?
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
        var clientFingerprint: String?
        var clientFingerprintLabel: JA4Label?
        if contentType == 0x16 { // handshake
            let handshakeType = try reader.readUInt8()
            fields.append(DissectionField(name: "Handshake Type", value: handshakeTypeName(handshakeType)))
            if handshakeType == 0x01, let parsed = try? parseClientHello(&reader) { // ClientHello
                serverName = parsed.serverName
                if let serverName {
                    fields.append(DissectionField(name: "Server Name", value: serverName))
                }
                let ja4 = JA4.string(from: parsed.hello, transport: .tcp)
                clientFingerprint = ja4
                clientFingerprintLabel = JA4Identifier.identify(ja4)
                fields.append(DissectionField(name: "JA4", value: ja4))
                if let label = clientFingerprintLabel {
                    fields.append(DissectionField(name: "Client", value: label.name))
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
        return Result(
            node: node,
            serverName: serverName,
            clientFingerprint: clientFingerprint,
            clientFingerprintLabel: clientFingerprintLabel
        )
    }

    /// Walks a ClientHello collecting every field JA4 needs (and the SNI host).
    private static func parseClientHello(
        _ reader: inout ByteReader
    ) throws -> (hello: JA4ClientHello, serverName: String?) {
        _ = try reader.readUInt8() // handshake length (high byte)
        _ = try reader.readUInt16() // handshake length (low bytes)
        let clientVersion = try reader.readUInt16()
        try reader.skip(32) // random
        let sessionIDLength = try Int(reader.readUInt8())
        try reader.skip(sessionIDLength)

        let cipherSuitesLength = try Int(reader.readUInt16())
        var ciphers = [UInt16]()
        var remainingCiphers = cipherSuitesLength
        while remainingCiphers >= 2 {
            try ciphers.append(reader.readUInt16())
            remainingCiphers -= 2
        }

        let compressionLength = try Int(reader.readUInt8())
        try reader.skip(compressionLength)

        var hello = JA4ClientHello(
            tlsVersion: clientVersion,
            ciphers: ciphers,
            extensions: [],
            signatureAlgorithms: [],
            alpnFirst: nil,
            hasSNI: false
        )
        var serverName: String?

        guard reader.remaining >= 2 else { return (hello, serverName) }
        var extensionsRemaining = try Int(reader.readUInt16())
        var supportedVersionMax: UInt16?

        while extensionsRemaining >= 4, reader.remaining >= 4 {
            let extensionType = try reader.readUInt16()
            let extensionLength = try Int(reader.readUInt16())
            extensionsRemaining -= 4 + extensionLength
            guard reader.remaining >= extensionLength else { break }
            hello.extensions.append(extensionType)

            switch extensionType {
            case 0x0000: // server_name
                hello.hasSNI = true
                serverName = parseSNI(&reader, length: extensionLength)
            case 0x0010: // application_layer_protocol_negotiation
                hello.alpnFirst = parseFirstALPN(&reader, length: extensionLength)
            case 0x002B: // supported_versions
                supportedVersionMax = parseSupportedVersions(&reader, length: extensionLength)
            case 0x000D: // signature_algorithms
                hello.signatureAlgorithms = parseSignatureAlgorithms(&reader, length: extensionLength)
            default:
                try reader.skip(extensionLength)
            }
        }
        if let supportedVersionMax { hello.tlsVersion = supportedVersionMax }
        return (hello, serverName)
    }

    /// server_name extension: list(2) + name_type(1) + name_len(2) + name.
    private static func parseSNI(_ reader: inout ByteReader, length: Int) -> String? {
        guard let bytes = try? reader.readBytes(length), bytes.count >= 5 else { return nil }
        let nameLength = Int(bytes[3]) << 8 | Int(bytes[4])
        guard bytes[2] == 0, bytes.count >= 5 + nameLength else { return nil }
        return String(bytes: bytes[5 ..< 5 + nameLength], encoding: .utf8)
    }

    /// ALPN extension: list(2) + proto_len(1) + proto; returns the first proto.
    private static func parseFirstALPN(_ reader: inout ByteReader, length: Int) -> [UInt8]? {
        guard let bytes = try? reader.readBytes(length), bytes.count >= 3 else { return nil }
        let protoLength = Int(bytes[2])
        guard protoLength > 0, bytes.count >= 3 + protoLength else { return nil }
        return Array(bytes[3 ..< 3 + protoLength])
    }

    /// supported_versions extension: list_len(1) + versions; returns max non-GREASE.
    private static func parseSupportedVersions(_ reader: inout ByteReader, length: Int) -> UInt16? {
        guard let bytes = try? reader.readBytes(length), bytes.count >= 1 else { return nil }
        let listLength = Int(bytes[0])
        var best: UInt16?
        var index = 1
        while index + 1 < 1 + listLength, index + 1 < bytes.count {
            let value = UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])
            if !JA4.isGREASE(value) { best = max(best ?? 0, value) }
            index += 2
        }
        return best
    }

    /// signature_algorithms extension: list_len(2) + algorithms (wire order kept).
    private static func parseSignatureAlgorithms(_ reader: inout ByteReader, length: Int) -> [UInt16] {
        guard let bytes = try? reader.readBytes(length), bytes.count >= 2 else { return [] }
        let listLength = Int(bytes[0]) << 8 | Int(bytes[1])
        var values = [UInt16]()
        var index = 2
        while index + 1 < 2 + listLength, index + 1 < bytes.count {
            values.append(UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1]))
            index += 2
        }
        return values
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
