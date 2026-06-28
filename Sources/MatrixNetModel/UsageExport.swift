import Foundation

/// Serializes usage rows to CSV or JSON for export (reporting, billing, audit).
/// Pure and deterministic: dates are ISO-8601 in UTC and rows keep their order.
public enum UsageExport {
    private static let header = "app,country,host,bytes_in,bytes_out,period_start"

    public static func csv(_ rows: [UsageRow]) -> String {
        var lines = [header]
        for row in rows {
            lines.append([
                field(row.app),
                field(row.country),
                field(row.host),
                "\(row.bytesIn)",
                "\(row.bytesOut)",
                isoDate(row.periodStart)
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    public static func json(_ rows: [UsageRow]) -> String {
        guard !rows.isEmpty else { return "[]" }
        let dtos = rows.map { row in
            Row(
                app: row.app,
                host: row.host,
                country: row.country,
                bytesIn: row.bytesIn,
                bytesOut: row.bytesOut,
                periodStart: isoDate(row.periodStart)
            )
        }
        let encoder = JSONEncoder()
        // snake_case so JSON keys match the CSV header (bytes_in, period_start, …).
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(dtos), let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return string
    }

    private struct Row: Encodable {
        let app: String
        let host: String
        let country: String
        let bytesIn: UInt64
        let bytesOut: UInt64
        let periodStart: String
    }

    /// Quotes a CSV field when it contains a comma, quote, or newline, doubling
    /// any embedded quotes (RFC 4180).
    private static func field(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func isoDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}
