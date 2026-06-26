// Converts the DB-IP Country Lite CSV (CC-BY-4.0) into MatrixNet's compact
// binary range table: UInt32 count, then records of
// [startIP: UInt32 BE][endIP: UInt32 BE][country: 2 ASCII bytes].
// IPv6 ranges are skipped (the lite lookup is IPv4-only for now).
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
    guard !text.contains(":") else { return nil } // IPv6 -> skip
    var addr = in_addr()
    guard inet_pton(AF_INET, text, &addr) == 1 else { return nil }
    return UInt32(bigEndian: addr.s_addr)
}

guard let content = try? String(contentsOfFile: inputPath, encoding: .utf8) else {
    print("cannot read \(inputPath)")
    exit(1)
}

struct Range { let start: UInt32
    let end: UInt32
    let country: String
}

var ranges = [Range]()

for line in content.split(separator: "\n") {
    let fields = line.split(separator: ",")
    guard fields.count == 3,
          let start = ipv4Value(String(fields[0])),
          let end = ipv4Value(String(fields[1])) else { continue }
    let country = String(fields[2]).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard country.count == 2 else { continue }
    ranges.append(Range(start: start, end: end, country: country))
}

ranges.sort { $0.start < $1.start }

var data = Data()
func appendU32(_ value: UInt32) {
    for shift in stride(from: 24, through: 0, by: -8) {
        data.append(UInt8(value >> UInt32(shift) & 0xFF))
    }
}

appendU32(UInt32(ranges.count))
for range in ranges {
    appendU32(range.start)
    appendU32(range.end)
    data.append(contentsOf: Array(range.country.utf8.prefix(2)))
}

do {
    try data.write(to: URL(fileURLWithPath: outputPath))
    print("wrote \(ranges.count) IPv4 country ranges (\(data.count) bytes) to \(outputPath)")
} catch {
    print("write failed: \(error)")
    exit(1)
}
