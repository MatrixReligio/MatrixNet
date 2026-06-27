import CFNetwork
import Foundation
import MatrixNetModel

/// App-level proxy/tunnel recognition. Reads the system proxy settings (so a
/// connection whose remote *is* the configured proxy can be flagged) and exposes
/// the pure `ProxyDetector`/`TunnelProcess` decisions to the UI.
///
/// Lookups are synchronous and called from the table body; the detector is
/// swapped atomically under a lock when the settings are refreshed.
enum ProxyInfo {
    private final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private var detector: ProxyDetector
        init(_ detector: ProxyDetector) {
            self.detector = detector
        }

        func routesThroughProxy(_ remote: Endpoint) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return detector.routesThroughProxy(remote)
        }

        func replace(with detector: ProxyDetector) {
            lock.lock()
            self.detector = detector
            lock.unlock()
        }
    }

    private static let storage = Storage(ProxyDetector(proxyEndpoints: systemProxyEndpoints()))

    /// Whether traffic to `remote` is routed through a configured/known proxy.
    static func routesThroughProxy(_ remote: Endpoint) -> Bool {
        storage.routesThroughProxy(remote)
    }

    /// Whether a process is a VPN/tunnel carrier (it relays other apps' traffic).
    static func isTunnel(_ processName: String) -> Bool {
        TunnelProcess.isTunnel(processName)
    }

    /// Re-reads the system proxy settings (cheap; safe to call periodically).
    static func refresh() {
        storage.replace(with: ProxyDetector(proxyEndpoints: systemProxyEndpoints()))
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
