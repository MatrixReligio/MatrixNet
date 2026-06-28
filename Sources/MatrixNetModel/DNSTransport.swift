/// How an app's DNS queries travel — the basis of its DNS privacy posture.
public enum DNSTransport: Sendable, Equatable, Hashable {
    /// Cleartext DNS on port 53 — visible to the local network and ISP.
    case plaintext
    /// DNS over TLS (RFC 7858), TCP port 853.
    case dot
    /// DNS over QUIC (RFC 9250), UDP port 853.
    case doq
    /// DNS over HTTPS (RFC 8484) — port 443 to a known resolver; `resolver` is a
    /// friendly provider name when recognized.
    case doh(resolver: String?)
    /// Link-local multicast name resolution (mDNS / LLMNR) — does not leave the LAN.
    case localDiscovery
    /// Not DNS traffic.
    case none

    /// Whether queries on this transport are encrypted in transit.
    public var isEncrypted: Bool {
        switch self {
        case .dot, .doq, .doh: true
        case .plaintext, .localDiscovery, .none: false
        }
    }

    /// Whether this is DNS at all (any transport except `.none`).
    public var isDNS: Bool {
        self != .none
    }
}

/// An app's aggregate DNS privacy posture across its observed connections.
public struct AppDNSPosture: Sendable, Equatable {
    public let app: String
    public let transports: Set<DNSTransport>

    public init(app: String, transports: Set<DNSTransport>) {
        self.app = app
        self.transports = transports
    }

    /// Whether the app sends any cleartext DNS (a privacy concern).
    public var usesPlaintext: Bool {
        transports.contains(.plaintext)
    }

    /// Whether the app uses any encrypted DNS transport.
    public var usesEncrypted: Bool {
        transports.contains { $0.isEncrypted }
    }
}
