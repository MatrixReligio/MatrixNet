import MatrixNetModel

/// Resolves a domain name to a real IP address. Implementations MUST use DoH
/// (DNS-over-HTTPS) with an IP-literal endpoint (e.g. `https://1.1.1.1/dns-query`):
/// under a TUN proxy, plaintext DNS — even sent to a public resolver's IP — is
/// intercepted and answered with a synthetic fake-IP, whereas the encrypted DoH
/// response is opaque to the proxy and carries the true address. (Verified on a
/// real machine 2026-06-29; see the proxy-visibility spec §10.)
public protocol DomainResolving: Sendable {
    func resolve(_ domain: String) async -> IPAddress?
}

/// Recovers the geographic country of a proxied flow whose kernel destination is
/// a synthetic fake-IP, by resolving the real domain (from SNI/DNS) to a real IP
/// and geolocating that. This makes an outbound DNS query, so it is gated by an
/// explicit `enabled` flag and only ever called for proxied flows whose country
/// is otherwise unknown. Results (including misses) are cached per domain so each
/// domain is queried at most once.
public actor ActiveGeoResolver {
    private let enabled: Bool
    private let resolver: DomainResolving
    private let lookupCountry: @Sendable (IPAddress) -> String?
    private var cache: [String: String?] = [:]

    public init(
        enabled: Bool,
        resolver: DomainResolving,
        lookupCountry: @escaping @Sendable (IPAddress) -> String?
    ) {
        self.enabled = enabled
        self.resolver = resolver
        self.lookupCountry = lookupCountry
    }

    /// The ISO country code for `domain`'s real destination, or `nil` when
    /// disabled, unresolvable, or ungeolocatable.
    public func country(forProxiedDomain domain: String) async -> String? {
        guard enabled else { return nil }
        if let cached = cache[domain] { return cached }
        guard let ip = await resolver.resolve(domain) else {
            cache[domain] = String?.none
            return nil
        }
        let code = lookupCountry(ip)
        cache[domain] = code
        return code
    }
}
