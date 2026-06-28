import CryptoKit
import Foundation

/// Fields parsed from a TLS ClientHello that JA4 is computed from.
struct JA4ClientHello: Sendable, Equatable {
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
    enum Transport: Sendable { case tcp, quic }

    /// GREASE: both bytes equal and each low nibble is `0xa` (RFC 8701).
    static func isGREASE(_ value: UInt16) -> Bool {
        let high = UInt8(value >> 8)
        let low = UInt8(value & 0xFF)
        return high == low && (low & 0x0F) == 0x0A
    }
}
