import Darwin
import Foundation
import MatrixNetModel

/// Resolves remote IPs to hostnames via reverse DNS, caching results. Lookups
/// run off the actor (they block), so the actor stays responsive; the UI reads
/// the cache. The lookup function is injectable for testing.
public actor HostnameResolver {
    public typealias Lookup = @Sendable (IPAddress) -> String?

    private var cache: [IPAddress: String] = [:]
    private var pending: Set<IPAddress> = []
    private let lookup: Lookup

    public init(lookup: @escaping Lookup = HostnameResolver.systemLookup) {
        self.lookup = lookup
    }

    /// The current IP→hostname cache.
    public func snapshot() -> [IPAddress: String] {
        cache
    }

    /// Kicks off reverse-DNS lookups for any IPs not already cached or in flight.
    /// Lookups run in detached tasks so the blocking `getnameinfo` never stalls
    /// the actor.
    public func resolveIfNeeded(_ ips: [IPAddress]) {
        for ip in ips where cache[ip] == nil && !pending.contains(ip) {
            pending.insert(ip)
            let lookup = lookup
            Task.detached {
                let hostname = lookup(ip)
                await self.store(ip, hostname)
            }
        }
    }

    private func store(_ ip: IPAddress, _ hostname: String?) {
        pending.remove(ip)
        if let hostname, !hostname.isEmpty { cache[ip] = hostname }
    }

    /// Reverse DNS via `getnameinfo`. Returns `nil` when no name exists.
    public static func systemLookup(_ ip: IPAddress) -> String? {
        let bytes = ip.bytes
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result: Int32

        if bytes.count == 4 {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr.s_addr = bytes.withUnsafeBytes { $0.load(as: in_addr_t.self) }
            result = withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getnameinfo(
                        $0,
                        socklen_t(MemoryLayout<sockaddr_in>.size),
                        &host,
                        socklen_t(host.count),
                        nil,
                        0,
                        NI_NAMEREQD
                    )
                }
            }
        } else {
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            withUnsafeMutableBytes(of: &addr.sin6_addr) { $0.copyBytes(from: bytes.prefix(16)) }
            result = withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getnameinfo(
                        $0,
                        socklen_t(MemoryLayout<sockaddr_in6>.size),
                        &host,
                        socklen_t(host.count),
                        nil,
                        0,
                        NI_NAMEREQD
                    )
                }
            }
        }

        guard result == 0 else { return nil }
        let name = host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let hostname = String(bytes: name, encoding: .utf8)
        return (hostname?.isEmpty == false) ? hostname : nil
    }
}
