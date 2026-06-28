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

    @Test("443 to a known DoH resolver hostname is DoH with the provider name")
    func doh() {
        func doh(_ host: String) -> DNSTransport {
            DNSEncryptionClassifier.classify(proto: .tcp, port: 443, hostname: host)
        }
        #expect(doh("cloudflare-dns.com") == .doh(resolver: "Cloudflare"))
        #expect(doh("mozilla.cloudflare-dns.com") == .doh(resolver: "Cloudflare")) // subdomain
        #expect(doh("DNS.GOOGLE") == .doh(resolver: "Google")) // case-insensitive
        #expect(doh("dns.quad9.net") == .doh(resolver: "Quad9"))
        #expect(doh("dns.nextdns.io") == .doh(resolver: "NextDNS"))
        #expect(doh("doh.opendns.com") == .doh(resolver: "OpenDNS"))
        #expect(doh("dns.adguard-dns.com") == .doh(resolver: "AdGuard"))
        #expect(doh("doh.cleanbrowsing.org") == .doh(resolver: "CleanBrowsing"))
        #expect(doh("dns.controld.com") == .doh(resolver: "Control D"))
    }

    @Test("a provider's homepage or a look-alike host is NOT misreported as DoH")
    func notDoH() {
        func cls(_ host: String?) -> DNSTransport {
            DNSEncryptionClassifier.classify(proto: .tcp, port: 443, hostname: host)
        }
        #expect(cls("example.com") == .none)
        #expect(cls(nil) == .none)
        // Provider corporate/product homepages are plain HTTPS, not resolvers.
        #expect(cls("opendns.com") == .none)
        #expect(cls("quad9.net") == .none)
        #expect(cls("nextdns.io") == .none)
        #expect(cls("controld.com") == .none)
        #expect(cls("adguard-dns.com") == .none)
        // Look-alikes / subdomain spoofing must not match.
        #expect(cls("notcloudflare-dns.com") == .none)
        #expect(cls("dns.google.attacker.com") == .none)
        #expect(cls("evilquad9.net") == .none)
        // DoH over HTTP/3 (UDP 443) is out of scope — must not be DoT/DoQ/DoH here.
        #expect(DNSEncryptionClassifier.classify(proto: .udp, port: 443, hostname: "cloudflare-dns.com") == .none)
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
