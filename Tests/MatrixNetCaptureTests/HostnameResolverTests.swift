import Foundation
import MatrixNetModel
import Testing
@testable import MatrixNetCapture

@Suite("HostnameResolver")
struct HostnameResolverTests {
    @Test("resolves and caches hostnames using the injected lookup")
    func resolvesAndCaches() async throws {
        let resolver = HostnameResolver { ip in
            ip == IPAddress("1.1.1.1") ? "one.one.one.one" : nil
        }
        let target = try #require(IPAddress("1.1.1.1"))
        await resolver.resolveIfNeeded([target])

        // Lookups run in detached tasks; poll briefly for the cached result.
        var resolved: String?
        for _ in 0 ..< 50 {
            resolved = await resolver.snapshot()[target]
            if resolved != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(resolved == "one.one.one.one")
    }

    @Test("does not cache when the lookup returns nil")
    func negativeLookup() async throws {
        let resolver = HostnameResolver { _ in nil }
        let target = try #require(IPAddress("203.0.113.7"))
        await resolver.resolveIfNeeded([target])
        try await Task.sleep(for: .milliseconds(50))
        #expect(await resolver.snapshot()[target] == nil)
    }

    @Test("remembers a failed lookup so it is not re-launched every call")
    func negativeResultIsCachedWithinTTL() async throws {
        let counter = LookupCounter()
        let resolver = HostnameResolver { _ in
            counter.increment()
            return nil // never resolves (e.g. a fake-IP with no PTR record)
        }
        let target = try #require(IPAddress("203.0.113.7"))
        await resolver.resolveIfNeeded([target])
        try await Task.sleep(for: .milliseconds(60))
        // A second round within the negative TTL must NOT launch another
        // blocking lookup — otherwise the ~1s refresh loop re-resolves every
        // non-resolving IP forever, saturating the lookup pool.
        await resolver.resolveIfNeeded([target])
        try await Task.sleep(for: .milliseconds(40))
        #expect(counter.value == 1)
    }

    @Test("retries a failed lookup once the negative TTL has elapsed")
    func negativeCacheExpiresAfterTTL() async throws {
        let counter = LookupCounter()
        let clock = MutableClock(start: Date(timeIntervalSince1970: 1_000))
        let resolver = HostnameResolver(
            lookup: { _ in
                counter.increment()
                return nil
            },
            negativeTTL: 60,
            now: { clock.value }
        )
        let target = try #require(IPAddress("203.0.113.7"))
        await resolver.resolveIfNeeded([target])
        try await Task.sleep(for: .milliseconds(60))
        #expect(counter.value == 1)

        // Still inside the TTL window: must not retry.
        clock.advance(30)
        await resolver.resolveIfNeeded([target])
        try await Task.sleep(for: .milliseconds(40))
        #expect(counter.value == 1)

        // Past the TTL: a transient miss is allowed to recover.
        clock.advance(40)
        await resolver.resolveIfNeeded([target])
        try await Task.sleep(for: .milliseconds(60))
        #expect(counter.value == 2)
    }

    @Test("does not launch duplicate lookups for the same IP")
    func deduplicatesInFlight() async throws {
        let counter = LookupCounter()
        let resolver = HostnameResolver { ip in
            counter.increment()
            return ip == IPAddress("9.9.9.9") ? "dns9" : nil
        }
        let target = try #require(IPAddress("9.9.9.9"))
        await resolver.resolveIfNeeded([target, target, target])
        try await Task.sleep(for: .milliseconds(50))
        // Already cached: a second round must not look up again.
        await resolver.resolveIfNeeded([target])
        try await Task.sleep(for: .milliseconds(30))
        #expect(counter.value == 1)
        #expect(await resolver.snapshot()[target] == "dns9")
    }
}

private final class LookupCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}

/// A hand-advanced clock so the negative-cache TTL can be tested deterministically.
private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(start: Date) {
        date = start
    }

    var value: Date {
        lock.withLock { date }
    }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { date += seconds }
    }
}
