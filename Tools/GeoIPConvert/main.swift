// Converts the DB-IP Country Lite CSV (CC-BY-4.0) into MatrixNet's compact
// binary range table (format v2): the IPv4 table followed by an appended IPv6
// section.
//   IPv4: [count: UInt32 BE] then [start: UInt32 BE][end: UInt32 BE][cc: 2 ASCII]
//   IPv6: [count: UInt32 BE] then [start: 16 B BE][end: 16 B BE][cc: 2 ASCII]
// The IPv6 section is appended after the IPv4 table so older readers ignore it.
//
// Usage: swift Tools/GeoIPConvert/main.swift <input.csv> <output.dat>
import Darwin
import Foundation

guard CommandLine.arguments.count == 3 else {
    print("usage: GeoIPConvert <input.csv> <output.dat>")
    exit(1)
}

let inputPath = CommandLine.arguments[1]
let outputPath = CommandLine.arguments[2]

func ipv4Value(_ text: String) -> UInt32? {
    guard !text.contains(":") else { return nil } // IPv6 -> handled separately
    var addr = in_addr()
    guard inet_pton(AF_INET, text, &addr) == 1 else { return nil }
    return UInt32(bigEndian: addr.s_addr)
}

func ipv6Halves(_ text: String) -> (high: UInt64, low: UInt64)? {
    guard text.contains(":") else { return nil } // IPv4 -> handled separately
    var bytes = [UInt8](repeating: 0, count: 16)
    guard inet_pton(AF_INET6, text, &bytes) == 1 else { return nil }
    var high: UInt64 = 0
    var low: UInt64 = 0
    for byte in bytes[0 ..< 8] {
        high = (high << 8) | UInt64(byte)
    }
    for byte in bytes[8 ..< 16] {
        low = (low << 8) | UInt64(byte)
    }
    return (high, low)
}

guard let content = try? String(contentsOfFile: inputPath, encoding: .utf8) else {
    print("cannot read \(inputPath)")
    exit(1)
}

struct Range { let start: UInt32
    let end: UInt32
    let country: String
}

struct V6Range { let startHigh: UInt64
    let startLow: UInt64
    let endHigh: UInt64
    let endLow: UInt64
    let country: String
}

var ranges = [Range]()
var v6Ranges = [V6Range]()

for line in content.split(separator: "\n") {
    let fields = line.split(separator: ",")
    guard fields.count == 3 else { continue }
    let country = String(fields[2]).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard country.count == 2 else { continue }

    if let start = ipv4Value(String(fields[0])), let end = ipv4Value(String(fields[1])) {
        ranges.append(Range(start: start, end: end, country: country))
    } else if let start = ipv6Halves(String(fields[0])), let end = ipv6Halves(String(fields[1])) {
        v6Ranges.append(V6Range(
            startHigh: start.high,
            startLow: start.low,
            endHigh: end.high,
            endLow: end.low,
            country: country
        ))
    }
}

ranges.sort { $0.start < $1.start }
v6Ranges.sort { ($0.startHigh, $0.startLow) < ($1.startHigh, $1.startLow) }

var data = Data()
func appendU32(_ value: UInt32) {
    for shift in stride(from: 24, through: 0, by: -8) {
        data.append(UInt8(value >> UInt32(shift) & 0xFF))
    }
}

func appendU64(_ value: UInt64) {
    for shift in stride(from: 56, through: 0, by: -8) {
        data.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
    }
}

// IPv4 table (format v1, byte-identical).
appendU32(UInt32(ranges.count))
for range in ranges {
    appendU32(range.start)
    appendU32(range.end)
    data.append(contentsOf: Array(range.country.utf8.prefix(2)))
}

// Appended IPv6 section.
appendU32(UInt32(v6Ranges.count))
for range in v6Ranges {
    appendU64(range.startHigh)
    appendU64(range.startLow)
    appendU64(range.endHigh)
    appendU64(range.endLow)
    data.append(contentsOf: Array(range.country.utf8.prefix(2)))
}

do {
    try data.write(to: URL(fileURLWithPath: outputPath))
    print("wrote \(ranges.count) IPv4 + \(v6Ranges.count) IPv6 country ranges (\(data.count) bytes) to \(outputPath)")
} catch {
    print("write failed: \(error)")
    exit(1)
}
