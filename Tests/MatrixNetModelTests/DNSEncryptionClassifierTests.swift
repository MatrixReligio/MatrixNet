import Testing
@testable import MatrixNetModel

@Suite("DNSEncryptionClassifier")
struct DNSEncryptionClassifierTests {
    @Test("port 53 is plaintext DNS (TCP or UDP)")
    func plaintext() {
        #expect(DNSEncryptionClassifier.classify(proto: .udp, port: 53, hostname: nil) == .plaintext)
        #expect(DNSEncryptionClassifier.classify(proto: .tcp, port: 53, hostname: nil) == .plaintext)
    }

    @Test("port 853 is DoT over TCP and DoQ over UDP")
    func dotDoq() {
        #expect(DNSEncryptionClassifier.classify(proto: .tcp, port: 853, hostname: nil) == .dot)
        #expect(DNSEncryptionClassifier.classify(proto: .udp, port: 853, hostname: nil) == .doq)
    }

    @Test("443 to a known DoH provider hostname is DoH with the resolver name")
    func doh() {
        #expect(DNSEncryptionClassifier.classify(proto: .tcp, port: 443, hostname: "cloudflare-dns.com")
            == .doh(resolver: "Cloudflare"))
        #expect(DNSEncryptionClassifier.classify(proto: .tcp, port: 443, hostname: "mozilla.cloudflare-dns.com")
            == .doh(resolver: "Cloudflare"))
        #expect(DNSEncryptionClassifier.classify(proto: .tcp, port: 443, hostname: "DNS.GOOGLE")
            == .doh(resolver: "Google"))
    }

    @Test("443 to a non-DoH host or with no hostname is not DNS")
    func notDoH() {
        #expect(DNSEncryptionClassifier.classify(proto: .tcp, port: 443, hostname: "example.com") == .none)
        #expect(DNSEncryptionClassifier.classify(proto: .tcp, port: 443, hostname: nil) == .none)
    }

    @Test("mDNS/LLMNR ports are local discovery")
    func localDiscovery() {
        #expect(DNSEncryptionClassifier.classify(proto: .udp, port: 5353, hostname: nil) == .localDiscovery)
        #expect(DNSEncryptionClassifier.classify(proto: .udp, port: 5355, hostname: nil) == .localDiscovery)
    }

    @Test("other ports are not DNS")
    func notDNS() {
        #expect(DNSEncryptionClassifier.classify(proto: .tcp, port: 80, hostname: "example.com") == .none)
    }

    @Test("encryption and DNS predicates")
    func predicates() {
        #expect(DNSTransport.plaintext.isDNS)
        #expect(!DNSTransport.plaintext.isEncrypted)
        #expect(DNSTransport.dot.isEncrypted)
        #expect(DNSTransport.doh(resolver: "Cloudflare").isEncrypted)
        #expect(!DNSTransport.none.isDNS)
    }

    @Test("posture flags mixed plaintext and encrypted use")
    func posture() {
        let posture = AppDNSPosture(app: "App", transports: [.plaintext, .doh(resolver: "Google")])
        #expect(posture.usesPlaintext)
        #expect(posture.usesEncrypted)
    }
}
