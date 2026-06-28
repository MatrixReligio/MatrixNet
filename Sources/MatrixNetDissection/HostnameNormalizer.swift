import Foundation

/// Normalizes hostnames observed in TLS SNI and DNS records to a stable form for
/// the IP→hostname enrichment map: trimmed, lowercased, and without the trailing
/// root dot. Empty or root-only input is rejected.
public enum HostnameNormalizer {
    public static func normalize(_ raw: String) -> String? {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        return host.isEmpty ? nil : host
    }
}
