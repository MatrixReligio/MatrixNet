import Testing
@testable import MatrixNetModel

@Suite("IPAddress")
struct IPAddressTests {
    @Test("parses valid IPv4 and round-trips through description", arguments: [
        "0.0.0.0",
        "127.0.0.1",
        "192.168.1.1",
        "255.255.255.255",
        "8.8.8.8"
    ])
    func parseIPv4RoundTrip(_ text: String) throws {
        let address = try #require(IPAddress(text), "should parse \(text)")
        #expect(!address.isIPv6)
        #expect(address.description == text)
        #expect(address.bytes.count == 4)
    }

    @Test("parses valid IPv6 and round-trips with canonical compression", arguments: [
        ("::", "::"),
        ("::1", "::1"),
        ("2001:db8::1", "2001:db8::1"),
        ("fe80::1", "fe80::1"),
        // Non-canonical input normalises to canonical RFC 5952 form.
        ("2001:0db8:0000:0000:0000:0000:0000:0001", "2001:db8::1"),
        ("2001:DB8::1", "2001:db8::1")
    ])
    func parseIPv6Canonical(_ input: String, _ canonical: String) throws {
        let address = try #require(IPAddress(input), "should parse \(input)")
        #expect(address.isIPv6)
        #expect(address.description == canonical)
        #expect(address.bytes.count == 16)
    }

    @Test("rejects malformed addresses", arguments: [
        "",
        "not an ip",
        "256.0.0.1",
        "1.2.3",
        "1.2.3.4.5",
        "::g",
        "2001:db8:::1",
        "12345::",
        " 1.2.3.4",
        "1.2.3.4 ",
        "fe80::1%en0", // zone IDs are not supported; strip before parsing
        "fe80::1%"
    ])
    func rejectsMalformed(_ text: String) {
        #expect(IPAddress(text) == nil, "should reject \(text)")
    }

    @Test("parses IPv4-mapped IPv6 as a distinct v6 address")
    func ipv4MappedIsDistinct() throws {
        let mapped = try #require(IPAddress("::ffff:192.0.2.1"))
        #expect(mapped.isIPv6)
        // By design the mapped and plain forms are NOT equal; normalising them
        // is the capture layer's responsibility via `unmappedIPv4`.
        #expect(mapped != IPAddress("192.0.2.1"))
    }

    @Test("unmappedIPv4 normalises IPv4-mapped addresses and leaves others alone")
    func unmappedIPv4Normalisation() throws {
        let mapped = try #require(IPAddress("::ffff:192.0.2.1"))
        #expect(mapped.unmappedIPv4 == IPAddress("192.0.2.1"))

        let plainV4 = try #require(IPAddress("10.0.0.1"))
        #expect(plainV4.unmappedIPv4 == plainV4)

        let realV6 = try #require(IPAddress("2001:db8::1"))
        #expect(realV6.unmappedIPv4 == realV6)
    }

    @Test("round-trips through raw bytes")
    func bytesRoundTrip() throws {
        let v4 = try #require(IPAddress(bytes: [192, 168, 0, 1]))
        #expect(v4.description == "192.168.0.1")

        let v6Bytes: [UInt8] = [0x20, 0x01, 0x0D, 0xB8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
        let v6 = try #require(IPAddress(bytes: v6Bytes))
        #expect(v6.description == "2001:db8::1")
        #expect(v6.bytes == v6Bytes)
    }

    @Test("rejects byte arrays of invalid length", arguments: [0, 3, 5, 8, 15, 17])
    func rejectsInvalidByteLength(_ count: Int) {
        #expect(IPAddress(bytes: [UInt8](repeating: 0, count: count)) == nil)
    }

    @Test("equality and hashing are stable across parse paths")
    func equalityAcrossParsePaths() throws {
        let fromText = try #require(IPAddress("10.0.0.1"))
        let fromBytes = try #require(IPAddress(bytes: [10, 0, 0, 1]))
        #expect(fromText == fromBytes)
        #expect(fromText.hashValue == fromBytes.hashValue)

        let v4 = try #require(IPAddress("0.0.0.1"))
        let v6 = try #require(IPAddress("::1"))
        #expect(v4 != v6, "an IPv4 and IPv6 address with similar bytes must not be equal")
    }
}
