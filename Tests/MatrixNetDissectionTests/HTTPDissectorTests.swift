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
        let node = try HTTPDissector.dissect(request, at: 0)
        #expect(node.shortName == "HTTP")
        #expect(node.fields.first { $0.name == "Method" }?.value == "GET")
        #expect(node.fields.first { $0.name == "Request URI" }?.value == "/index.html")
        #expect(node.fields.first { $0.name == "Host" }?.value == "example.com")
    }

    @Test("parses a status line")
    func parsesResponse() throws {
        let response = ascii("HTTP/1.1 404 Not Found\r\nContent-Type: text/html\r\n\r\n")
        let node = try HTTPDissector.dissect(response, at: 0)
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
        #expect((try? HTTPDissector.dissect(ascii("not http at all"), at: 0)) == nil)
    }

    @Test("a header line without a colon is tolerated")
    func toleratesMalformedHeader() throws {
        let request = ascii("GET / HTTP/1.1\r\ngarbageheader\r\nHost: ok.com\r\n\r\n")
        let node = try HTTPDissector.dissect(request, at: 0)
        #expect(node.fields.first { $0.name == "Host" }?.value == "ok.com")
    }
}
