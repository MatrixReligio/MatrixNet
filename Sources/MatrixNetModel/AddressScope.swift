/// A coarse classification of where an address lives — enough to distinguish
/// local/private traffic from traffic leaving the machine, without a GeoIP
/// database. (Full country geolocation would require a separately-licensed DB.)
public enum AddressScope: String, Sendable {
    case loopback
    case linkLocal
    case privateNetwork
    case carrierGradeNAT
    case multicast
    case global

    /// A short human label.
    public var label: String {
        switch self {
        case .loopback: "Loopback"
        case .linkLocal: "Link-local"
        case .privateNetwork: "Private"
        case .carrierGradeNAT: "CGNAT"
        case .multicast: "Multicast"
        case .global: "Public"
        }
    }

    /// Whether traffic to this address stays on the local host/network.
    public var isLocal: Bool {
        self != .global
    }
}

public extension IPAddress {
    /// Classifies the address into a coarse routing scope. IPv4-mapped IPv6 is
    /// classified as its underlying IPv4.
    var scope: AddressScope {
        let address = unmappedIPv4
        let bytes = address.bytes
        return bytes.count == 4 ? Self.scopeV4(bytes) : Self.scopeV6(bytes)
    }

    private static func scopeV4(_ bytes: [UInt8]) -> AddressScope {
        switch (bytes[0], bytes[1]) {
        case (127, _): .loopback
        case (10, _): .privateNetwork
        case (172, 16 ... 31): .privateNetwork
        case (192, 168): .privateNetwork
        case (169, 254): .linkLocal
        case (100, 64 ... 127): .carrierGradeNAT
        case (224 ... 239, _): .multicast
        default: .global
        }
    }

    private static func scopeV6(_ bytes: [UInt8]) -> AddressScope {
        if bytes == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1] { return .loopback }
        switch bytes[0] {
        case 0xFF: return .multicast
        case 0xFE where bytes[1] & 0xC0 == 0x80: return .linkLocal
        case 0xFC, 0xFD: return .privateNetwork // unique local (fc00::/7)
        default: return .global
        }
    }
}
