# Per-App Encrypted DNS Detection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Passively classify each connection/app's DNS transport (plaintext / DoT / DoQ / DoH / local discovery) from the 5-tuple + observed hostname, and surface a per-app DNS privacy posture in the connection inspector.

**Architecture:** A pure, stateless classifier (`DNSEncryptionClassifier` + `DNSTransport`) in `MatrixNetModel` decides the transport from `(proto, port, hostname)`; a curated static DoH-provider suffix table maps known resolver hostnames to friendly names. The app classifies each connection on the fly (no new persistence) and aggregates per app into `AppDNSPosture`. Works during ordinary NStat monitoring — NOT capture-only.

**Tech Stack:** Swift 6 strict concurrency, Swift Testing, SwiftUI. No new dependencies.

## Global Constraints

- **Not capture-only:** classification uses only `(proto, port, remoteHostname)` available from connections during normal monitoring.
- **TDD:** failing test first; full suite green; zero `swiftlint --strict` / `swiftformat --lint` warnings.
- **DoH needs a hostname:** 443 + hostname in the DoH suffix table → DoH; 443 without a known hostname → `.none` (never guess).
- **Localization:** every new user-facing string in all 8 languages (en + de/es/fr/ja/ko/zh-Hans/zh-Hant).
- **English public docs/code comments; Chinese internal.** Apache-2.0.
- **UI verification via `scripts/smoke.sh`** (Developer-ID signed) — never an ad-hoc build (TCC prompt).
- **Full regression before review:** `swift test` + verify the built artifact, not just unit tests.
- **Version:** target **1.5.0 (build 36)** (1.4.1/35 shipped the GeoIP fix). Commit identity `Jim Ho <jim.ho@matrixreligio.com>`, no Claude authorship. CI is canonical; verify appcast `sparkle:version=36`.

---

## File Structure

- Create `Sources/MatrixNetModel/DNSTransport.swift` — `DNSTransport` enum + `AppDNSPosture`.
- Create `Sources/MatrixNetModel/DNSEncryptionClassifier.swift` — `classify` + `knownDoHProvider` + static provider table.
- Test `Tests/MatrixNetModelTests/DNSEncryptionClassifierTests.swift`.
- Modify `App/Sources/AppModel.swift` — `dnsTransport(for:)` + `dnsPosture(for:)` (computed from current connections; no persistence).
- Modify `App/Sources/ConnectionInspector.swift` — "DNS" row.
- Modify `App/Resources/Localizable.xcstrings` — new strings ×8.
- Docs: `CHANGELOG.md`, `README.md` + 7 translations, `project.yml`.

---

## Task 0: Pure classifier (Phase 0 spike) — `DNSTransport`, `DNSEncryptionClassifier`, `AppDNSPosture`

> `swift test` only. No app changes, no version bump. Must be green + reviewed before Task 1.

**Files:**
- Create: `Sources/MatrixNetModel/DNSTransport.swift`
- Create: `Sources/MatrixNetModel/DNSEncryptionClassifier.swift`
- Test: `Tests/MatrixNetModelTests/DNSEncryptionClassifierTests.swift`

**Interfaces (produced):**
- `public enum DNSTransport: Sendable, Equatable { case plaintext, dot, doq, doh(resolver: String?), localDiscovery, none; var isEncrypted: Bool; var isDNS: Bool }`
- `public struct AppDNSPosture: Sendable, Equatable { let app: String; let transports: Set<DNSTransport>; var usesPlaintext: Bool; var usesEncrypted: Bool }`
- `public enum DNSEncryptionClassifier { static func classify(proto: TransportProtocol, port: UInt16, hostname: String?) -> DNSTransport; static func knownDoHProvider(_ hostname: String) -> String? }`

### Algorithm (exact)
`classify(proto:port:hostname:)`:
- port `53` → `.plaintext` (UDP or TCP).
- port `853` && proto `.tcp` → `.dot`; port `853` && proto `.udp` → `.doq`.
- port `5353` or `5355` → `.localDiscovery` (mDNS / LLMNR).
- port `443` && proto `.tcp`, and `hostname` non-nil with `knownDoHProvider(hostname) != nil` → `.doh(resolver: provider)`.
- else → `.none`.

`knownDoHProvider(_:)`: lowercase the host; return the provider name if the host equals or ends with `"." + entry.suffix` for any table entry, else nil. Table (suffix → name):
- `cloudflare-dns.com` → "Cloudflare"; `mozilla.cloudflare-dns.com` covered by suffix.
- `dns.google` → "Google"; `dns.google.com` → "Google".
- `dns.quad9.net` → "Quad9"; `quad9.net` → "Quad9".
- `dns.nextdns.io` → "NextDNS"; `nextdns.io` → "NextDNS".
- `doh.opendns.com` → "OpenDNS"; `opendns.com` → "OpenDNS".
- `dns.adguard-dns.com` → "AdGuard"; `adguard-dns.com` → "AdGuard".
- `doh.cleanbrowsing.org` → "CleanBrowsing".
- `dns.controld.com` → "Control D".

