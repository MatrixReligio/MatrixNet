import CryptoKit
import Foundation

/// Fields parsed from a TLS ClientHello that JA4 is computed from.
struct JA4ClientHello: Equatable {
    /// Negotiated/offered version used for JA4_a (from supported_versions, else legacy).
    var tlsVersion: UInt16
    /// Offered cipher suites, in wire order, GREASE NOT yet removed.
    var ciphers: [UInt16]
    /// Offered extension types, in wire order, GREASE NOT yet removed.
    var extensions: [UInt16]
    /// signature_algorithms (extension 0x000d) values, in wire order.
    var signatureAlgorithms: [UInt16]
    /// The first ALPN protocol's raw bytes, when an ALPN extension is present.
    var alpnFirst: [UInt8]?
    /// Whether a server_name (SNI, 0x0000) extension is present.
    var hasSNI: Bool
}

/// Computes the JA4 TLS client fingerprint (BSD-3, FoxIO patent waiver).
///
/// JA4S/JA4H/JA4X are deliberately not implemented (FoxIO License 1.1 +
/// patent-pending); only the freely-implementable JA4 client fingerprint is here.
enum JA4 {
    /// Whether the fingerprint is for TLS over TCP or over QUIC.
    enum Transport { case tcp, quic }

    /// GREASE: both bytes equal and each low nibble is `0xa` (RFC 8701).
    static func isGREASE(_ value: UInt16) -> Bool {
        let high = UInt8(value >> 8)
        let low = UInt8(value & 0xFF)
        return high == low && (low & 0x0F) == 0x0A
    }

    private static func hex4(_ value: UInt16) -> String {
        String(format: "%04x", value)
    }

    private static func hash12(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(12).description
    }

    /// Sorted, GREASE-free, comma-joined cipher hex (the JA4_b pre-image).
    static func rawB(ciphers: [UInt16]) -> String {
        ciphers.filter { !isGREASE($0) }.map(hex4).sorted().joined(separator: ",")
    }

    /// JA4_b: first 12 hex of SHA-256 of the cipher pre-image, or the zero sentinel.
    static func partB(ciphers: [UInt16]) -> String {
        let raw = rawB(ciphers: ciphers)
        return raw.isEmpty ? "000000000000" : hash12(raw)
    }

    /// Sorted GREASE/SNI/ALPN-free extensions, then "_" + sig-algs in wire order
    /// (the JA4_c pre-image). The trailing "_" is omitted when there are no sig-algs.
    static func rawC(extensions: [UInt16], signatureAlgorithms: [UInt16]) -> String {
        let exts = extensions
            .filter { !isGREASE($0) && $0 != 0x0000 && $0 != 0x0010 }
            .map(hex4)
            .sorted()
            .joined(separator: ",")
        // No qualifying extensions → no pre-image. Returning "" (rather than
        // "_<sigs>") keeps the contract self-consistent; partC maps this to the
        // zero sentinel regardless of sig-algs.
        guard !exts.isEmpty else { return exts }
        let sigs = signatureAlgorithms.filter { !isGREASE($0) }.map(hex4).joined(separator: ",")
        return sigs.isEmpty ? exts : "\(exts)_\(sigs)"
    }

    /// JA4_c: first 12 hex of SHA-256 of the extension pre-image, or the zero sentinel.
    static func partC(extensions: [UInt16], signatureAlgorithms: [UInt16]) -> String {
        let extsOnly = extensions.filter { !isGREASE($0) && $0 != 0x0000 && $0 != 0x0010 }
        if extsOnly.isEmpty { return "000000000000" }
        return hash12(rawC(extensions: extensions, signatureAlgorithms: signatureAlgorithms))
    }

    /// Two-character JA4 version code (FoxIO mapping); "00" if unrecognized.
    private static func versionString(_ value: UInt16) -> String {
        switch value {
        case 0x0304: "13"
        case 0x0303: "12"
        case 0x0302: "11"
        case 0x0301: "10"
        case 0x0300: "s3"
        case 0x0002: "s2"
        case 0xFEFF: "d1"
        case 0xFEFD: "d2"
        case 0xFEFC: "d3"
        default: "00"
        }
    }

    private static func count2(_ count: Int) -> String {
        String(format: "%02d", min(count, 99))
    }

    /// First and last char of the first ALPN value; "00" when absent, "99" when
    /// the first byte is non-ASCII. This follows FoxIO's reference `ja4.py`
    /// (`f"{alpn[0]}{alpn[-1]}"`, then `'99'` if `ord(alpn[0]) > 127`), which is
    /// what shipping tools actually produce; it diverges from the prose in JA4.md
    /// for non-ASCII bytes, but real ALPN values are always printable ASCII
    /// protocol IDs (h2, http/1.1, h3), so the common path is unambiguous.
    private static func alpnCode(_ value: [UInt8]?) -> String {
        guard let value, let first = value.first, let last = value.last else { return "00" }
        if first > 0x7F { return "99" }
        return "\(String(UnicodeScalar(first)))\(String(UnicodeScalar(last)))"
    }

    /// JA4_a: protocol + version + SNI flag + cipher count + extension count + ALPN.
    static func rawA(from hello: JA4ClientHello, transport: Transport) -> String {
        let proto = transport == .quic ? "q" : "t"
        let sni = hello.hasSNI ? "d" : "i"
        let cipherCount = count2(hello.ciphers.count(where: { !isGREASE($0) }))
        let extCount = count2(hello.extensions.count(where: { !isGREASE($0) }))
        return "\(proto)\(versionString(hello.tlsVersion))\(sni)\(cipherCount)\(extCount)\(alpnCode(hello.alpnFirst))"
    }

    /// The full JA4 string `a_b_c`.
    static func string(from hello: JA4ClientHello, transport: Transport) -> String {
        let partA = rawA(from: hello, transport: transport)
        let hashB = partB(ciphers: hello.ciphers)
        let hashC = partC(extensions: hello.extensions, signatureAlgorithms: hello.signatureAlgorithms)
        return "\(partA)_\(hashB)_\(hashC)"
    }
}
