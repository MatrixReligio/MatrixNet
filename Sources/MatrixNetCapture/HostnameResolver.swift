import Darwin
import Foundation
import MatrixNetModel

/// Resolves remote IPs to hostnames via reverse DNS, caching results. The lookup
/// (`getnameinfo`) is a *blocking* syscall, so it must never run on Swift's
/// cooperative thread pool — that pool has only as many threads as CPU cores, and
/// blocking them violates the runtime's forward-progress guarantee (the lookups
/// would starve every other task). Instead the blocking call is dispatched to a
/// dedicated queue and the result is bridged back with a continuation; the actor
/// only ever touches the caches. The lookup function is injectable for testing.
///
/// Two caches keep the work bounded:
///  - a positive cache (IP → hostname) for addresses that resolved, and
///  - a negative cache (IP → time of last failure) for addresses that did *not*.
///
/// The negative cache is essential: most addresses have no PTR record (CDN and
/// cloud ranges, link-local peers, and the synthetic addresses a VPN/proxy hands
/// back all fail reverse DNS). Without it, the ~1s refresh loop would re-launch a
/// blocking lookup for every unresolved IP on every tick — dozens per second —
/// saturating the lookup pool and burning CPU for results that will never exist.
/// Failures are retried only after `negativeTTL`, so a genuinely transient miss
/// still recovers.
public actor HostnameResolver {
    public typealias Lookup = @Sendable (IPAddress) -> String?

    private var cache: [IPAddress: String] = [:]
    private var pending: Set<IPAddress> = []
    /// IP → time its reverse lookup last failed (no PTR record / error). Retried
    /// only once `negativeTTL` has elapsed.
    private var failures: [IPAddress: Date] = [:]
    private let lookup: Lookup
    private let negativeTTL: TimeInterval
    private let now: @Sendable () -> Date

    /// At most this many blocking lookups run at once; the rest queue in `waiting`.
    /// Caps concurrency so a burst of new connections can't spawn an unbounded
    /// number of blocking threads, while still resolving several IPs in parallel.
    private let maxConcurrent: Int
    private var inFlight = 0
    private var waiting: [IPAddress] = []

    /// Dedicated queue for the blocking `getnameinfo` calls — deliberately *not*
    /// the cooperative pool. Concurrency is bounded by `maxConcurrent` above, so
    /// this never spins up more than a handful of threads.
    private let lookupQueue = DispatchQueue(
        label: "com.matrixreligio.matrixnet.hostname-resolver",
        qos: .utility,
        attributes: .concurrent
    )

    public init(
        lookup: @escaping Lookup = HostnameResolver.systemLookup,
        negativeTTL: TimeInterval = 600,
        maxConcurrent: Int = 6,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.negativeTTL = negativeTTL
        self.maxConcurrent = max(1, maxConcurrent)
        self.now = now
        self.lookup = lookup
    }

    /// The current IP→hostname cache (successful lookups only).
    public func snapshot() -> [IPAddress: String] {
        cache
    }

    /// Kicks off reverse-DNS lookups for any IPs that are not already resolved,
    /// in flight, or within the negative-cache cooldown of a recent failure.
    public func resolveIfNeeded(_ ips: [IPAddress]) {
        let current = now()
        for ip in ips {
            guard cache[ip] == nil, !pending.contains(ip) else { continue }
            if let failedAt = failures[ip], current.timeIntervalSince(failedAt) < negativeTTL {
                continue
            }
            pending.insert(ip)
            launch(ip)
        }
    }

    /// Either starts a lookup now or parks it until a slot frees up.
    private func launch(_ ip: IPAddress) {
        guard inFlight < maxConcurrent else {
            waiting.append(ip)
            return
        }
        inFlight += 1
        let lookup = lookup
        let queue = lookupQueue
        Task { [weak self] in
            // Suspends (does not block) the calling task while the blocking
            // `getnameinfo` runs on the dedicated queue, off the cooperative pool.
            let hostname: String? = await withCheckedContinuation { continuation in
                queue.async {
                    continuation.resume(returning: lookup(ip))
                }
            }
            await self?.finish(ip, hostname)
        }
    }

    private func finish(_ ip: IPAddress, _ hostname: String?) {
        inFlight -= 1
        store(ip, hostname)
        if !waiting.isEmpty {
            launch(waiting.removeFirst())
        }
    }

    private func store(_ ip: IPAddress, _ hostname: String?) {
        pending.remove(ip)
        if let hostname, !hostname.isEmpty {
            cache[ip] = hostname
            failures[ip] = nil
        } else {
            // Remember the miss so the refresh loop stops re-resolving it every
            // tick; it is retried only after `negativeTTL`.
            failures[ip] = now()
        }
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
