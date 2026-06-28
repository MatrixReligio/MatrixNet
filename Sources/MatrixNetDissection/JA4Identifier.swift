/// A human label for a recognized TLS client fingerprint.
struct JA4Label: Equatable {
    let name: String
    let category: String
}

/// Maps JA4 fingerprints to recognizable TLS stacks.
///
/// Seeded with public, license-clean fingerprints of common clients; the table
/// is the seam a downloadable dataset will later replace (same self-updating
/// pattern as GeoIP/Threat). Matching is exact for now — coarser heuristics are
/// avoided so a label is never wrong.
enum JA4Identifier {
    private static let exact: [String: JA4Label] = [
        // FoxIO's canonical JA4.md example is a Chrome ClientHello.
        "t13d1516h2_8daaf6152771_e5627efa2ab1": JA4Label(name: "Chrome / Chromium", category: "Browser")
    ]

    /// The label for a JA4 fingerprint, or nil when it is not recognized.
    static func identify(_ ja4: String) -> JA4Label? {
        exact[ja4]
    }
}
