/// Pure helpers for rendering a remote address as either its IP or its resolved
/// domain name, driven by a user toggle. Used by the Connections, Packets, and
/// Map views so they all honour the same preference.
public enum AddressDisplay {
    /// The host string for a remote: the domain when `showDomains` is on and a
    /// non-empty `name` is known, otherwise the IP.
    public static func host(ip: String, name: String?, showDomains: Bool) -> String {
        if showDomains, let name, !name.isEmpty {
            return name
        }
        return ip
    }

    /// Rewrites a packet summary like `TCP 1.2.3.4:80 → 5.6.7.8:443`, replacing
    /// each `IP:port` whose IP has a known name with `name:port`. Matches whole
    /// space-separated tokens split at the last colon, so an IP that merely
    /// contains a known IP as a substring is never corrupted.
    public static func rewriteSummary(_ summary: String, names: [String: String]) -> String {
        guard !names.isEmpty else { return summary }
        return summary
            .split(separator: " ", omittingEmptySubsequences: false)
            .map { token -> Substring in
                guard let colon = token.lastIndex(of: ":") else { return token }
                let host = String(token[token.startIndex ..< colon])
                guard let name = names[host], !name.isEmpty else { return token }
                return Substring(name + token[colon...])
            }
            .joined(separator: " ")
    }
}
