import Foundation
import MatrixNetModel

/// Membership test over a sorted table of malicious IPv4 addresses, using binary
/// search. The table is a compact binary blob (built from the public-domain
/// IPsum aggregate by `scripts/build-threatlist.sh`): a `UInt32` count, then
/// `count` big-endian `UInt32` IPv4 addresses, sorted ascending.
public struct ThreatDatabase: Sendable {
    /// IPv4 addresses as 32-bit integers, sorted ascending for binary search.
    private let addresses: [UInt32]

    /// How many addresses the database holds.
    public var count: Int {
        addresses.count
    }

    /// Whether the database carries no addresses (e.g. a header-only file).
    public var isEmpty: Bool {
        addresses.isEmpty
    }

    /// Builds from raw addresses (sorted defensively so lookups are correct).
    public init(addresses: [UInt32]) {
        self.addresses = addresses.sorted()
    }

    /// Loads the compact binary table. Returns `nil` if truncated/invalid.
    public init?(data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return nil }
        func readUInt32(_ offset: Int) -> UInt32 {
            (0 ..< 4).reduce(UInt32(0)) { $0 << 8 | UInt32(bytes[offset + $1]) }
        }
        let count = Int(readUInt32(0))
        guard count >= 0, bytes.count >= 4 + count * 4 else { return nil }

        var result = [UInt32]()
        result.reserveCapacity(count)
        var offset = 4
        for _ in 0 ..< count {
            result.append(readUInt32(offset))
            offset += 4
        }
        // The builder writes sorted addresses; sort defensively all the same.
        addresses = result.sorted()
    }

    /// Encodes the table to the compact binary format `init?(data:)` reads.
    public func serialized() -> Data {
        var data = Data(capacity: 4 + addresses.count * 4)
        func append(_ value: UInt32) {
            data.append(UInt8((value >> 24) & 0xFF))
            data.append(UInt8((value >> 16) & 0xFF))
            data.append(UInt8((value >> 8) & 0xFF))
            data.append(UInt8(value & 0xFF))
        }
        append(UInt32(addresses.count))
        for address in addresses {
            append(address)
        }
        return data
    }

    /// Whether the address is on the threat list. IPv4 only (the IPsum dataset);
    /// IPv6 always returns `false`.
    public func contains(_ address: IPAddress) -> Bool {
        let bytes = address.unmappedIPv4.bytes
        guard bytes.count == 4 else { return false }
        let value = bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }

        var low = 0
        var high = addresses.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let candidate = addresses[mid]
            if value < candidate {
                high = mid - 1
            } else if value > candidate {
                low = mid + 1
            } else {
                return true
            }
        }
        return false
    }
}
