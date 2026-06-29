import MatrixNetModel
import Testing
@testable import MatrixNetGeoIP

/// A test double that records how many times it was asked to resolve.
private actor StubResolver: DomainResolving {
    private let map: [String: IPAddress]
    private(set) var calls = 0
    init(_ map: [String: IPAddress]) {
        self.map = map
    }

    func resolve(_ domain: String) async -> IPAddress? {
        calls += 1
        return map[domain]
    }
}

struct ActiveGeoResolverTests {
    private func ip(_ string: String) throws -> IPAddress {
        try #require(IPAddress(string))
    }

    @Test("disabled resolver never makes a query and returns nil")
    func disabledNeverResolves() async throws {
        let realIP = try ip("104.16.123.96")
        let resolver = StubResolver(["www.cloudflare.com": realIP])
        let sut = ActiveGeoResolver(enabled: false, resolver: resolver) { _ in "US" }

        let country = await sut.country(forProxiedDomain: "www.cloudflare.com")

        #expect(country == nil)
        #expect(await resolver.calls == 0)
    }

    @Test("enabled resolver maps domain -> real IP -> country")
    func enabledResolvesDomainToCountry() async throws {
        let realIP = try ip("104.16.123.96")
        let resolver = StubResolver(["www.cloudflare.com": realIP])
        let sut = ActiveGeoResolver(enabled: true, resolver: resolver) { addr in
            addr == realIP ? "US" : nil
        }

        let country = await sut.country(forProxiedDomain: "www.cloudflare.com")

        #expect(country == "US")
        #expect(await resolver.calls == 1)
    }

    @Test("results are cached per domain so the resolver is queried once")
    func cachesResultPerDomain() async throws {
        let realIP = try ip("104.16.123.96")
        let resolver = StubResolver(["www.cloudflare.com": realIP])
        let sut = ActiveGeoResolver(enabled: true, resolver: resolver) { _ in "US" }

        _ = await sut.country(forProxiedDomain: "www.cloudflare.com")
        _ = await sut.country(forProxiedDomain: "www.cloudflare.com")

        #expect(await resolver.calls == 1)
    }

    @Test("an unresolvable domain caches the miss without re-querying")
    func cachesNegativeResult() async {
        let resolver = StubResolver([:])
        let sut = ActiveGeoResolver(enabled: true, resolver: resolver) { _ in "US" }

        let first = await sut.country(forProxiedDomain: "unknown.example")
        let second = await sut.country(forProxiedDomain: "unknown.example")

        #expect(first == nil)
        #expect(second == nil)
        #expect(await resolver.calls == 1)
    }
}
