import Foundation

/// Builds auditable TLS/IP byte fixtures for JA4 parsing tests, shared between
/// the dissector-level and packet-level tests (DRY).
enum JA4ParseFixtures {
    private static func u16(_ value: Int) -> [UInt8] {
        [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    /// A TLS handshake record wrapping a ClientHello with a GREASE cipher, SNI
    /// "a.com", ALPN h2, supported_versions (GREASE + 0x0304), and two sig-algs.
    static func clientHelloRecord() -> [UInt8] {
        // Extensions ---------------------------------------------------------
        let host = Array("a.com".utf8)
        let sniInner = [0x00] + u16(host.count) + host // name_type(0) + name_len + name
        let sni = u16(0x0000) + u16(sniInner.count + 2) + u16(sniInner.count) + sniInner
        let alpnList = [UInt8(2)] + Array("h2".utf8) // proto_len + "h2"
        let alpn = u16(0x0010) + u16(alpnList.count + 2) + u16(alpnList.count) + alpnList
        let svList = [UInt8(4)] + u16(0x0A0A) + u16(0x0304) // list_len + GREASE + TLS1.3
        let sv = u16(0x002B) + u16(svList.count) + svList
        let saList = u16(4) + u16(0x0403) + u16(0x0804)
        let sigAlgs = u16(0x000D) + u16(saList.count) + saList
        let extensions = sni + alpn + sv + sigAlgs

        // Body ---------------------------------------------------------------
        let clientVersion = u16(0x0303)
        let random = [UInt8](repeating: 0, count: 32)
        let sessionID = [UInt8(0)] // length 0
        let ciphers = u16(4) + u16(0x0A0A) + u16(0x1301) // list_len + GREASE + AES128
        let compression = [UInt8(1), UInt8(0)] // len 1, null
        let body = clientVersion + random + sessionID + ciphers + compression + u16(extensions.count) + extensions

        // Handshake header (type 1, 3-byte length) + body
        let handshake = [
            UInt8(0x01),
            UInt8(body.count >> 16 & 0xFF),
            UInt8(body.count >> 8 & 0xFF),
            UInt8(body.count & 0xFF)
        ] + body
        // TLS record header: handshake(0x16), version 0x0301, length
        return [0x16, 0x03, 0x01] + u16(handshake.count) + handshake
    }
}
