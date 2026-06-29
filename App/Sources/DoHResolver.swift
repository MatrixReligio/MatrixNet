import Foundation
import MatrixNetGeoIP
import MatrixNetModel

/// DoH (DNS-over-HTTPS) resolver used to recover the real country of a proxied
/// flow whose kernel destination is a synthetic fake-IP.
///
/// It queries an **IP-literal** endpoint (`https://1.1.1.1/dns-query`) so the
/// bootstrap lookup of the resolver's own hostname isn't itself hijacked by the
/// TUN proxy's fake-IP DNS. Plaintext DNS — even sent to a public resolver — is
/// intercepted by the TUN and answered with a fake-IP; the encrypted DoH body is
/// opaque to the proxy and carries the true address. (Verified on a real machine
/// with Loon active, 2026-06-29.)
struct DoHResolver: DomainResolving {
    func resolve(_ domain: String) async -> IPAddress? {
        var components = URLComponents(string: "https://1.1.1.1/dns-query")
        components?.queryItems = [
            URLQueryItem(name: "name", value: domain),
            URLQueryItem(name: "type", value: "A")
        ]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/dns-json", forHTTPHeaderField: "accept")
        request.timeoutInterval = 5

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = json["Answer"] as? [[String: Any]] else { return nil }

        for answer in answers where (answer["type"] as? Int) == 1 {
            if let value = answer["data"] as? String, let ip = IPAddress(value) {
                return ip
            }
        }
        return nil
    }
}
