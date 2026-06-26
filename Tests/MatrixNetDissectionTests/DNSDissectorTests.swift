import MatrixNetModel
import Testing
@testable import MatrixNetDissection

@Suite("DNSDissector")
struct DNSDissectorTests {
    /// Query for example.com (A): id=1234 flags=0100 qd=1 an=ns=ar=0
    /// qname = 07 'example' 03 'com' 00, qtype=A(0001) qclass=IN(0001)
    private let query = hex("""
    1234 0100 0001 0000 0000 0000
    07 6578616d706c65 03 636f6d 00 0001 0001
    """)

    /// Response reusing a compression pointer (0xC00C) for the answer name,
    /// answer = A record 93.184.216.34, TTL 300.
    private let response = hex("""
    1234 8180 0001 0001 0000 0000
    07 6578616d706c65 03 636f6d 00 0001 0001
    C00C 0001 0001 0000012C 0004 5db8d822
    """)

    @Test("parses a DNS query name and type")
    func parsesQuery() throws {
        let result = try DNSDissector.dissect(query, at: 0)
        #expect(result.message.id == 0x1234)
        #expect(result.message.isResponse == false)
        #expect(result.message.questions.first?.name == "example.com")
        #expect(result.message.questions.first?.type == "A")
        #expect(result.node.shortName == "DNS")
    }

    @Test("parses a DNS response and extracts the answer IP via a compression pointer")
    func parsesResponse() throws {
        let result = try DNSDissector.dissect(response, at: 0)
        #expect(result.message.isResponse)
        let answer = try #require(result.message.answers.first)
        #expect(answer.name == "example.com")
        #expect(answer.type == "A")
        #expect(answer.ip == IPAddress("93.184.216.34"))
    }

    @Test("a self-referential compression pointer terminates instead of looping")
    func pointerLoopTerminates() {
        // Header claims 1 question; qname is a pointer to offset 12 (itself).
        let malicious = hex("1234 0100 0001 0000 0000 0000 C00C")
        // Must not hang or crash; either throws or yields no question name.
        let result = try? DNSDissector.dissect(malicious, at: 0)
        #expect(result == nil || result?.message.questions.first?.name.isEmpty != false)
    }

    @Test("truncated DNS payloads do not crash", arguments: 0 ... 30)
    func truncationFuzz(_ length: Int) {
        let truncated = Array(response.prefix(length))
        _ = try? DNSDissector.dissect(truncated, at: 0)
        // Reaching here without trapping is the assertion.
        #expect(Bool(true))
    }

    @Test("an oversized label length is rejected without over-reading")
    func oversizedLabel() {
        // qname label length 0x3F (63) but no bytes follow.
        let bad = hex("1234 0100 0001 0000 0000 0000 3F")
        _ = try? DNSDissector.dissect(bad, at: 0)
        #expect(Bool(true))
    }
}
