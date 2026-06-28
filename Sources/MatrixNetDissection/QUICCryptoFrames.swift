/// Reassembles the TLS ClientHello from the CRYPTO frames (type 0x06) of a
/// decrypted QUIC Initial payload. PADDING (0x00) and PING (0x01) frames are
/// skipped; any other frame type stops the scan (the ClientHello is always
/// carried in the Initial's CRYPTO frames, which come first).
enum QUICCryptoFrames {
    static func reassembleClientHello(_ plaintext: [UInt8]) -> [UInt8]? {
        var fragments = [(offset: Int, data: [UInt8])]()
        var cursor = 0
        while cursor < plaintext.count {
            let type = plaintext[cursor]
            if type == 0x00 || type == 0x01 { // PADDING / PING
                cursor += 1
                continue
            }
            guard type == 0x06 else { break } // CRYPTO only; stop at anything else
            cursor += 1
            guard let offset = QUICVarint.decode(plaintext, at: cursor) else { break }
            cursor += offset.length
            guard let length = QUICVarint.decode(plaintext, at: cursor) else { break }
            cursor += length.length
            let count = Int(length.value)
            guard cursor + count <= plaintext.count else { break }
            fragments.append((Int(offset.value), Array(plaintext[cursor ..< cursor + count])))
            cursor += count
        }
        guard !fragments.isEmpty else { return nil }

        var result = [UInt8]()
        for fragment in fragments.sorted(by: { $0.offset < $1.offset }) {
            guard fragment.offset == result.count else { return nil } // non-contiguous
            result.append(contentsOf: fragment.data)
        }
        return result
    }
}
