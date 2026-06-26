import Foundation
import MatrixNetModel

/// IPv4 country lookup over a sorted range table, using binary search. The table
/// is a compact binary blob (built from the CC-BY DB-IP Country Lite dataset by
/// `scripts/build-geoip.sh`): a UInt32 count, then `count` records of
/// `[startIP: UInt32 BE][endIP: UInt32 BE][country: 2 ASCII bytes]`.
public struct GeoIPDatabase: Sendable {
    struct Range {
        let start: UInt32
        let end: UInt32
        let country: String
    }

    private let ranges: [Range]

    /// Whether the database carries no ranges (e.g. a header-only file).
    public var isEmpty: Bool {
        ranges.isEmpty
    }

    /// Builds from pre-sorted ranges (used by the loader and tests).
    init(ranges: [Range]) {
        self.ranges = ranges
    }

    /// Loads the compact binary range table. Returns `nil` if truncated/invalid.
    public init?(data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return nil }
        func readUInt32(_ offset: Int) -> UInt32 {
            (0 ..< 4).reduce(UInt32(0)) { $0 << 8 | UInt32(bytes[offset + $1]) }
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
    }

    /// Looks up the ISO 3166-1 alpha-2 country code for an address, or `nil`.
    /// IPv4 only (the lite dataset); IPv6 returns `nil`.
    public func country(for address: IPAddress) -> String? {
        let bytes = address.unmappedIPv4.bytes
        guard bytes.count == 4 else { return nil }
        let value = bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }

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
                return range.country
            }
        }
        return nil
    }

    /// The flag emoji for an ISO country code (e.g. "US" -> 🇺🇸).
    public static func flag(for countryCode: String) -> String? {
        guard countryCode.count == 2 else { return nil }
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
