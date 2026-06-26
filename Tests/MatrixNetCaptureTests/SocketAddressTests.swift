import MatrixNetModel
import Testing
@testable import MatrixNetCapture

private func hex(_ string: String) -> [UInt8] {
    let cleaned = string.filter { !$0.isWhitespace }
    var bytes = [UInt8]()
    var index = cleaned.startIndex
    while index < cleaned.endIndex {
        let next = cleaned.index(index, offsetBy: 2)
        bytes.append(UInt8(cleaned[index ..< next], radix: 16) ?? 0)
        index = next
    }
    return bytes
}

@Suite("SocketAddress")
struct SocketAddressTests {
    @Test("parses an IPv4 sockaddr_in as observed from NetworkStatistics")
    func parseIPv4() throws {
        // sa_len=10 family=02 port=01bb(443) addr=b73c0f18(183.60.15.24) + pad
        let endpoint = try #require(SocketAddress.endpoint(fromSockaddr: hex("100201bbb73c0f180000000000000000")))
        #expect(endpoint.address == IPAddress("183.60.15.24"))
        #expect(endpoint.port == 443)
    }

    @Test("parses a high IPv4 ephemeral port")
    func parseIPv4HighPort() throws {
        let endpoint = try #require(SocketAddress.endpoint(fromSockaddr: hex("1002e773ac1ec88000000000000000 00")))
        #expect(endpoint.address == IPAddress("172.30.200.128"))
        #expect(endpoint.port == 0xE773)
    }

    @Test("parses an IPv6 sockaddr_in6")
    func parseIPv6() throws {
        // len=1c family=1e port=01bb flow=00000000 addr=::1 scope=00000000
        let bytes = hex("1c1e 01bb 00000000 00000000000000000000000000000001 00000000")
        let endpoint = try #require(SocketAddress.endpoint(fromSockaddr: bytes))
        #expect(endpoint.address == IPAddress("::1"))
        #expect(endpoint.port == 443)
    }

    @Test("normalises IPv4-mapped IPv6 to plain IPv4")
    func normalisesIPv4Mapped() throws {
        // len=1c family=1e port=0050 flow=00000000 addr=::ffff:1.2.3.4 scope=00000000
        let bytes = hex("1c1e 0050 00000000 00000000000000000000ffff01020304 00000000")
        let endpoint = try #require(SocketAddress.endpoint(fromSockaddr: bytes))
        #expect(endpoint.address == IPAddress("1.2.3.4"))
        #expect(endpoint.port == 0x0050)
    }

    @Test("rejects malformed sockaddr blobs", arguments: [
        "",
        "10",
        "1002", // family but no port/address
        "100201bb010203", // IPv4 too short for the 4-byte address
        "99020000" // unknown family
    ])
    func rejectsMalformed(_ hexString: String) {
        #expect(SocketAddress.endpoint(fromSockaddr: hex(hexString)) == nil)
    }
}
