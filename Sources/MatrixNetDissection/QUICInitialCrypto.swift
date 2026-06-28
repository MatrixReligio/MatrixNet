import CommonCrypto
import CryptoKit
import Foundation

/// Derives the public QUIC v1 Initial-packet keys (RFC 9001 §5.2) and performs
/// the AEAD / header-protection crypto needed to read an Initial packet. Initial
/// packets are protected with keys derived from a fixed salt and the client's
/// Destination Connection ID, so this needs no handshake secret — it is fully
/// passive. Constants are verbatim from RFC 9001.
/// The client Initial-packet keys derived for a QUIC connection.
struct QUICKeys: Equatable {
    let key: [UInt8]
    let iv: [UInt8]
    let hp: [UInt8]
}

enum QUICInitialCrypto {
    /// RFC 9001 §5.2 — the QUIC version 1 initial salt.
    static let v1Salt: [UInt8] = [
        0x38, 0x76, 0x2C, 0xF7, 0xF5, 0x59, 0x34, 0xB3, 0x4D, 0x17,
        0x9A, 0xE6, 0xA4, 0xC8, 0x0C, 0xAD, 0xCC, 0xBB, 0x7F, 0x0A
    ]

    /// The client key, IV, and header-protection key for a given DCID.
    static func initialSecrets(dcid: [UInt8]) -> QUICKeys {
        let prk = HKDF<SHA256>.extract(
            inputKeyMaterial: SymmetricKey(data: Data(dcid)),
            salt: Data(v1Salt)
        )
        let clientSecret = HKDFExpandLabel.derive(secret: prk, label: "client in", length: 32)
        return QUICKeys(
            key: HKDFExpandLabel.derive(secret: clientSecret, label: "quic key", length: 16),
            iv: HKDFExpandLabel.derive(secret: clientSecret, label: "quic iv", length: 12),
            hp: HKDFExpandLabel.derive(secret: clientSecret, label: "quic hp", length: 16)
        )
    }

    /// AES-128-ECB of the 16-byte ciphertext sample under the hp key; the first
    /// five bytes form the header-protection mask (RFC 9001 §5.4.3).
    static func headerProtectionMask(hp: [UInt8], sample: [UInt8]) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: kCCBlockSizeAES128)
        let capacity = output.count
        let keyLength = hp.count
        let sampleLength = sample.count
        var moved = 0
        _ = hp.withUnsafeBytes { keyPtr in
            sample.withUnsafeBytes { dataPtr in
                output.withUnsafeMutableBytes { outPtr in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        keyPtr.baseAddress,
                        keyLength,
                        nil,
                        dataPtr.baseAddress,
                        sampleLength,
                        outPtr.baseAddress,
                        capacity,
                        &moved
                    )
                }
            }
        }
        return output
    }
}
