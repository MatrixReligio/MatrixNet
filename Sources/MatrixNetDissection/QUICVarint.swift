/// Decodes QUIC variable-length integers (RFC 9000 §16). The two most
/// significant bits of the first byte select the length: 00→1, 01→2, 10→4, 11→8
/// bytes; the value is the remaining big-endian bits.
enum QUICVarint {
    static func decode(_ bytes: [UInt8], at offset: Int) -> (value: UInt64, length: Int)? {
        guard offset >= 0, offset < bytes.count else { return nil }
        let prefix = bytes[offset] >> 6
        let length = 1 << Int(prefix) // 1, 2, 4, or 8
        guard offset + length <= bytes.count else { return nil }
        var value = UInt64(bytes[offset] & 0x3F)
        for index in 1 ..< length {
            value = (value << 8) | UInt64(bytes[offset + index])
        }
        return (value, length)
    }
}
