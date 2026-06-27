// Converts the public-domain IPsum aggregate (one IPv4 per line, optionally with
// a trailing count column; lines starting with '#' are comments) into
// MatrixNet's compact binary threat table: UInt32 count, then `count` big-endian
// UInt32 IPv4 addresses, sorted ascending. IPv6 lines are skipped.
//
// IPsum (https://github.com/stamparm/ipsum) is released under the Unlicense
// (public domain).
//
// Usage: swift Tools/ThreatConvert/main.swift <input.txt> <output.dat>
import Darwin
import Foundation

guard CommandLine.arguments.count == 3 else {
    print("usage: ThreatConvert <input.txt> <output.dat>")
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

var addresses = Set<UInt32>()
for rawLine in content.split(separator: "\n") {
    let line = rawLine.trimmingCharacters(in: .whitespaces)
    guard !line.isEmpty, !line.hasPrefix("#") else { continue }
    // IPsum lines are "IP" or "IP<TAB>count"; take the first whitespace field.
    let first = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? line
    if let value = ipv4Value(first) {
        addresses.insert(value)
    }
}

let sorted = addresses.sorted()

var data = Data()
func appendU32(_ value: UInt32) {
    for shift in stride(from: 24, through: 0, by: -8) {
        data.append(UInt8(value >> UInt32(shift) & 0xFF))
    }
}

appendU32(UInt32(sorted.count))
for address in sorted {
    appendU32(address)
}

do {
    try data.write(to: URL(fileURLWithPath: outputPath))
    print("wrote \(sorted.count) IPv4 threat addresses (\(data.count) bytes) to \(outputPath)")
} catch {
    print("write failed: \(error)")
    exit(1)
}
