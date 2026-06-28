/// Classifies a connection's DNS transport from its 5-tuple and observed
/// hostname — purely, with no decryption. DoH is recognized only when the
/// destination is a known resolver hostname (the only passive DoH signal), so a
/// plain HTTPS connection to an unrelated host is never misreported as DoH.
public enum DNSEncryptionClassifier {
    /// Known public DoH resolver host suffixes → friendly provider name. Each
    /// entry is a resolver-specific hostname, NOT a provider's corporate/product
    /// homepage — otherwise a browser visiting, say, `quad9.net` would be
    /// misreported as encrypted DNS. Matched exactly or as a subdomain.
    private static let dohProviders: [(suffix: String, name: String)] = [
        ("cloudflare-dns.com", "Cloudflare"),
        ("dns.google", "Google"),
        ("dns.google.com", "Google"),
        ("dns.quad9.net", "Quad9"),
        ("dns.nextdns.io", "NextDNS"),
        ("doh.opendns.com", "OpenDNS"),
        ("dns.adguard-dns.com", "AdGuard"),
        ("doh.cleanbrowsing.org", "CleanBrowsing"),
        ("dns.controld.com", "Control D"),
        ("freedns.controld.com", "Control D")
    ]

    /// Classifies the DNS transport implied by a connection's protocol, remote
    /// port, and observed hostname (SNI/DNS-derived). `.none` when not DNS.
    public static func classify(proto: TransportProtocol, port: UInt16, hostname: String?) -> DNSTransport {
        switch port {
        case 53:
            return .plaintext
        case 853:
            return proto == .udp ? .doq : .dot
        case 5353, 5355:
            return .localDiscovery
        case 443 where proto == .tcp:
            if let hostname, let provider = knownDoHProvider(hostname) {
                return .doh(resolver: provider)
            }
            return .none
        default:
            return .none
        }
    }

    /// The friendly provider name if `hostname` is a known DoH resolver, else nil.
    /// Matches the host exactly or as a subdomain of a table suffix, case-insensitively.
    public static func knownDoHProvider(_ hostname: String) -> String? {
        let host = hostname.lowercased()
        for entry in dohProviders where host == entry.suffix || host.hasSuffix("." + entry.suffix) {
            return entry.name
        }
        return nil
    }
}
