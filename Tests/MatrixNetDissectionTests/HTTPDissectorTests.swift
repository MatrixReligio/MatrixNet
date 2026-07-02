import Foundation
import Testing
@testable import MatrixNetDissection

@Suite("HTTPDissector")
struct HTTPDissectorTests {
    private func ascii(_ string: String) -> [UInt8] {
        Array(string.utf8)
    }

    @Test("parses a request line and headers")
    func parsesRequest() throws {
        let request = ascii("GET /index.html HTTP/1.1\r\nHost: example.com\r\nUser-Agent: matrixnet\r\n\r\n")
        let node = try HTTPDissector.dissect(request, at: 0, detailed: true)
        #expect(node.shortName == "HTTP")
        #expect(node.fields.first { $0.name == "Method" }?.value == "GET")
        #expect(node.fields.first { $0.name == "Request URI" }?.value == "/index.html")
        #expect(node.fields.first { $0.name == "Host" }?.value == "example.com")
    }

    @Test("parses a status line")
    func parsesResponse() throws {
        let response = ascii("HTTP/1.1 404 Not Found\r\nContent-Type: text/html\r\n\r\n")
        let node = try HTTPDissector.dissect(response, at: 0, detailed: true)
        #expect(node.fields.first { $0.name == "Status Code" }?.value == "404")
        #expect(node.fields.first { $0.name == "Content-Type" }?.value == "text/html")
    }

    @Test("recognises HTTP by content for sniffing")
    func sniffing() {
        #expect(HTTPDissector.looksLikeHTTP(ascii("POST /x HTTP/1.1\r\n"), at: 0))
        #expect(HTTPDissector.looksLikeHTTP(ascii("HTTP/1.0 200 OK\r\n"), at: 0))
        #expect(!HTTPDissector.looksLikeHTTP(ascii("\u{16}\u{03}\u{01}"), at: 0))
        #expect(!HTTPDissector.looksLikeHTTP([], at: 0))
    }

    @Test("a non-HTTP payload is rejected")
    func rejectsNonHTTP() {
        #expect((try? HTTPDissector.dissect(ascii("not http at all"), at: 0, detailed: true)) == nil)
    }

    @Test("header parsing is bounded: fields beyond the scan cap are not extracted")
    func boundedHeaderScan() throws {
        // 12 KB of filler header lines with no blank line, then a notable header.
        // The dissector must not scan arbitrarily deep into a packet for headers —
        // TSO superframes hand us tens of kilobytes on the per-packet fast path.
        var text = "GET / HTTP/1.1\r\n"
        text += String(repeating: "X-Filler: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\r\n", count: 280)
        text += "Server: beyond-cap\r\n\r\n"
        let node = try HTTPDissector.dissect(ascii(text), at: 0, detailed: true)
        #expect(node.fields.first { $0.name == "Method" }?.value == "GET")
        #expect(node.fields.first { $0.name == "Server" } == nil)
    }

    @Test("body bytes after the blank line are never parsed as headers")
    func bodyNotParsedAsHeaders() throws {
        let request = ascii("POST /u HTTP/1.1\r\nHost: real.com\r\n\r\nServer: fake-in-body\r\n\r\n")
        let node = try HTTPDissector.dissect(request, at: 0, detailed: true)
        #expect(node.fields.first { $0.name == "Host" }?.value == "real.com")
        #expect(node.fields.first { $0.name == "Server" } == nil)
        #expect(node.byteRange == 0 ..< request.count)
    }

    @Test("a header line without a colon is tolerated")
    func toleratesMalformedHeader() throws {
        let request = ascii("GET / HTTP/1.1\r\ngarbageheader\r\nHost: ok.com\r\n\r\n")
        let node = try HTTPDissector.dissect(request, at: 0, detailed: true)
        #expect(node.fields.first { $0.name == "Host" }?.value == "ok.com")
    }
}
