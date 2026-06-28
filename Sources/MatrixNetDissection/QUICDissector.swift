import Foundation

/// Dissects the visible part of a QUIC v1 Initial packet: it passively decrypts
/// the Initial (public keys derived from the DCID, RFC 9001 §5.2), reassembles
/// the ClientHello from the CRYPTO frames, and reports the SNI, ALPN, and the
/// QUIC JA4 fingerprint (transport `q`). Handshake/1-RTT packets stay encrypted.
enum QUICDissector {
    struct Result {
        let node: DissectionNode
        /// The SNI host from the QUIC ClientHello, when present.
        let serverName: String?
        /// The QUIC JA4 client fingerprint, when the ClientHello was recovered.
        let clientFingerprint: String?
    }

    static func dissect(_ bytes: [UInt8], at start: Int) -> Result? {
        guard start >= 0, start <= bytes.count else { return nil }
        let packet = Array(bytes[start...])
        guard let header = QUICInitial.parse(packet), header.version == 1 else { return nil }

        var fields = [
            DissectionField(name: "Version", value: "1 (RFC 9001)"),
            DissectionField(name: "DCID", value: hex(header.dcid))
        ]
        var serverName: String?
        var clientFingerprint: String?
        if let plaintext = QUICInitialCrypto.decryptInitial(packet),
           let handshake = QUICCryptoFrames.reassembleClientHello(plaintext),
           let parsed = TLSDissector.clientHello(fromHandshake: handshake) {
            serverName = parsed.serverName
            if let serverName {
                fields.append(DissectionField(name: "Server Name", value: serverName))
            }
            if let alpn = parsed.hello.alpnFirst, let alpnText = String(bytes: alpn, encoding: .utf8) {
                fields.append(DissectionField(name: "ALPN", value: alpnText))
            }
            let ja4 = JA4.string(from: parsed.hello, transport: .quic)
            clientFingerprint = ja4
            fields.append(DissectionField(name: "JA4", value: ja4))
            if let label = JA4Identifier.identify(ja4) {
                fields.append(DissectionField(name: "Client", value: label.name))
            }
        }

        // Bound the node to *this* packet, not the rest of the datagram: a UDP
        // datagram may coalesce an Initial with a following Handshake/0-RTT packet
        // (RFC 9000 §12.2). header.pnOffset/length are in `packet` coordinates.
        let packetEnd = min(start + header.pnOffset + header.length, bytes.count)
        let node = DissectionNode(
            label: "QUIC",
            shortName: "QUIC",
            fields: fields,
            byteRange: start ..< packetEnd
        )
        return Result(node: node, serverName: serverName, clientFingerprint: clientFingerprint)
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
