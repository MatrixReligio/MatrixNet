import Testing
@testable import MatrixNetModel

@Suite("AddressDisplay")
struct AddressDisplayTests {
    @Test("host prefers the domain when enabled and known")
    func hostPrefersDomain() {
        #expect(AddressDisplay.host(ip: "1.1.1.1", name: "one.one.one.one", showDomains: true) == "one.one.one.one")
    }

    @Test("host falls back to IP when disabled or unknown")
    func hostFallsBack() {
        #expect(AddressDisplay.host(ip: "1.1.1.1", name: "one.one.one.one", showDomains: false) == "1.1.1.1")
        #expect(AddressDisplay.host(ip: "1.1.1.1", name: nil, showDomains: true) == "1.1.1.1")
        #expect(AddressDisplay.host(ip: "1.1.1.1", name: "", showDomains: true) == "1.1.1.1")
    }

    @Test("rewriteSummary swaps known IPs (keeping the port) and leaves the rest")
    func rewrite() {
        let names = ["104.202.107.59": "edge.example.com", "8.8.8.8": "dns.google"]
        let summary = "TCP 104.202.107.59:7978 → 192.168.0.111:56277"
        #expect(
            AddressDisplay.rewriteSummary(summary, names: names)
                == "TCP edge.example.com:7978 → 192.168.0.111:56277"
        )
    }

    @Test("rewriteSummary does not corrupt an IP that merely contains a known IP")
    func rewriteNoSubstringCorruption() {
        let names = ["1.2.3.4": "host.example"]
        // 11.2.3.4 contains "1.2.3.4" as a substring but is a different host.
        #expect(AddressDisplay.rewriteSummary("TCP 11.2.3.4:80 → 1.2.3.4:443", names: names)
            == "TCP 11.2.3.4:80 → host.example:443")
    }

    @Test("rewriteSummary is a no-op with no names")
    func rewriteEmpty() {
        let summary = "TLS 1.2.3.4:443 → 5.6.7.8:51000"
        #expect(AddressDisplay.rewriteSummary(summary, names: [:]) == summary)
    }
}
