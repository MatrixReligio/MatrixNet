import Foundation
import MatrixNetModel

/// Country lookup over sorted range tables, using binary search. The table is a
/// compact binary blob (built from the CC-BY DB-IP Country Lite dataset by
/// `scripts/build-geoip.sh`).
///
/// Format v2 is the IPv4 table followed by an appended IPv6 section:
///   - `[v4count: UInt32 BE]` then `count` records of
///     `[startIP: UInt32 BE][endIP: UInt32 BE][country: 2 ASCII bytes]` (10 B);
///   - optionally `[v6count: UInt32 BE]` then `count` records of
///     `[startIP: 16 B BE][endIP: 16 B BE][country: 2 ASCII bytes]` (34 B).
///
/// The IPv6 section is appended *after* the IPv4 table, so the format is both
/// backward compatible (older readers stop after the IPv4 table and ignore the
/// tail) and forward compatible (a legacy v1 file with no tail loads with an
/// empty IPv6 table).
public struct GeoIPDatabase: Sendable {
    struct Range {
        let start: UInt32
        let end: UInt32
        let country: String
    }

    /// An IPv6 range, stored as the big-endian high/low 64-bit halves of the
    /// start and end addresses so lookups compare lexicographically without a
    /// 128-bit integer type.
    struct V6Range {
        let startHigh: UInt64
        let startLow: UInt64
        let endHigh: UInt64
        let endLow: UInt64
        let country: String
    }

    private let ranges: [Range]
    private let v6Ranges: [V6Range]

    /// Whether the database carries no ranges in either family (e.g. a
    /// header-only file). A valid IPv4-only (legacy) database is not empty.
    public var isEmpty: Bool {
        ranges.isEmpty && v6Ranges.isEmpty
    }

    /// Builds from pre-sorted ranges (used by the loader and tests).
    init(ranges: [Range], v6Ranges: [V6Range] = []) {
        self.ranges = ranges
        self.v6Ranges = v6Ranges
    }

    /// Loads the compact binary range table. Returns `nil` if truncated/invalid.
    public init?(data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return nil }
        func readUInt32(_ offset: Int) -> UInt32 {
            (0 ..< 4).reduce(UInt32(0)) { $0 << 8 | UInt32(bytes[offset + $1]) }
        }
        func readUInt64(_ offset: Int) -> UInt64 {
            (0 ..< 8).reduce(UInt64(0)) { $0 << 8 | UInt64(bytes[offset + $1]) }
        }

        let count = Int(readUInt32(0))
        let recordSize = 10 // startIP(4) + endIP(4) + country(2)
        guard count >= 0, bytes.count >= 4 + count * recordSize else { return nil }

        var ranges = [Range]()
        ranges.reserveCapacity(count)
        var offset = 4
        for _ in 0 ..< count {
            let country = String(bytes: bytes[offset + 8 ..< offset + 10], encoding: .utf8) ?? "??"
            ranges.append(Range(start: readUInt32(offset), end: readUInt32(offset + 4), country: country))
            offset += recordSize
        }
        self.ranges = ranges

        guard let v6Ranges = Self.parseV6Section(
            bytes: bytes, offset: offset, readUInt32: readUInt32, readUInt64: readUInt64
        ) else { return nil }
        self.v6Ranges = v6Ranges
    }

    /// Parses the optional appended IPv6 section starting at `offset`. Returns an
    /// empty array when there is no tail (legacy v1 file), or `nil` when the
    /// declared section is truncated.
    private static func parseV6Section(
        bytes: [UInt8],
        offset: Int,
        readUInt32: (Int) -> UInt32,
        readUInt64: (Int) -> UInt64
    ) -> [V6Range]? {
        guard bytes.count >= offset + 4 else { return [] }
        let v6Count = Int(readUInt32(offset))
        let v6RecordSize = 34 // startIP(16) + endIP(16) + country(2)
        guard v6Count >= 0, bytes.count >= offset + 4 + v6Count * v6RecordSize else { return nil }

        var v6Ranges = [V6Range]()
        v6Ranges.reserveCapacity(v6Count)
        var cursor = offset + 4
        for _ in 0 ..< v6Count {
            let country = String(bytes: bytes[cursor + 32 ..< cursor + 34], encoding: .utf8) ?? "??"
            v6Ranges.append(V6Range(
                startHigh: readUInt64(cursor),
                startLow: readUInt64(cursor + 8),
                endHigh: readUInt64(cursor + 16),
                endLow: readUInt64(cursor + 24),
                country: country
            ))
            cursor += v6RecordSize
        }
        return v6Ranges
    }

    /// Looks up the ISO 3166-1 alpha-2 country code for an address, or `nil`.
    /// IPv4-mapped IPv6 addresses are normalised to IPv4 first.
    public func country(for address: IPAddress) -> String? {
        switch address.unmappedIPv4 {
        case let .v4(value):
            lookupV4(value)
        case let .v6(high, low):
            lookupV6(high: high, low: low)
        }
    }

    private func lookupV4(_ value: UInt32) -> String? {
        var low = 0
        var high = ranges.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let range = ranges[mid]
            if value < range.start {
                high = mid - 1
            } else if value > range.end {
                low = mid + 1
            } else {
                return Self.resolved(range.country)
            }
        }
        return nil
    }

    private func lookupV6(high: UInt64, low: UInt64) -> String? {
        var lower = 0
        var upper = v6Ranges.count - 1
        while lower <= upper {
            let mid = (lower + upper) / 2
            let range = v6Ranges[mid]
            if (high, low) < (range.startHigh, range.startLow) {
                upper = mid - 1
            } else if (high, low) > (range.endHigh, range.endLow) {
                lower = mid + 1
            } else {
                return Self.resolved(range.country)
            }
        }
        return nil
    }

    /// DB-IP marks reserved/unallocated (but globally-routed) ranges with
    /// placeholder codes; treat them as unknown, not a country.
    private static func resolved(_ country: String) -> String? {
        placeholderCodes.contains(country.uppercased()) ? nil : country
    }

    /// Placeholder/user-assigned codes that are not real countries; turning them
    /// into regional-indicator pairs renders as missing-glyph boxes.
    private static let placeholderCodes: Set<String> = ["ZZ", "XX", "??"]

    /// The flag emoji for an ISO country code (e.g. "US" -> 🇺🇸). Returns `nil`
    /// for placeholder codes like "ZZ" (DB-IP's marker for unknown/reserved
    /// ranges) so they never show as tofu.
    public static func flag(for countryCode: String) -> String? {
        guard countryCode.count == 2 else { return nil }
        guard !placeholderCodes.contains(countryCode.uppercased()) else { return nil }
        let base: UInt32 = 0x1F1E6
        var scalars = String.UnicodeScalarView()
        for character in countryCode.uppercased().unicodeScalars {
            guard ("A" ... "Z").contains(character),
                  let scalar = Unicode.Scalar(base + character.value - 65) else { return nil }
            scalars.append(scalar)
        }
        return String(scalars)
    }
}
