/// Classifies whether a destination is a synthetic fake-IP handle minted by a
/// TUN proxy (Clash/Loon/Surge) rather than a routable address. Such addresses
/// must NOT be geolocated — the real destination comes from SNI/DNS instead.
///
/// Reserved/benchmarking ranges are recognised statically; proxy pools that fall
/// outside them (observed in the wild, e.g. `198.0.0.0/16`) are matched against
/// `/16` prefixes learned at runtime from the tunnel gateway or proxy-DNS
/// answers.
public struct FakeIPClassifier: Sendable {
    private let learnedSyntheticPrefixes16: Set<UInt32>

    public init(learnedSyntheticPrefixes16: Set<UInt32> = []) {
        self.learnedSyntheticPrefixes16 = learnedSyntheticPrefixes16
    }

    /// Whether `ip` is a synthetic fake-IP handle (reserved range or a learned
    /// proxy pool prefix).
    public func isSynthetic(_ ip: IPAddress) -> Bool {
        if Self.isReservedSyntheticV4(ip) { return true }
        guard case let .v4(value) = ip.unmappedIPv4 else { return false }
        return learnedSyntheticPrefixes16.contains(value >> 16)
    }

    /// Reserved/benchmarking ranges TUN proxies carve fake-IP pools and gateways
    /// from. Real internet traffic never uses these.
    public static func isReservedSyntheticV4(_ ip: IPAddress) -> Bool {
        guard case let .v4(value) = ip.unmappedIPv4 else { return false }
        if value & 0xFFFE_0000 == 0xC612_0000 { return true } // 198.18.0.0/15
        if value & 0xFFC0_0000 == 0x6440_0000 { return true } // 100.64.0.0/10
        if value & 0xF000_0000 == 0xF000_0000 { return true } // 240.0.0.0/4
        return false
    }
}
