/// Decides whether a connection's remote endpoint is a local or configured
/// proxy that the traffic is being routed through. The proxy endpoints come from
/// the system proxy settings (read by the app); a curated set of well-known
/// loopback proxy ports is also flagged so an explicitly-configured local proxy
/// is recognised even when it is not the *system* proxy.
public struct ProxyDetector: Sendable {
    public let proxyEndpoints: Set<Endpoint>
    public let loopbackProxyPorts: Set<UInt16>

    /// Ports commonly used by local proxy/forward engines (SOCKS/HTTP), used
    /// only for loopback addresses to keep false positives low.
    public static let commonLoopbackProxyPorts: Set<UInt16> = [
        1080, 1086, 1087, // SOCKS / common forwarders
        6152, 6153, // Surge
        7890, 7891, 7897, // Clash / Mihomo
        8889 // common alt HTTP proxy
    ]

    public init(
        proxyEndpoints: [Endpoint] = [],
        loopbackProxyPorts: Set<UInt16> = commonLoopbackProxyPorts
    ) {
        self.proxyEndpoints = Set(proxyEndpoints)
        self.loopbackProxyPorts = loopbackProxyPorts
    }

    /// Whether traffic to `remote` is routed through a configured or well-known
    /// local proxy.
    public func routesThroughProxy(_ remote: Endpoint) -> Bool {
        if proxyEndpoints.contains(remote) { return true }
        if remote.address.scope == .loopback, loopbackProxyPorts.contains(remote.port) { return true }
        return false
    }
}

/// Recognises NetworkExtension VPN/tunnel and proxy-engine processes — the ones
/// that carry *other* apps' traffic, so the kernel attributes proxied bytes to
/// them. Used to badge such flows as routed through a tunnel.
public enum TunnelProcess {
    /// Lowercased substrings that mark a tunnel/VPN/proxy engine. Conservative
    /// enough to avoid matching ordinary apps.
    static let keywords: [String] = [
        "tunnelprovider", "packettunnel", "networkextension",
        "vpn", "wireguard", "tailscale", "openvpn",
        "loon", "surge", "clash", "mihomo", "sing-box",
        "shadowrocket", "quantumult", "v2ray", "tun2socks"
    ]

    /// Whether a process name looks like a VPN/tunnel/proxy carrier.
    public static func isTunnel(_ processName: String) -> Bool {
        let name = processName.lowercased()
        return keywords.contains { name.contains($0) }
    }
}
