import CryptoKit
import Foundation

/// TLS 1.3 HKDF-Expand-Label (RFC 8446 §7.1), used for QUIC initial key
/// derivation. The label is prefixed with "tls13 " and the context is empty.
enum HKDFExpandLabel {
    static func derive(secret: some ContiguousBytes, label: String, length: Int) -> [UInt8] {
        let fullLabel = Array("tls13 ".utf8) + Array(label.utf8)
        var info = [UInt8]()
        info.append(UInt8(length >> 8 & 0xFF))
        info.append(UInt8(length & 0xFF))
        info.append(UInt8(fullLabel.count))
        info.append(contentsOf: fullLabel)
        info.append(0) // empty context
        let okm = HKDF<SHA256>.expand(
            pseudoRandomKey: secret,
            info: Data(info),
            outputByteCount: length
        )
        return okm.withUnsafeBytes { Array($0) }
    }
}
