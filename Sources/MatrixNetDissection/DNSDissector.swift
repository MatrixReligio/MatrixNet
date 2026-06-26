import Foundation
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

    /// Defensive cap on record counts so a lying QDCOUNT/ANCOUNT can't drive a
    /// huge loop even before the bounds checks would stop it.
    private static let maxRecords = 100

    static func dissect(_ bytes: [UInt8], at start: Int) throws -> (node: DissectionNode, message: DNSMessage) {
        var reader = ByteReader(bytes, offset: start)
        let id = try reader.readUInt16()
        let flags = try reader.readUInt16()
        let questionCount = try reader.readUInt16()
        let answerCount = try reader.readUInt16()
        _ = try reader.readUInt16() // NSCOUNT
        _ = try reader.readUInt16() // ARCOUNT

        var offset = reader.offset
        var questions = [DNSQuestion]()
        for _ in 0 ..< min(Int(questionCount), maxRecords) {
            guard let parsed = parseName(bytes, at: offset, base: start) else { throw DissectionError.malformed }
            offset = parsed.nextOffset
            guard offset + 4 <= bytes.count else { throw DissectionError.malformed }
            let type = UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
            offset += 4
            questions.append(DNSQuestion(name: parsed.name, type: typeName(type)))
        }

        var answers = [DNSResourceRecord]()
        for _ in 0 ..< min(Int(answerCount), maxRecords) {
            guard let parsed = parseName(bytes, at: offset, base: start) else { throw DissectionError.malformed }
            offset = parsed.nextOffset
            guard offset + 10 <= bytes.count else { throw DissectionError.malformed }
            let type = UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
            let rdLength = Int(UInt16(bytes[offset + 8]) << 8 | UInt16(bytes[offset + 9]))
            offset += 10
            guard offset + rdLength <= bytes.count else { throw DissectionError.malformed }
            let rdata = Array(bytes[offset ..< offset + rdLength])
            offset += rdLength
            answers.append(DNSResourceRecord(
                name: parsed.name,
                type: typeName(type),
                ip: address(type: type, rdata: rdata)
            ))
        }

        let message = DNSMessage(
            id: id,
            isResponse: flags & 0x8000 != 0,
            questions: questions,
            answers: answers
        )
        let node = DissectionNode(
            label: "Domain Name System",
            shortName: "DNS",
            fields: [
                DissectionField(name: "Transaction ID", value: HexFormat.hex16(id)),
                DissectionField(name: "Flags", value: HexFormat.hex16(flags)),
                DissectionField(name: "Questions", value: "\(questionCount)"),
                DissectionField(name: "Answers", value: "\(answerCount)")
            ],
            byteRange: start ..< bytes.count
        )
        return (node, message)
    }

    /// Parses a (possibly compressed) DNS name. Follows pointers but bounds the
    /// number of jumps, returning the decoded name and the offset just past the
    /// name as it appeared at `at` (not where a pointer led). Returns `nil` on
    /// any malformed or out-of-bounds structure.
    private static func parseName(_ bytes: [UInt8], at start: Int, base: Int) -> (name: String, nextOffset: Int)? {
        var labels = [String]()
        var offset = start
        var nextOffset: Int?
        var jumps = 0

        while true {
            guard offset >= 0, offset < bytes.count else { return nil }
            let length = bytes[offset]

            if length == 0 {
                offset += 1
                return (labels.joined(separator: "."), nextOffset ?? offset)
            }

            if length & 0xC0 == 0xC0 {
                guard offset + 1 < bytes.count else { return nil }
                let pointer = (Int(length & 0x3F) << 8) | Int(bytes[offset + 1])
                if nextOffset == nil { nextOffset = offset + 2 }
                jumps += 1
                guard jumps <= maxPointerJumps else { return nil }
                offset = base + pointer
                continue
            }

            guard length & 0xC0 == 0 else { return nil } // reserved bits
            let labelLength = Int(length)
            guard offset + 1 + labelLength <= bytes.count else { return nil }
            let labelBytes = Array(bytes[offset + 1 ..< offset + 1 + labelLength])
            labels.append(String(bytes: labelBytes, encoding: .utf8) ?? "")
            offset += 1 + labelLength
        }
    }

    private static func typeName(_ type: UInt16) -> String {
        switch type {
        case 1: "A"
        case 2: "NS"
        case 5: "CNAME"
        case 6: "SOA"
        case 12: "PTR"
        case 15: "MX"
        case 16: "TXT"
        case 28: "AAAA"
        case 33: "SRV"
        case 65: "HTTPS"
        default: "TYPE\(type)"
        }
    }

    private static func address(type: UInt16, rdata: [UInt8]) -> IPAddress? {
        switch (type, rdata.count) {
        case (1, 4), (28, 16): IPAddress(bytes: rdata)
        default: nil
        }
    }
}
