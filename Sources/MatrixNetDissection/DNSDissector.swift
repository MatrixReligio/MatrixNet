import MatrixNetModel

/// A parsed DNS question.
public struct DNSQuestion: Sendable, Equatable {
    public let name: String
    public let type: String
}

/// A parsed DNS resource record. `ip` is populated for A/AAAA answers.
public struct DNSResourceRecord: Sendable, Equatable {
    public let name: String
    public let type: String
    public let ip: IPAddress?
}

/// A decoded DNS message, exposed for connection hostname enrichment.
public struct DNSMessage: Sendable, Equatable {
    public let id: UInt16
    public let isResponse: Bool
    public let questions: [DNSQuestion]
    public let answers: [DNSResourceRecord]
}

/// Dissects a DNS message (RFC 1035) carried in a UDP payload.
///
/// Name decompression (RFC 1035 §4.1.4) follows pointers but bounds the number
/// of jumps, so a malicious self-referential or cyclic pointer can never cause
/// an infinite loop.
enum DNSDissector {
    /// Maximum compression-pointer jumps before giving up (loop guard).
    static let maxPointerJumps = 128

    static func dissect(_ bytes: [UInt8], at start: Int) throws -> (node: DissectionNode, message: DNSMessage) {
        // STUB for RED phase.
        throw DissectionError.malformed
    }
}