`AppDNSPosture`: `usesPlaintext = transports.contains(.plaintext)`; `usesEncrypted = transports.contains { $0.isEncrypted }`. `DNSTransport.isEncrypted` = true for `.dot/.doq/.doh`; false otherwise. `isDNS` = true for everything except `.none`.

- [ ] **Step 1: Write failing tests**

```swift
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
```

- [ ] **Step 2: Run, verify failure** — `swift test --filter DNSEncryptionClassifier` → compile error (types undefined).

- [ ] **Step 3: Create `DNSTransport.swift`**

```swift
/// How an app's DNS queries travel — the basis of its DNS privacy posture.
public enum DNSTransport: Sendable, Equatable {
    /// Cleartext DNS on port 53 — visible to the local network and ISP.
    case plaintext
    /// DNS over TLS (RFC 7858), TCP port 853.
    case dot
    /// DNS over QUIC (RFC 9250), UDP port 853.
    case doq
    /// DNS over HTTPS (RFC 8484) — port 443 to a known resolver; `resolver` is a
    /// friendly provider name when recognized.
    case doh(resolver: String?)
    /// Link-local multicast name resolution (mDNS / LLMNR) — does not leave the LAN.
    case localDiscovery
    /// Not DNS traffic.
    case none

    /// Whether queries on this transport are encrypted in transit.
    public var isEncrypted: Bool {
        switch self {
        case .dot, .doq, .doh: true
        case .plaintext, .localDiscovery, .none: false
        }
    }

    /// Whether this is DNS at all (any transport except `.none`).
    public var isDNS: Bool { self != .none }
}

/// An app's aggregate DNS privacy posture across its observed connections.
public struct AppDNSPosture: Sendable, Equatable {
    public let app: String
    public let transports: Set<DNSTransport>

    public init(app: String, transports: Set<DNSTransport>) {
        self.app = app
        self.transports = transports
    }

    /// Whether the app sends any cleartext DNS (a privacy concern).
    public var usesPlaintext: Bool { transports.contains(.plaintext) }
    /// Whether the app uses any encrypted DNS transport.
    public var usesEncrypted: Bool { transports.contains { $0.isEncrypted } }
}
```

Note: `DNSTransport` must be `Hashable` to live in a `Set`. Add `Hashable` to the enum's conformances (`Sendable, Equatable, Hashable`).

- [ ] **Step 4: Create `DNSEncryptionClassifier.swift`**

```swift
/// Classifies a connection's DNS transport from its 5-tuple and observed
/// hostname — purely, with no decryption. DoH is recognized only when the
/// destination is a known resolver hostname (the only passive DoH signal).
public enum DNSEncryptionClassifier {
    /// Known public DoH resolver host suffixes → friendly provider name.
    private static let dohProviders: [(suffix: String, name: String)] = [
        ("cloudflare-dns.com", "Cloudflare"),
        ("dns.google", "Google"),
        ("dns.google.com", "Google"),
        ("quad9.net", "Quad9"),
        ("nextdns.io", "NextDNS"),
        ("opendns.com", "OpenDNS"),
        ("adguard-dns.com", "AdGuard"),
        ("cleanbrowsing.org", "CleanBrowsing"),
        ("controld.com", "Control D")
    ]

    public static func classify(proto: TransportProtocol, port: UInt16, hostname: String?) -> DNSTransport {
        switch port {
        case 53:
            return .plaintext
        case 853:
            return proto == .udp ? .doq : .dot
        case 5353, 5355:
            return .localDiscovery
        case 443 where proto == .tcp:
            if let hostname, let provider = knownDoHProvider(hostname) {
                return .doh(resolver: provider)
            }
            return .none
        default:
            return .none
        }
    }

    /// The friendly provider name if `hostname` is a known DoH resolver, else nil.
    /// Matches the host exactly or as a subdomain of a table suffix, case-insensitively.
    public static func knownDoHProvider(_ hostname: String) -> String? {
        let host = hostname.lowercased()
        for entry in dohProviders where host == entry.suffix || host.hasSuffix("." + entry.suffix) {
            return entry.name
        }
        return nil
    }
}
```

- [ ] **Step 5: Run, verify pass** — `swift test --filter DNSEncryptionClassifier` → all green.

- [ ] **Step 6: Lint** — `swiftformat Sources/MatrixNetModel --lint && swiftlint --strict --quiet` clean.

- [ ] **Step 7: Commit**

```bash
git add Sources/MatrixNetModel/DNSTransport.swift Sources/MatrixNetModel/DNSEncryptionClassifier.swift Tests/MatrixNetModelTests/DNSEncryptionClassifierTests.swift
git commit -m "feat(model): DNSEncryptionClassifier — passive plaintext/DoT/DoQ/DoH classification"
```

- [ ] **Step 8: SPIKE GATE** — code-reviewer on the classifier (DoH false-positive risk, suffix matching edge cases, port semantics). Resolve all issues before Task 1.

---

## Task 1: App wiring + "DNS" inspector row + localization

**Files:** `App/Sources/AppModel.swift`, `App/Sources/ConnectionInspector.swift`, `App/Resources/Localizable.xcstrings`.

