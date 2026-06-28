/// A parsed QUIC long-header Initial packet (RFC 9000 §17.2.2). Only the fields
/// before the packet number are read here; they are not header-protected, so
/// this works directly on the on-wire (still-encrypted) bytes.
struct QUICInitial: Equatable {
    let version: UInt32
    let dcid: [UInt8]
    let scid: [UInt8]
    let tokenLength: Int
    /// The length field: packet number + protected payload.
    let length: Int
    /// Byte offset of the (header-protected) packet number.
    let pnOffset: Int

    static func parse(_ bytes: [UInt8]) -> QUICInitial? {
        guard bytes.count >= 6 else { return nil }
        let first = bytes[0]
        guard first & 0x80 != 0 else { return nil } // long header
        guard first & 0x40 != 0 else { return nil } // fixed bit
        guard first & 0x30 == 0x00 else { return nil } // type 0 = Initial

        let version = UInt32(bytes[1]) << 24 | UInt32(bytes[2]) << 16
            | UInt32(bytes[3]) << 8 | UInt32(bytes[4])

        var offset = 5
        guard offset < bytes.count else { return nil }
        let dcidLength = Int(bytes[offset])
        offset += 1
        guard offset + dcidLength <= bytes.count else { return nil }
        let dcid = Array(bytes[offset ..< offset + dcidLength])
        offset += dcidLength

        guard offset < bytes.count else { return nil }
        let scidLength = Int(bytes[offset])
        offset += 1
        guard offset + scidLength <= bytes.count else { return nil }
        let scid = Array(bytes[offset ..< offset + scidLength])
        offset += scidLength

        guard let token = QUICVarint.decode(bytes, at: offset) else { return nil }
        offset += token.length
        let tokenLength = Int(token.value)
        guard offset + tokenLength <= bytes.count else { return nil }
        offset += tokenLength

        guard let payloadLength = QUICVarint.decode(bytes, at: offset) else { return nil }
        offset += payloadLength.length

        return QUICInitial(
            version: version,
            dcid: dcid,
            scid: scid,
            tokenLength: tokenLength,
            length: Int(payloadLength.value),
            pnOffset: offset
        )
    }
}
