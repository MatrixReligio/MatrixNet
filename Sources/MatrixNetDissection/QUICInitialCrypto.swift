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

    /// Fully decrypts a QUIC v1 Initial packet to its frame payload, or nil if it
    /// is not a v1 Initial / fails authentication. Passive: keys come from the
    /// public DCID-derived secret, never a handshake secret.
    static func decryptInitial(_ packet: [UInt8]) -> [UInt8]? {
        guard let header = QUICInitial.parse(packet), header.version == 1 else { return nil }
        let keys = initialSecrets(dcid: header.dcid)
        let sampleStart = header.pnOffset + 4
        guard sampleStart + 16 <= packet.count else { return nil }
        let mask = headerProtectionMask(hp: keys.hp, sample: Array(packet[sampleStart ..< sampleStart + 16]))

        let firstByte = packet[0] ^ (mask[0] & 0x0F)
        let pnLength = Int(firstByte & 0x03) + 1
        let payloadStart = header.pnOffset + pnLength
        let payloadEnd = header.pnOffset + header.length
        guard payloadStart <= packet.count, payloadEnd <= packet.count, payloadEnd - payloadStart >= 16 else {
            return nil
        }

        var pnBytes = [UInt8]()
        for index in 0 ..< pnLength {
            pnBytes.append(packet[header.pnOffset + index] ^ mask[1 + index])
        }

        var aad = [firstByte]
        aad.append(contentsOf: packet[1 ..< header.pnOffset])
        aad.append(contentsOf: pnBytes)

        let body = Array(packet[payloadStart ..< payloadEnd])
        let ciphertext = Array(body.prefix(body.count - 16))
        let tag = Array(body.suffix(16))

        var nonce = keys.iv
        for index in 0 ..< pnLength {
            nonce[nonce.count - pnLength + index] ^= pnBytes[index]
        }
        return try? aesGCMOpen(key: keys.key, nonce: nonce, ciphertext: ciphertext, tag: tag, aad: aad)
    }

    private static func aesGCMOpen(
        key: [UInt8],
        nonce: [UInt8],
        ciphertext: [UInt8],
        tag: [UInt8],
        aad: [UInt8]
    ) throws -> [UInt8] {
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: Data(nonce)),
            ciphertext: Data(ciphertext),
            tag: Data(tag)
        )
        let plaintext = try AES.GCM.open(box, using: SymmetricKey(data: Data(key)), authenticating: Data(aad))
        return Array(plaintext)
    }
}
