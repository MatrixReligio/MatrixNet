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
