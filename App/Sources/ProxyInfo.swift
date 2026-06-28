import CFNetwork
import Foundation
import MatrixNetModel
import SystemConfiguration

/// App-level proxy/tunnel recognition. Reads the system proxy settings (so a
/// connection whose remote *is* the configured proxy can be flagged) and detects
/// whether the system's default route is a tunnel (e.g. Loon/Surge in TUN mode,
/// which carries all internet traffic without setting a system proxy), then
/// exposes the pure `ProxyDetector`/`TunnelProcess` decisions to the UI.
///
/// Lookups are synchronous and called from the table body; the detector is
/// swapped atomically under a lock when the settings are refreshed.
enum ProxyInfo {
    private final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private var detector: ProxyDetector
        private var systemTunneled: Bool
        init(_ detector: ProxyDetector, systemTunneled: Bool) {
            self.detector = detector
            self.systemTunneled = systemTunneled
        }

        func routesThroughProxy(_ remote: Endpoint) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return detector.routesThroughProxyOrTunnel(remote, systemTunneled: systemTunneled)
        }

        func replace(with detector: ProxyDetector, systemTunneled: Bool) {
            lock.lock()
            self.detector = detector
            self.systemTunneled = systemTunneled
            lock.unlock()
        }
    }

    private static let storage = Storage(
        ProxyDetector(proxyEndpoints: systemProxyEndpoints()),
        systemTunneled: defaultRouteIsTunnel()
    )

    /// Whether traffic to `remote` is routed through a configured/known proxy or
    /// the system tunnel (TUN-mode VPN/proxy carrying all internet traffic).
    static func routesThroughProxy(_ remote: Endpoint) -> Bool {
        storage.routesThroughProxy(remote)
    }

    /// Whether a process is a VPN/tunnel carrier (it relays other apps' traffic).
    static func isTunnel(_ processName: String) -> Bool {
        TunnelProcess.isTunnel(processName)
    }

    /// Re-reads the system proxy settings and default-route tunnel state (cheap;
    /// safe to call periodically so toggling the VPN/proxy is reflected).
    static func refresh() {
        storage.replace(
            with: ProxyDetector(proxyEndpoints: systemProxyEndpoints()),
            systemTunneled: defaultRouteIsTunnel()
        )
    }

    /// Whether the system's default route egresses through a tunnel interface
    /// (utun/ipsec/ppp/tun/tap) — i.e. a TUN-mode VPN/proxy like Loon is carrying
    /// all internet-bound traffic, even though no system HTTP/SOCKS proxy is set.
    private static func defaultRouteIsTunnel() -> Bool {
        guard let store = SCDynamicStoreCreate(nil, "com.matrixreligio.matrixnet" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let primary = global["PrimaryInterface"] as? String else { return false }
        let tunnelPrefixes = ["utun", "ipsec", "ppp", "tun", "tap"]
        return tunnelPrefixes.contains { primary.hasPrefix($0) }
    }

    /// Reads the HTTP/HTTPS/SOCKS proxies from the system network settings,
    /// keeping those whose host is a literal IP we can match remotes against.
    private static func systemProxyEndpoints() -> [Endpoint] {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else {
            return []
        }
        var endpoints: [Endpoint] = []
        func add(enable: CFString, host: CFString, port: CFString) {
            guard settings[enable as String] as? Int == 1,
                  let hostString = settings[host as String] as? String,
                  let address = IPAddress(hostString),
                  let portNumber = settings[port as String] as? Int,
                  portNumber > 0, portNumber <= 65535 else { return }
            endpoints.append(Endpoint(address: address, port: UInt16(portNumber)))
        }
        add(enable: kCFNetworkProxiesHTTPEnable, host: kCFNetworkProxiesHTTPProxy, port: kCFNetworkProxiesHTTPPort)
        add(enable: kCFNetworkProxiesHTTPSEnable, host: kCFNetworkProxiesHTTPSProxy, port: kCFNetworkProxiesHTTPSPort)
        add(enable: kCFNetworkProxiesSOCKSEnable, host: kCFNetworkProxiesSOCKSProxy, port: kCFNetworkProxiesSOCKSPort)
        return endpoints
    }
}
