import Foundation

/// Dissects the head of an HTTP/1.x message (request line or status line plus
/// headers). Bodies are not reassembled here — that is Follow Stream's job.
enum HTTPDissector {
    private static let methods = [
        "GET", "POST", "PUT", "DELETE", "HEAD", "OPTIONS", "PATCH", "CONNECT", "TRACE"
    ]

    /// Heuristic content sniff: does the payload begin with an HTTP request line
    /// or status line?
    static func looksLikeHTTP(_ bytes: [UInt8], at offset: Int) -> Bool {
        guard let prefix = asciiPrefix(bytes, at: offset, max: 8) else { return false }
        if prefix.hasPrefix("HTTP/") { return true }
        return methods.contains { prefix.hasPrefix($0 + " ") }
    }

    /// Headers surfaced as fields when present (others are still counted).
    private static let notableHeaders = ["host", "content-type", "user-agent", "server", "location"]

    static func dissect(_ bytes: [UInt8], at start: Int) throws -> DissectionNode {
        guard looksLikeHTTP(bytes, at: start) else { throw DissectionError.malformed }
        guard start < bytes.count,
              let text = String(bytes: bytes[start ..< bytes.count], encoding: .isoLatin1)
        else {
            throw DissectionError.malformed
        }

        // Header section ends at the first blank line; tolerate its absence.
        let head = text.components(separatedBy: "\r\n\r\n").first ?? text
        let lines = head.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        guard let startLine = lines.first else { throw DissectionError.malformed }

        var fields = [DissectionField]()
        let parts = startLine.split(separator: " ", maxSplits: 2).map(String.init)

        if startLine.hasPrefix("HTTP/") {
            fields.append(DissectionField(name: "Version", value: parts.first ?? ""))
            if parts.count >= 2 { fields.append(DissectionField(name: "Status Code", value: parts[1])) }
            if parts.count >= 3 { fields.append(DissectionField(name: "Reason", value: parts[2])) }
        } else {
            if parts.count >= 1 { fields.append(DissectionField(name: "Method", value: parts[0])) }
            if parts.count >= 2 { fields.append(DissectionField(name: "Request URI", value: parts[1])) }
            if parts.count >= 3 { fields.append(DissectionField(name: "Version", value: parts[2])) }
        }

        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if notableHeaders.contains(name.lowercased()) {
                fields.append(DissectionField(name: name, value: value))
            }
        }

        return DissectionNode(
            label: "Hypertext Transfer Protocol",
            shortName: "HTTP",
            fields: fields,
            byteRange: start ..< bytes.count
        )
    }

    private static func asciiPrefix(_ bytes: [UInt8], at offset: Int, max: Int) -> String? {
        guard offset < bytes.count else { return nil }
        let slice = Array(bytes[offset ..< min(offset + max, bytes.count)])
        return String(bytes: slice, encoding: .isoLatin1)
    }
}