**Interfaces:**
- Consumes: `DNSEncryptionClassifier.classify`, `DNSTransport`, `AppDNSPosture` (Task 0).
- Produces: `AppModel.dnsTransport(for connection: Connection) -> DNSTransport`, `AppModel.dnsPosture(for app: String) -> AppDNSPosture`.

> Verified by build + `scripts/smoke.sh` signed launch + screenshot; classification logic is unit-tested in Task 0.

- [ ] **Step 1: AppModel classification helpers** (no persistence — computed from `connections`)

```swift
// MARK: - DNS privacy posture
extension AppModel {
    /// The DNS transport this connection represents (plaintext/DoT/DoQ/DoH/…).
    public func dnsTransport(for connection: Connection) -> DNSTransport {
        DNSEncryptionClassifier.classify(
            proto: connection.fiveTuple.proto,
            port: connection.fiveTuple.destination.port,
            hostname: connection.remoteHostname
        )
    }

    /// The aggregate DNS posture for an app across its current connections.
    public func dnsPosture(for app: String) -> AppDNSPosture {
        let transports = connections
            .filter { $0.app.displayName == app }
            .map { dnsTransport(for: $0) }
            .filter(\.isDNS)
        return AppDNSPosture(app: app, transports: Set(transports))
    }
}
```

- [ ] **Step 2: Inspector "DNS" row** — in `ConnectionInspector`, inside the `Flow` section (after `Routing`), show the DNS classification when the connection is DNS:

```swift
let dns = model.dnsTransport(for: connection)
if dns.isDNS {
    LabeledContent("DNS") { dnsLabel(dns) }
}
```

with a helper:

```swift
@ViewBuilder
private func dnsLabel(_ transport: DNSTransport) -> some View {
    switch transport {
    case .plaintext:
        Label("Plaintext DNS", systemImage: "lock.open")
            .foregroundStyle(Theme.advisory).font(.callout.weight(.medium))
    case .dot: Text("DNS over TLS").foregroundStyle(Theme.accent)
    case .doq: Text("DNS over QUIC").foregroundStyle(Theme.accent)
    case let .doh(resolver):
        Text(resolver.map { "DNS over HTTPS (\($0))" } ?? "DNS over HTTPS").foregroundStyle(Theme.accent)
    case .localDiscovery: Text("Local discovery (mDNS)").foregroundStyle(.secondary)
    case .none: EmptyView()
    }
}
```

- [ ] **Step 3: Localize** new strings ×8: "DNS", "Plaintext DNS", "DNS over TLS", "DNS over QUIC", "DNS over HTTPS", "Local discovery (mDNS)". ("DNS over HTTPS (%@)" uses the base "DNS over HTTPS" + provider; keep the provider name unlocalized.) Use the existing xcstrings helper pattern (preserve key order, append).

- [ ] **Step 4: Build + full test** — `swift build && swift test` green.

- [ ] **Step 5: Lint** — `swiftformat Sources App --lint && swiftlint --strict --quiet` clean.

- [ ] **Step 6: smoke + screenshot** — `./scripts/smoke.sh Release`, confirm launch (no TCC prompt) and the inspector renders the DNS row for a port-53/DoH connection.

- [ ] **Step 7: Commit**

```bash
git add App/Sources/AppModel.swift App/Sources/ConnectionInspector.swift App/Resources/Localizable.xcstrings
git commit -m "feat(app): DNS transport classification in the connection inspector"
```

---

## Task 2: Docs + version 1.5.0 (build 36) + release

- [ ] **Step 1: CHANGELOG** — `## [1.5.0]` Added: per-app encrypted DNS detection (plaintext/DoT/DoQ/DoH), shown in the connection inspector; works without packet capture.
- [ ] **Step 2: README ×8** — bullet "Per-app encrypted DNS — see which apps use plaintext DNS vs DoT/DoQ/DoH (no capture needed)" in each language, anchored after the network-quality bullet.
- [ ] **Step 3: Version** — project.yml settings.base + both info.properties → 1.5.0 / 36.
- [ ] **Step 4: Regression** — `swift test` green; `scripts/smoke.sh` signed launch; verify bundle datasets present.
- [ ] **Step 5: Commit + tag** — `release: per-app encrypted DNS detection (1.5.0)`, `git tag v1.5.0`.
- [ ] **Step 6: Push + CI** — `git push origin main --tags`; `gh workflow run release.yml -f version=v1.5.0`.
- [ ] **Step 7: Verify** — CI success; appcast `sparkle:version=36`; notarized DMG; local Developer-ID launch shows the DNS row.

---

## Self-Review
- Spec coverage: plaintext/DoT/DoQ/DoH/local classification (Task 0) ✓; DoH-by-hostname-only ✓; per-app posture ✓; inspector row (Task 1) ✓; not capture-only ✓; 1.5.0/36 + 8-lang docs (Task 2) ✓.
- No placeholders; complete code in each step. Names consistent: `DNSTransport`/`DNSEncryptionClassifier`/`classify`/`knownDoHProvider`/`AppDNSPosture`/`dnsTransport(for:)`/`dnsPosture(for:)`.
- DoH false-positive guard: only known resolver hostnames at 443 → DoH; no hostname → none.
