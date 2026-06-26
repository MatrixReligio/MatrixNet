import Testing
@testable import MatrixNetModel

@Suite("AddressScope")
struct AddressScopeTests {
    @Test("classifies IPv4 scopes", arguments: [
        ("127.0.0.1", AddressScope.loopback),
        ("10.1.2.3", .privateNetwork),
        ("172.16.0.1", .privateNetwork),
        ("172.31.255.255", .privateNetwork),
        ("172.32.0.1", .global),
        ("192.168.1.1", .privateNetwork),
        ("169.254.1.1", .linkLocal),
        ("100.64.0.1", .carrierGradeNAT),
        ("224.0.0.251", .multicast),
        ("8.8.8.8", .global)
    ])
    func ipv4(_ text: String, _ expected: AddressScope) throws {
        #expect(try #require(IPAddress(text)).scope == expected)
    }

    @Test("classifies IPv6 scopes", arguments: [
        ("::1", AddressScope.loopback),
        ("fe80::1", .linkLocal),
        ("fd00::1", .privateNetwork),
        ("ff02::1", .multicast),
        ("2606:4700::1111", .global)
    ])
    func ipv6(_ text: String, _ expected: AddressScope) throws {
        #expect(try #require(IPAddress(text)).scope == expected)
    }

    @Test("classifies IPv4-mapped IPv6 as its IPv4 scope")
    func mapped() throws {
        #expect(try #require(IPAddress("::ffff:10.0.0.1")).scope == .privateNetwork)
    }

    @Test("isLocal is true for everything except global")
    func isLocal() {
        #expect(AddressScope.privateNetwork.isLocal)
        #expect(AddressScope.loopback.isLocal)
        #expect(!AddressScope.global.isLocal)
    }
}
