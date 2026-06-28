# JA4 TLS Client Fingerprint × Per-App — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Passively compute the JA4 TLS client fingerprint from each ClientHello, attribute it to the originating process, identify the TLS stack, and surface it in the packet/connection inspectors — shipped as 1.2.0.

**Architecture:** A pure, dependency-free JA4 core in `MatrixNetDissection` (validated standalone via `swift test` against the FoxIO reference vector — this is the Phase 0 "spike" that de-risks the protocol math before any app change). The existing ClientHello parser is widened from SNI-only to all JA4 inputs. The fingerprint flows through `DissectedPacket` exactly like the existing hostname-observation path, gets attributed per-app in `ConnectionAggregator`, is persisted in the single shared SwiftData container, and is shown in the inspectors.

**Tech Stack:** Swift 6 (strict concurrency), Swift Testing, CryptoKit (system framework, SHA-256), SwiftData, SwiftUI.

## Global Constraints

- License Apache-2.0; **public code comments + DocC + open-source docs in English**; internal docs (spec/plan) in Chinese.
- Swift 6 strict concurrency; Swift Testing (`@Test`/`@Suite`/`#expect`/`#require`); **zero warnings**; `swiftlint --strict` and `swiftformat --lint` must be clean.
- **Git commits must NOT carry Claude/Claude Code authorship** (no `Co-Authored-By: Claude`, no "Generated with Claude Code"). Commit identity is `Jim Ho <jim.ho@matrixreligio.com>`.
- **One SwiftData container for all `@Model` types** (`SharedModelContainer`); never open a per-model container against the shared store.
- **JA4 client fingerprint only** — do NOT implement JA4S/JA4H/JA4X/JA4T (FoxIO License 1.1 + patent-pending). The JA4 client algorithm itself is BSD-3 with FoxIO's explicit patent waiver.
- **No guessing on protocol details** — every JA4 field is taken verbatim from FoxIO `technical_details/JA4.md`. Authoritative reference vector: `t13d1516h2_8daaf6152771_e5627efa2ab1`.
- 8-language localization (en source + de/es/fr/ja/ko/zh-Hans/zh-Hant) for every new user-facing string; `scripts/check-localizations.py` must pass.
- Version source of truth = `project.yml` two `info.properties` blocks (App + Widget) → set `CFBundleShortVersionString=1.2.0`, `CFBundleVersion=31`; also sync `settings.base` `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`; run `xcodegen generate` to verify.
- JA4 data only exists while the privileged capture helper (PKTAP) is running; there is **no NStat fallback** (NStat has no payload). UI must degrade to a clear "enable capture" empty state, not pretend.

## FoxIO JA4 reference (verbatim — implement exactly this)

JA4 = `JA4_a` + `_` + `JA4_b` + `_` + `JA4_c`.

- **GREASE**: a 16-bit value where byte0 == byte1 and the low nibble of each byte is `0xa` (0x0a0a, 0x1a1a, … 0xfafa). Ignore GREASE everywhere.
- **JA4_a** (10 chars): protocol (`t` TCP / `q` QUIC / `d` DTLS) + TLS version (2 chars) + SNI (`d` if extension 0x0000 present else `i`) + cipher count (2-digit decimal, GREASE excluded, **SCSV 0x00ff/0x5600 and 0xfe00–0xfeff kept**, cap 99) + extension count (2-digit, GREASE excluded, **includes SNI and ALPN**, cap 99) + ALPN first/last char.
- **TLS version** = highest value from `supported_versions` (0x002b) ignoring GREASE; else legacy ClientHello version. Map: 0x0304→`13`, 0x0303→`12`, 0x0302→`11`, 0x0301→`10`, 0x0300→`s3`, 0x0002→`s2`, 0xfeff→`d1`, 0xfefd→`d2`, 0xfefc→`d3`.
- **ALPN first/last**: no ALPN / empty → `00`; single char → that char twice; if first or last byte is ASCII alphanumeric (0x30–0x39, 0x41–0x5a, 0x61–0x7a) use those chars; else hex of first and last byte. `h2`→`h2`; `http/1.1`→`h1`.
- **JA4_b** = first 12 lowercase hex chars of SHA-256 of the cipher list: 4-char lowercase hex, GREASE excluded (SCSV/experimental kept), **sorted ascending lexicographically**, comma-joined. No ciphers → `000000000000`.
- **JA4_c** = first 12 chars of SHA-256 of `{sorted_extensions}_{signature_algorithms}` where extensions are 4-char hex, GREASE excluded, **SNI (0x0000) and ALPN (0x0010) removed**, sorted ascending, comma-joined; signature_algorithms (from ext 0x000d) are 4-char hex **in original order (not sorted)**, comma-joined. If there are no signature algorithms, JA4_c hashes just `{sorted_extensions}` (no trailing `_`). No extensions after exclusions → `000000000000`.

Reference worked example (used as the Phase 0 gate):
- ciphers `1301,1302,1303,c02b,c02f,c02c,c030,cca9,cca8,c013,c014,009c,009d,002f,0035`
  → sorted `002f,0035,009c,009d,1301,1302,1303,c013,c014,c02b,c02c,c02f,c030,cca8,cca9` → JA4_b `8daaf6152771`
- extensions `001b,0000,0033,0010,4469,0017,002d,000d,0005,0023,0012,002b,ff01,000b,000a,0015`
  → after removing 0000+0010 and sorting `0005,000a,000b,000d,0012,0015,0017,001b,0023,002b,002d,0033,4469,ff01`
  → `+ "_" +` sigalgs `0403,0804,0401,0503,0805,0501,0806,0601` → JA4_c `e5627efa2ab1`
- version 0x0304, SNI present, ALPN `h2`, 15 ciphers, 16 extensions → JA4_a `t13d1516h2`
- full: `t13d1516h2_8daaf6152771_e5627efa2ab1`

## File Structure

| File | Responsibility |
| --- | --- |
| `Sources/MatrixNetDissection/JA4.swift` (Create) | Pure JA4 string assembly: `JA4ClientHello`, `JA4.Transport`, GREASE test, `rawA/rawB/rawC`, `string(from:transport:)`, SHA-256 via CryptoKit. |
| `Sources/MatrixNetDissection/JA4Identifier.swift` (Create) | `JA4Label`, seed table of common TLS stacks, `JA4Identifier.identify(_:)`. |
| `Sources/MatrixNetDissection/TLSDissector.swift` (Modify) | Widen ClientHello parse from SNI-only to a full `JA4ClientHello`; `Result` gains `clientFingerprint`/`clientFingerprintLabel`; TLS node gets JA4 fields. |
| `Sources/MatrixNetDissection/DissectionResult.swift` (Modify) | `DissectedPacket` gains `tlsClientFingerprint: String?`. |
| `Sources/MatrixNetDissection/PacketDissector.swift` (Modify) | Thread the fingerprint from the TLS layer into `DissectedPacket`. |
| `Sources/MatrixNetModel/AppFingerprintObservation.swift` (Create) | `AppFingerprintObservation{app, ja4}` snapshot type. |
| `Sources/MatrixNetCapture/ConnectionAggregator.swift` (Modify) | `recordFingerprint`, `fingerprintsByApp`, `fingerprintSnapshot()`, reset. |
| `Sources/MatrixNetStore/AppFingerprintRecord.swift` (Create) | `@Model AppFingerprintRecord` + `StoredFingerprint` value type. |
| `Sources/MatrixNetStore/FingerprintStore.swift` (Create) | Upsert/load per-app fingerprints. |
| `Sources/MatrixNetStore/SharedModelContainer.swift` (Modify) | Register `AppFingerprintRecord` in the shared schema. |
| `App/Sources/PacketCaptureModel.swift` (Modify) | Record fingerprints from dissected rows into the aggregator. |
| `App/Sources/AppModel.swift` (Modify) | Build `FingerprintStore`; `flushFingerprints()` throttled persist; expose per-app fingerprints to the UI. |
| `App/Sources/ConnectionsView.swift` / inspector (Modify) | Show the selected connection/app's fingerprints + identified stack; empty state. |
| `docs/superpowers/notes/ja4-spike.md` (Create) | Record the real-ClientHello validation results. |
| Localization catalogs + README ×8 + CHANGELOG + DocC + NOTICE (Modify) | New strings + feature docs + JA4/FoxIO attribution. |

---

# Phase 0 — JA4 protocol core (spike: pure `swift test`, no app, no version bump)

> Goal of this phase: prove the JA4 math is correct in isolation. Everything here is in `MatrixNetDissection` and verified with `swift test --filter MatrixNetDissectionTests`. No app target is touched, nothing ships. Only after this phase is green do we integrate (Phase 1+).

### Task 0.1: GREASE detection + JA4 skeleton types

**Files:**
- Create: `Sources/MatrixNetDissection/JA4.swift`
- Test: `Tests/MatrixNetDissectionTests/JA4Tests.swift`

**Interfaces:**
- Produces: `struct JA4ClientHello: Sendable, Equatable` with `tlsVersion: UInt16`, `ciphers: [UInt16]`, `extensions: [UInt16]`, `signatureAlgorithms: [UInt16]`, `alpnFirst: [UInt8]?`, `hasSNI: Bool`. `enum JA4 { enum Transport: Sendable { case tcp, quic } ; static func isGREASE(_ v: UInt16) -> Bool }`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import MatrixNetDissection

@Suite("JA4 GREASE")
struct JA4GreaseTests {
    @Test("GREASE values are detected, real values are not")
    func grease() {
        #expect(JA4.isGREASE(0x0A0A))
        #expect(JA4.isGREASE(0x1A1A))
        #expect(JA4.isGREASE(0xFAFA))
        #expect(!JA4.isGREASE(0x1301)) // TLS_AES_128_GCM_SHA256
        #expect(!JA4.isGREASE(0x00FF)) // SCSV — not GREASE
        #expect(!JA4.isGREASE(0x0A1A)) // bytes differ
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter JA4GreaseTests`
Expected: FAIL — `JA4` / `isGREASE` not found (compile error).

- [ ] **Step 3: Write minimal implementation**

```swift
import CryptoKit
import Foundation

/// Fields parsed from a TLS ClientHello that JA4 is computed from.
struct JA4ClientHello: Sendable, Equatable {
    /// Negotiated/offered version used for JA4_a (from supported_versions, else legacy).
    var tlsVersion: UInt16
    /// Offered cipher suites, in wire order, GREASE NOT yet removed.
    var ciphers: [UInt16]
    /// Offered extension types, in wire order, GREASE NOT yet removed.
    var extensions: [UInt16]
    /// signature_algorithms (extension 0x000d) values, in wire order.
    var signatureAlgorithms: [UInt16]
    /// The first ALPN protocol's raw bytes, when an ALPN extension is present.
    var alpnFirst: [UInt8]?
    /// Whether a server_name (SNI, 0x0000) extension is present.
    var hasSNI: Bool
}

/// Computes the JA4 TLS client fingerprint (BSD-3, FoxIO patent waiver).
/// JA4S/JA4H/JA4X are deliberately not implemented (FoxIO License 1.1).
enum JA4 {
    enum Transport: Sendable { case tcp, quic }

    /// GREASE: both bytes equal and each low nibble is 0xa (RFC 8701).
    static func isGREASE(_ value: UInt16) -> Bool {
        let high = UInt8(value >> 8)
        let low = UInt8(value & 0xFF)
        return high == low && (low & 0x0F) == 0x0A
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter JA4GreaseTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MatrixNetDissection/JA4.swift Tests/MatrixNetDissectionTests/JA4Tests.swift
git commit -m "feat(dissection): JA4 skeleton + GREASE detection"
```

---

### Task 0.2: JA4_b (cipher hash) with sorting + GREASE exclusion

**Files:**
- Modify: `Sources/MatrixNetDissection/JA4.swift`
- Test: `Tests/MatrixNetDissectionTests/JA4Tests.swift`

**Interfaces:**
- Produces: `static func rawB(ciphers: [UInt16]) -> String` (pre-hash, sorted comma list), `static func partB(ciphers: [UInt16]) -> String` (12-hex hash or `000000000000`).

- [ ] **Step 1: Write the failing test**

```swift
@Suite("JA4_b ciphers")
struct JA4BTests {
    let ciphers: [UInt16] = [
        0x1301, 0x1302, 0x1303, 0xc02b, 0xc02f, 0xc02c, 0xc030,
        0xcca9, 0xcca8, 0xc013, 0xc014, 0x009c, 0x009d, 0x002f, 0x0035
    ]

    @Test("raw cipher list is GREASE-free and sorted ascending")
    func raw() {
        #expect(JA4.rawB(ciphers: [0x0A0A] + ciphers) ==
            "002f,0035,009c,009d,1301,1302,1303,c013,c014,c02b,c02c,c02f,c030,cca8,cca9")
    }

    @Test("hash matches the FoxIO reference vector")
    func hash() {
        #expect(JA4.partB(ciphers: ciphers) == "8daaf6152771")
    }

    @Test("no ciphers hashes to the zero sentinel")
    func empty() {
        #expect(JA4.partB(ciphers: [0x1A1A]) == "000000000000")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter JA4BTests`
Expected: FAIL — `rawB`/`partB` not found.

- [ ] **Step 3: Write minimal implementation** (add to `JA4`)

```swift
extension JA4 {
    private static func hex4(_ value: UInt16) -> String {
        String(format: "%04x", value)
    }

    private static func hash12(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(12).description
    }

    /// Sorted, GREASE-free, comma-joined cipher hex (the JA4_b pre-image).
    static func rawB(ciphers: [UInt16]) -> String {
        ciphers.filter { !isGREASE($0) }.map(hex4).sorted().joined(separator: ",")
    }

    static func partB(ciphers: [UInt16]) -> String {
        let raw = rawB(ciphers: ciphers)
        return raw.isEmpty ? "000000000000" : hash12(raw)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter JA4BTests`
Expected: PASS (proves SHA-256 wiring against the authoritative vector).

- [ ] **Step 5: Commit**

```bash
git add Sources/MatrixNetDissection/JA4.swift Tests/MatrixNetDissectionTests/JA4Tests.swift
git commit -m "feat(dissection): JA4_b cipher hash"
```

---

### Task 0.3: JA4_c (extension hash) with SNI/ALPN exclusion + sig-algs

**Files:**
- Modify: `Sources/MatrixNetDissection/JA4.swift`
- Test: `Tests/MatrixNetDissectionTests/JA4Tests.swift`

**Interfaces:**
- Produces: `static func rawC(extensions: [UInt16], signatureAlgorithms: [UInt16]) -> String`, `static func partC(extensions: [UInt16], signatureAlgorithms: [UInt16]) -> String`.

- [ ] **Step 1: Write the failing test**

```swift
@Suite("JA4_c extensions")
struct JA4CTests {
    let extensions: [UInt16] = [
        0x001b, 0x0000, 0x0033, 0x0010, 0x4469, 0x0017, 0x002d, 0x000d,
        0x0005, 0x0023, 0x0012, 0x002b, 0xff01, 0x000b, 0x000a, 0x0015
    ]
    let sigAlgs: [UInt16] = [0x0403, 0x0804, 0x0401, 0x0503, 0x0805, 0x0501, 0x0806, 0x0601]

    @Test("raw list removes SNI+ALPN+GREASE, sorts extensions, keeps sig-alg order")
    func raw() {
        #expect(JA4.rawC(extensions: [0x0A0A] + extensions, signatureAlgorithms: sigAlgs) ==
            "0005,000a,000b,000d,0012,0015,0017,001b,0023,002b,002d,0033,4469,ff01_0403,0804,0401,0503,0805,0501,0806,0601")
    }

    @Test("hash matches the FoxIO reference vector")
    func hash() {
        #expect(JA4.partC(extensions: extensions, signatureAlgorithms: sigAlgs) == "e5627efa2ab1")
    }

    @Test("no signature algorithms means no trailing underscore")
    func noSigAlgs() {
        #expect(JA4.rawC(extensions: [0x002b, 0x000a], signatureAlgorithms: []) == "000a,002b")
    }

    @Test("no extensions after exclusions hashes to the zero sentinel")
    func empty() {
        #expect(JA4.partC(extensions: [0x0000, 0x0010, 0x1A1A], signatureAlgorithms: []) == "000000000000")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter JA4CTests`
Expected: FAIL — `rawC`/`partC` not found.

- [ ] **Step 3: Write minimal implementation** (add to `JA4`)

```swift
extension JA4 {
    /// Sorted GREASE/SNI/ALPN-free extensions, then "_" + sig-algs in wire order.
    /// (JA4_c pre-image.) A trailing "_" is omitted when there are no sig-algs.
    static func rawC(extensions: [UInt16], signatureAlgorithms: [UInt16]) -> String {
        let exts = extensions
            .filter { !isGREASE($0) && $0 != 0x0000 && $0 != 0x0010 }
            .map(hex4)
            .sorted()
            .joined(separator: ",")
        let sigs = signatureAlgorithms.filter { !isGREASE($0) }.map(hex4).joined(separator: ",")
        return sigs.isEmpty ? exts : "\(exts)_\(sigs)"
    }

    static func partC(extensions: [UInt16], signatureAlgorithms: [UInt16]) -> String {
        let extsOnly = extensions.filter { !isGREASE($0) && $0 != 0x0000 && $0 != 0x0010 }
        if extsOnly.isEmpty { return "000000000000" }
        return hash12(rawC(extensions: extensions, signatureAlgorithms: signatureAlgorithms))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter JA4CTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MatrixNetDissection/JA4.swift Tests/MatrixNetDissectionTests/JA4Tests.swift
git commit -m "feat(dissection): JA4_c extension+sigalg hash"
```

---

### Task 0.4: JA4_a + full string assembly (the reference-vector gate)

**Files:**
- Modify: `Sources/MatrixNetDissection/JA4.swift`
- Test: `Tests/MatrixNetDissectionTests/JA4Tests.swift`

**Interfaces:**
- Produces: `static func rawA(from: JA4ClientHello, transport: Transport) -> String`, `static func string(from: JA4ClientHello, transport: Transport) -> String`.

- [ ] **Step 1: Write the failing test**

```swift
@Suite("JA4_a and full string")
struct JA4AfullTests {
    private func reference() -> JA4ClientHello {
        JA4ClientHello(
            tlsVersion: 0x0304,
            ciphers: [
                0x1301, 0x1302, 0x1303, 0xc02b, 0xc02f, 0xc02c, 0xc030,
                0xcca9, 0xcca8, 0xc013, 0xc014, 0x009c, 0x009d, 0x002f, 0x0035
            ],
            extensions: [
                0x001b, 0x0000, 0x0033, 0x0010, 0x4469, 0x0017, 0x002d, 0x000d,
                0x0005, 0x0023, 0x0012, 0x002b, 0xff01, 0x000b, 0x000a, 0x0015
            ],
            signatureAlgorithms: [0x0403, 0x0804, 0x0401, 0x0503, 0x0805, 0x0501, 0x0806, 0x0601],
            alpnFirst: Array("h2".utf8),
            hasSNI: true
        )
    }

    @Test("JA4_a matches the reference vector")
    func partA() {
        #expect(JA4.rawA(from: reference(), transport: .tcp) == "t13d1516h2")
    }

    @Test("full JA4 string matches the FoxIO reference vector")
    func full() {
        #expect(JA4.string(from: reference(), transport: .tcp) == "t13d1516h2_8daaf6152771_e5627efa2ab1")
    }

    @Test("no SNI yields i, no ALPN yields 00, GREASE excluded from counts, count caps at 99")
    func variants() {
        var hello = reference()
        hello.hasSNI = false
        hello.alpnFirst = nil
        hello.ciphers = [0x0A0A] + Array(repeating: 0x1301, count: 120)
        let a = JA4.rawA(from: hello, transport: .tcp)
        #expect(a.hasPrefix("t13i"))   // version 13, no SNI
        #expect(a.contains("99"))      // cipher count capped
        #expect(a.hasSuffix("00"))     // no ALPN
    }

    @Test("ALPN http/1.1 maps to h1; quic transport prefixes q")
    func alpnAndQuic() {
        var hello = reference()
        hello.alpnFirst = Array("http/1.1".utf8)
        #expect(JA4.rawA(from: hello, transport: .quic).hasPrefix("q13d"))
        #expect(JA4.rawA(from: hello, transport: .quic).hasSuffix("h1"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter JA4AfullTests`
Expected: FAIL — `rawA`/`string` not found.

- [ ] **Step 3: Write minimal implementation** (add to `JA4`)

```swift
extension JA4 {
    private static func versionString(_ value: UInt16) -> String {
        switch value {
        case 0x0304: "13"
        case 0x0303: "12"
        case 0x0302: "11"
        case 0x0301: "10"
        case 0x0300: "s3"
        case 0x0002: "s2"
        case 0xfeff: "d1"
        case 0xfefd: "d2"
        case 0xfefc: "d3"
        default: "00"
        }
    }

    private static func count2(_ n: Int) -> String {
        String(format: "%02d", min(n, 99))
    }

    private static func isAlnum(_ byte: UInt8) -> Bool {
        (0x30 ... 0x39).contains(byte) || (0x41 ... 0x5A).contains(byte) || (0x61 ... 0x7A).contains(byte)
    }

    /// First and last char of the first ALPN value (FoxIO rules); "00" when absent.
    private static func alpnCode(_ value: [UInt8]?) -> String {
        guard let value, let first = value.first, let last = value.last else { return "00" }
        func charOrHex(_ byte: UInt8) -> String {
            isAlnum(byte) ? String(UnicodeScalar(byte)) : String(format: "%02x", byte)
        }
        if isAlnum(first), isAlnum(last) {
            return "\(String(UnicodeScalar(first)))\(String(UnicodeScalar(last)))"
        }
        return "\(charOrHex(first))\(charOrHex(last))"
    }

    static func rawA(from hello: JA4ClientHello, transport: Transport) -> String {
        let proto = transport == .quic ? "q" : "t"
        let sni = hello.hasSNI ? "d" : "i"
        let cipherCount = count2(hello.ciphers.filter { !isGREASE($0) }.count)
        let extCount = count2(hello.extensions.filter { !isGREASE($0) }.count)
        return "\(proto)\(versionString(hello.tlsVersion))\(sni)\(cipherCount)\(extCount)\(alpnCode(hello.alpnFirst))"
    }

    static func string(from hello: JA4ClientHello, transport: Transport) -> String {
        "\(rawA(from: hello, transport: transport))_\(partB(ciphers: hello.ciphers))_\(partC(extensions: hello.extensions, signatureAlgorithms: hello.signatureAlgorithms))"
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter "JA4AfullTests"`
Expected: PASS — full string equals `t13d1516h2_8daaf6152771_e5627efa2ab1`. **This is the Phase 0 correctness gate.**

- [ ] **Step 5: Commit**

```bash
git add Sources/MatrixNetDissection/JA4.swift Tests/MatrixNetDissectionTests/JA4Tests.swift
git commit -m "feat(dissection): JA4_a + full string (FoxIO reference vector passes)"
```

---

### Task 0.5: Parse a real ClientHello's bytes into `JA4ClientHello`

**Files:**
- Modify: `Sources/MatrixNetDissection/TLSDissector.swift`
- Test: `Tests/MatrixNetDissectionTests/JA4ParseTests.swift`

**Interfaces:**
- Consumes: `ByteReader` (existing), `JA4ClientHello`.
- Produces: `static func parseClientHello(_ reader: inout ByteReader) throws -> (hello: JA4ClientHello, serverName: String?)?` in `TLSDissector`. Replaces `parseClientHelloSNI` (SNI extraction folded in).

> The test builds a real ClientHello byte layout with a helper so the bytes are auditable. It includes a GREASE cipher, GREASE extension, SNI, ALPN h2, supported_versions (GREASE + 0x0304), and signature_algorithms.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import MatrixNetDissection

@Suite("JA4 ClientHello parsing")
struct JA4ParseTests {
    /// Builds a TLS record (handshake) wrapping a ClientHello with the given parts.
    private func clientHelloRecord() -> [UInt8] {
        func u16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }

        // Extensions ----------------------------------------------------------
        // server_name: list len, type 0 (host), name len, "a.com"
        let host = Array("a.com".utf8)
        let sniInner = [0x00] + u16(host.count) + host
        let sni = u16(0x0000) + u16(sniInner.count + 2) + u16(sniInner.count) + sniInner
        // ALPN: ext_data = list len + (1-byte len + "h2")
        let alpnList = [UInt8(2)] + Array("h2".utf8)
        let alpn = u16(0x0010) + u16(alpnList.count + 2) + u16(alpnList.count) + alpnList
        // supported_versions: 1-byte list len + GREASE + 0x0304
        let svList = [UInt8(4)] + u16(0x0A0A) + u16(0x0304)
        let sv = u16(0x002b) + u16(svList.count) + svList
        // signature_algorithms: 2-byte list len + 0x0403,0x0804
        let saList = u16(4) + u16(0x0403) + u16(0x0804)
        let sa = u16(0x000d) + u16(saList.count) + saList

        let extensions = sni + alpn + sv + sa
        // Body ----------------------------------------------------------------
        let clientVersion = u16(0x0303)
        let random = [UInt8](repeating: 0, count: 32)
        let sessionID = [UInt8(0)] // length 0
        let ciphers = u16(4) + u16(0x0A0A) + u16(0x1301) // list len + GREASE + AES128
        let compression = [UInt8(1), UInt8(0)] // len 1, null
        let body = clientVersion + random + sessionID + ciphers + compression + u16(extensions.count) + extensions
        // Handshake header: type 1, 3-byte length
        let handshake = [UInt8(0x01), UInt8(body.count >> 16 & 0xff), UInt8(body.count >> 8 & 0xff), UInt8(body.count & 0xff)] + body
        // TLS record header: type 0x16, version 0x0301, length
        return [0x16, 0x03, 0x01] + u16(handshake.count) + handshake
    }

    @Test("parses ciphers, extensions, ALPN, SNI, version, sig-algs from wire bytes")
    func parse() throws {
        let result = try TLSDissector.dissect(clientHelloRecord(), at: 0)
        #expect(result.serverName == "a.com")
        // From these bytes the JA4 should be t13d (TLS1.3 via supported_versions, SNI present)
        #expect(result.clientFingerprint?.hasPrefix("t13d") == true)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter JA4ParseTests`
Expected: FAIL — `Result` has no `clientFingerprint`.

- [ ] **Step 3: Write minimal implementation**

Replace `parseClientHelloSNI` with a full parser and wire it into `dissect`. In `TLSDissector.Result` add:

```swift
    struct Result {
        let node: DissectionNode
        let serverName: String?
        let clientFingerprint: String?
        let clientFingerprintLabel: JA4Label?
    }
```

In `dissect`, in the `handshakeType == 0x01` branch:

```swift
            if handshakeType == 0x01 { // ClientHello
                if let parsed = try? parseClientHello(&reader) {
                    serverName = parsed.serverName
                    if let serverName {
                        fields.append(DissectionField(name: "Server Name", value: serverName))
                    }
                    let ja4 = JA4.string(from: parsed.hello, transport: .tcp)
                    clientFingerprint = ja4
                    clientFingerprintLabel = JA4Identifier.identify(ja4)
                    fields.append(DissectionField(name: "JA4", value: ja4))
                    if let label = clientFingerprintLabel {
                        fields.append(DissectionField(name: "Client", value: label.name))
                    }
                }
            }
```

Add the parser (replaces `parseClientHelloSNI`):

```swift
    /// Walks a ClientHello collecting every field JA4 needs (and SNI).
    private static func parseClientHello(
        _ reader: inout ByteReader
    ) throws -> (hello: JA4ClientHello, serverName: String?) {
        _ = try reader.readUInt8()  // handshake length (high)
        _ = try reader.readUInt16() // handshake length (low)
        let clientVersion = try reader.readUInt16()
        try reader.skip(32) // random
        let sessionIDLength = try Int(reader.readUInt8())
        try reader.skip(sessionIDLength)

        let cipherSuitesLength = try Int(reader.readUInt16())
        var ciphers = [UInt16]()
        var remainingCiphers = cipherSuitesLength
        while remainingCiphers >= 2 {
            ciphers.append(try reader.readUInt16())
            remainingCiphers -= 2
        }

        let compressionLength = try Int(reader.readUInt8())
        try reader.skip(compressionLength)

        var hello = JA4ClientHello(
            tlsVersion: clientVersion,
            ciphers: ciphers,
            extensions: [],
            signatureAlgorithms: [],
            alpnFirst: nil,
            hasSNI: false
        )
        var serverName: String?

        guard reader.remaining >= 2 else { return (hello, serverName) }
        var extensionsRemaining = try Int(reader.readUInt16())
        var supportedVersionMax: UInt16?

        while extensionsRemaining >= 4, reader.remaining >= 4 {
            let extensionType = try reader.readUInt16()
            let extensionLength = try Int(reader.readUInt16())
            extensionsRemaining -= 4 + extensionLength
            guard reader.remaining >= extensionLength else { break }
            hello.extensions.append(extensionType)

            switch extensionType {
            case 0x0000: // server_name
                hello.hasSNI = true
                serverName = parseSNI(&reader, length: extensionLength)
            case 0x0010: // ALPN
                hello.alpnFirst = parseFirstALPN(&reader, length: extensionLength)
            case 0x002b: // supported_versions
                supportedVersionMax = parseSupportedVersions(&reader, length: extensionLength)
            case 0x000d: // signature_algorithms
                hello.signatureAlgorithms = parseSignatureAlgorithms(&reader, length: extensionLength)
            default:
                try reader.skip(extensionLength)
            }
        }
        if let supportedVersionMax { hello.tlsVersion = supportedVersionMax }
        return (hello, serverName)
    }
```

Add the four small extension sub-parsers (each consumes exactly `length` bytes; on any shortfall they skip the remainder and return a safe default):

```swift
    private static func parseSNI(_ reader: inout ByteReader, length: Int) -> String? {
        guard let bytes = try? reader.readBytes(length), bytes.count >= 5 else { return nil }
        // server_name_list(2) + name_type(1) + name_len(2) + name
        let nameLength = Int(bytes[3]) << 8 | Int(bytes[4])
        guard bytes[2] == 0, bytes.count >= 5 + nameLength else { return nil }
        return String(bytes: bytes[5 ..< 5 + nameLength], encoding: .utf8)
    }

    private static func parseFirstALPN(_ reader: inout ByteReader, length: Int) -> [UInt8]? {
        guard let bytes = try? reader.readBytes(length), bytes.count >= 3 else { return nil }
        // ALPNProtocolNameList(2) + proto_len(1) + proto
        let protoLength = Int(bytes[2])
        guard bytes.count >= 3 + protoLength, protoLength > 0 else { return nil }
        return Array(bytes[3 ..< 3 + protoLength])
    }

    private static func parseSupportedVersions(_ reader: inout ByteReader, length: Int) -> UInt16? {
        guard let bytes = try? reader.readBytes(length), bytes.count >= 1 else { return nil }
        let listLength = Int(bytes[0])
        var best: UInt16?
        var index = 1
        while index + 1 < 1 + listLength, index + 1 < bytes.count {
            let value = UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])
            if !JA4.isGREASE(value) { best = max(best ?? 0, value) }
            index += 2
        }
        return best
    }

    private static func parseSignatureAlgorithms(_ reader: inout ByteReader, length: Int) -> [UInt16] {
        guard let bytes = try? reader.readBytes(length), bytes.count >= 2 else { return [] }
        let listLength = Int(bytes[0]) << 8 | Int(bytes[1])
        var values = [UInt16]()
        var index = 2
        while index + 1 < 2 + listLength, index + 1 < bytes.count {
            values.append(UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1]))
            index += 2
        }
        return values
    }
```

> Note: the `clientFingerprint`/`clientFingerprintLabel` vars must be declared near `serverName` at the top of `dissect` (`var clientFingerprint: String?` / `var clientFingerprintLabel: JA4Label?`) and passed into the returned `Result`. `JA4Identifier` is added in Task 0.6 — until then, temporarily set `clientFingerprintLabel = nil` and omit the identifier call, OR implement Task 0.6 first. (Recommended: do Task 0.6 before this step's identifier wiring; the test here only checks the `t13d` prefix so it passes with label nil.)

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter JA4ParseTests`
Expected: PASS — `serverName == "a.com"`, `clientFingerprint` starts `t13d`.

- [ ] **Step 5: Commit**

```bash
git add Sources/MatrixNetDissection/TLSDissector.swift Tests/MatrixNetDissectionTests/JA4ParseTests.swift
git commit -m "feat(dissection): parse full ClientHello into JA4ClientHello"
```

---

### Task 0.6: `JA4Identifier` — label common TLS stacks

**Files:**
- Create: `Sources/MatrixNetDissection/JA4Identifier.swift`
- Test: `Tests/MatrixNetDissectionTests/JA4IdentifierTests.swift`

**Interfaces:**
- Produces: `struct JA4Label: Sendable, Equatable { let name: String; let category: String }`, `enum JA4Identifier { static func identify(_ ja4: String) -> JA4Label? }`.

> Seed only fingerprints we are confident about as public facts. Matching is exact JA4 string OR JA4_a-prefix fallback (a coarse "looks like a browser/Go/curl" hint). This table is the seam a downloadable dataset will later replace.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import MatrixNetDissection

@Suite("JA4 identifier")
struct JA4IdentifierTests {
    @Test("an unknown fingerprint returns nil")
    func unknown() {
        #expect(JA4Identifier.identify("t13d000000_000000000000_000000000000") == nil)
    }

    @Test("a seeded fingerprint returns its label")
    func known() {
        // The FoxIO reference vector is a known Chrome fingerprint.
        let label = JA4Identifier.identify("t13d1516h2_8daaf6152771_e5627efa2ab1")
        #expect(label?.category == "Browser")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter JA4IdentifierTests`
Expected: FAIL — `JA4Identifier` not found.

- [ ] **Step 3: Write minimal implementation**

```swift
/// A human label for a recognized TLS client fingerprint.
struct JA4Label: Sendable, Equatable {
    let name: String
    let category: String
}

/// Maps JA4 fingerprints to recognizable TLS stacks. Seeded with public,
/// license-clean fingerprints of common clients; structured so a downloadable
/// dataset can replace the seed later (same pattern as GeoIP/Threat).
enum JA4Identifier {
    private static let exact: [String: JA4Label] = [
        "t13d1516h2_8daaf6152771_e5627efa2ab1": JA4Label(name: "Chrome / Chromium", category: "Browser")
    ]

    static func identify(_ ja4: String) -> JA4Label? {
        exact[ja4]
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter JA4IdentifierTests`
Expected: PASS.

- [ ] **Step 5: Wire the identifier into `TLSDissector`** (uncomment the `JA4Identifier.identify(ja4)` call from Task 0.5 Step 3 if it was left nil), then run the full module suite:

Run: `swift test --filter MatrixNetDissectionTests`
Expected: PASS — all JA4 + existing TLS/SNI tests green.

- [ ] **Step 6: Commit**

```bash
git add Sources/MatrixNetDissection/JA4Identifier.swift Sources/MatrixNetDissection/TLSDissector.swift Tests/MatrixNetDissectionTests/JA4IdentifierTests.swift
git commit -m "feat(dissection): JA4 client identification seed table"
```

---

### Task 0.7: Real-ClientHello validation + spike notes

**Files:**
- Create: `docs/superpowers/notes/ja4-spike.md`

> No production code — this is the "small demo proves the tech" gate the user asked for, documented like `capture-spike.md`.

- [ ] **Step 1: Capture a real ClientHello**

Run (records the ClientHello hex without needing root; `-msg` prints handshake bytes):

```bash
echo | openssl s_client -connect cloudflare.com:443 -alpn h2 -msg -tls1_3 2>/dev/null | sed -n '/ClientHello/,/^$/p' | head -60
```

If `openssl s_client -msg` hex extraction is impractical, instead capture one ClientHello via the app's own PKTAP path (helper enabled) and copy the TLS record bytes from the Packets hex view.

- [ ] **Step 2: Compute and cross-check**

Feed the captured bytes through a temporary `swift test` case (or `swift -e`-style scratch test in `Tests/MatrixNetDissectionTests`) calling `TLSDissector.dissect(bytes, at:)` and print `clientFingerprint`. Cross-check the JA4_a fields by hand against the captured ClientHello (version, SNI present, cipher/extension counts, ALPN) and, if available, against Wireshark's JA4 column or the `ja4` reference tool.

- [ ] **Step 3: Record results**

Write `docs/superpowers/notes/ja4-spike.md` (Chinese, like capture-spike.md): the captured client, the bytes' key fields, the computed JA4, how it cross-checked, and any edge cases found (e.g. ECH, no ALPN). State explicitly that the FoxIO reference vector is the authoritative regression gate and lives in `JA4Tests`.

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/notes/ja4-spike.md
git commit -m "docs: JA4 protocol-core spike validation notes"
```

**Phase 0 gate (review before Phase 1):** `swift test --filter MatrixNetDissectionTests` green; reference vector passes; spike notes written; `swiftlint --strict` + `swiftformat --lint` clean on the new files. No app target touched, nothing shipped.

---

# Phase 1 — Integrate the fingerprint into the dissection output

### Task 1.1: Carry the fingerprint on `DissectedPacket`

**Files:**
- Modify: `Sources/MatrixNetDissection/DissectionResult.swift`
- Modify: `Sources/MatrixNetDissection/PacketDissector.swift`
- Test: `Tests/MatrixNetDissectionTests/PacketDissectorJA4Tests.swift`

**Interfaces:**
- Produces: `DissectedPacket.tlsClientFingerprint: String?`; `PacketDissector.dissect` populates it from the TLS layer.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import MatrixNetDissection
import MatrixNetModel

@Suite("PacketDissector JA4")
struct PacketDissectorJA4Tests {
    @Test("a dissected TLS ClientHello packet exposes its JA4")
    func fingerprint() {
        // Minimal raw-IP TCP packet carrying a ClientHello to :443.
        let payload = JA4ParseFixtures.clientHelloRecord() // shared fixture (see note)
        let packet = JA4ParseFixtures.rawIPv4TCP(toPort: 443, payload: payload)
        let result = PacketDissector().dissect(packet, linkType: .rawIP)
        #expect(result.tlsClientFingerprint?.hasPrefix("t1") == true)
    }
}
```

> Note: extract `clientHelloRecord()` and a `rawIPv4TCP(toPort:payload:)` helper into a shared `JA4ParseFixtures` enum in the test target so both `JA4ParseTests` and this test reuse them (DRY).

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PacketDissectorJA4Tests`
Expected: FAIL — `DissectedPacket` has no `tlsClientFingerprint`.

- [ ] **Step 3: Write minimal implementation**

In `DissectionResult.swift`, add the stored property + initializer parameter (default nil) to `DissectedPacket`:

```swift
    public let tlsClientFingerprint: String?
```
```swift
    public init(
        layers: [DissectionNode],
        fiveTuple: FiveTuple?,
        summary: String,
        hostnames: [HostnameObservation] = [],
        tlsClientFingerprint: String? = nil
    ) {
        // ... assign existing ...
        self.tlsClientFingerprint = tlsClientFingerprint
    }
```

In `PacketDissector.swift`, change `parseApplicationLayer` to also return the fingerprint, and thread it into the returned `DissectedPacket`. Update the TLS branch:

```swift
        if ports.source == 443 || ports.destination == 443 || TLSDissector.looksLikeTLS(bytes, at: offset) {
            guard let tls = try? TLSDissector.dissect(bytes, at: offset) else { return nil }
            let hostnames = (tls.serverName.flatMap(HostnameNormalizer.normalize))
                .map { [HostnameObservation(ip: destination, name: $0)] } ?? []
            return (tls.node, hostnames, tls.clientFingerprint)
        }
```

(Adjust the function's return tuple to `(node:, hostnames:, fingerprint:)`, defaulting `fingerprint` to nil for DNS/HTTP branches, and set `tlsClientFingerprint:` in the final `DissectedPacket(...)`.)

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter PacketDissectorJA4Tests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MatrixNetDissection Tests/MatrixNetDissectionTests
git commit -m "feat(dissection): expose JA4 on DissectedPacket"
```

---

# Phase 2 — Per-app attribution

### Task 2.1: `AppFingerprintObservation` + aggregator recording

**Files:**
- Create: `Sources/MatrixNetModel/AppFingerprintObservation.swift`
- Modify: `Sources/MatrixNetCapture/ConnectionAggregator.swift`
- Test: `Tests/MatrixNetCaptureTests/AggregatorFingerprintTests.swift`

**Interfaces:**
- Produces: `struct AppFingerprintObservation: Sendable, Equatable { let app: String; let ja4: String }`; `ConnectionAggregator.recordFingerprint(_ ja4: String, flowKey: FlowKey, pid: Int32) async`; `ConnectionAggregator.fingerprintSnapshot() -> [AppFingerprintObservation]`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import MatrixNetModel
@testable import MatrixNetCapture

@Suite("Aggregator fingerprints")
struct AggregatorFingerprintTests {
    @Test("a recorded fingerprint is attributed to its app and de-duplicated")
    func record() async {
        let aggregator = ConnectionAggregator()
        let connection = TestFixtures.connection(app: "Safari") // existing test helper
        await aggregator.apply(.added(connection))
        let key = connection.fiveTuple.flowKey
        await aggregator.recordFingerprint("t13d1516h2_aaaa_bbbb", flowKey: key, pid: connection.app.pid)
        await aggregator.recordFingerprint("t13d1516h2_aaaa_bbbb", flowKey: key, pid: connection.app.pid)
        let snap = aggregator.fingerprintSnapshot()
        #expect(snap == [AppFingerprintObservation(app: "Safari", ja4: "t13d1516h2_aaaa_bbbb")])
    }
}
```

> If `TestFixtures.connection`/`flowKey` helpers differ, mirror whatever `ConnectionAggregator` tests already use (read `Tests/MatrixNetCaptureTests`).

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AggregatorFingerprintTests`
Expected: FAIL — `AppFingerprintObservation` / `recordFingerprint` not found.

- [ ] **Step 3: Write minimal implementation**

Create `AppFingerprintObservation.swift`:

```swift
/// One TLS client fingerprint observed for an app (display name → JA4).
public struct AppFingerprintObservation: Sendable, Equatable {
    public let app: String
    public let ja4: String
    public init(app: String, ja4: String) {
        self.app = app
        self.ja4 = ja4
    }
}
```

In `ConnectionAggregator`, add state + methods:

```swift
    /// Set of JA4 fingerprints observed per app (display name). Populated only
    /// while packet capture is active (a ClientHello is needed); de-duplicated.
    private var fingerprintsByApp: [String: Set<String>] = [:]
```
```swift
    /// Records a TLS client fingerprint against the app that owns `flowKey`.
    public func recordFingerprint(_ ja4: String, flowKey: FlowKey, pid: Int32) async {
        guard let id = await correlator.connectionID(forPacketFlow: flowKey, pid: pid),
              let connection = connections[id] else { return }
        fingerprintsByApp[connection.app.displayName, default: []].insert(ja4)
    }

    /// All observed (app, JA4) pairs.
    public func fingerprintSnapshot() -> [AppFingerprintObservation] {
        fingerprintsByApp.flatMap { app, set in
            set.map { AppFingerprintObservation(app: app, ja4: $0) }
        }
    }
```

Add `fingerprintsByApp.removeAll()` to `reset()`.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AggregatorFingerprintTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MatrixNetModel/AppFingerprintObservation.swift Sources/MatrixNetCapture/ConnectionAggregator.swift Tests/MatrixNetCaptureTests/AggregatorFingerprintTests.swift
git commit -m "feat(capture): per-app JA4 attribution in the aggregator"
```

---

# Phase 3 — Persistence (single shared container)

### Task 3.1: `AppFingerprintRecord` + register in shared schema

**Files:**
- Create: `Sources/MatrixNetStore/AppFingerprintRecord.swift`
- Modify: `Sources/MatrixNetStore/SharedModelContainer.swift`
- Test: `Tests/MatrixNetStoreTests/SharedContainerFingerprintTests.swift`

**Interfaces:**
- Produces: `@Model final class AppFingerprintRecord` with `app, ja4, label, transport, firstSeen, lastSeen, count`.

- [ ] **Step 1: Write the failing test** (multi-model regression: adding the model must not drop existing tables)

```swift
import Testing
import SwiftData
@testable import MatrixNetStore

@Suite("Shared container with fingerprints")
struct SharedContainerFingerprintTests {
    @Test("all four models coexist in one in-memory container")
    func coexist() throws {
        let container = try SharedModelContainer.makeInMemory()
        let context = container.mainContext
        context.insert(AppFingerprintRecord(app: "Safari", ja4: "t13d_a_b", label: nil, transport: "tcp", firstSeen: .init(timeIntervalSince1970: 0), lastSeen: .init(timeIntervalSince1970: 0), count: 1))
        context.insert(KnownDestinationRecord(app: "Safari", country: "US", firstSeen: .init(timeIntervalSince1970: 0)))
        try context.save()
        #expect(try context.fetch(FetchDescriptor<AppFingerprintRecord>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<KnownDestinationRecord>()).count == 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SharedContainerFingerprintTests`
Expected: FAIL — `AppFingerprintRecord` not found.

- [ ] **Step 3: Write minimal implementation**

Create `AppFingerprintRecord.swift`:

```swift
import Foundation
import SwiftData

/// One TLS client fingerprint an app has used, keyed by app + JA4. The set of
/// these per app records which TLS stacks a process has been seen using.
@Model
public final class AppFingerprintRecord {
    public var app: String
    public var ja4: String
    public var label: String?
    public var transport: String
    public var firstSeen: Date
    public var lastSeen: Date
    public var count: Int

    public init(app: String, ja4: String, label: String?, transport: String, firstSeen: Date, lastSeen: Date, count: Int) {
        self.app = app
        self.ja4 = ja4
        self.label = label
        self.transport = transport
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.count = count
    }
}
```

In `SharedModelContainer.swift`, add the model to the schema:

```swift
    private static var schema: Schema {
        Schema([ConnectionHistoryRecord.self, UsageBucketRecord.self, KnownDestinationRecord.self, AppFingerprintRecord.self])
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SharedContainerFingerprintTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MatrixNetStore/AppFingerprintRecord.swift Sources/MatrixNetStore/SharedModelContainer.swift Tests/MatrixNetStoreTests/SharedContainerFingerprintTests.swift
git commit -m "feat(store): AppFingerprintRecord in the shared container"
```

---

### Task 3.2: `FingerprintStore` upsert + load

**Files:**
- Create: `Sources/MatrixNetStore/FingerprintStore.swift`
- Test: `Tests/MatrixNetStoreTests/FingerprintStoreTests.swift`

**Interfaces:**
- Produces: `struct StoredFingerprint: Sendable, Equatable { let ja4, label?, transport: ...; let firstSeen, lastSeen: Date; let count: Int }`; `@MainActor final class FingerprintStore { init(container:); static func inMemory() throws -> FingerprintStore; func record(app:ja4:label:transport:at:) throws; func load() throws -> [String: [StoredFingerprint]] }`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import MatrixNetStore

@Suite("FingerprintStore")
@MainActor
struct FingerprintStoreTests {
    @Test("repeated records de-duplicate and bump count + lastSeen")
    func upsert() throws {
        let store = try FingerprintStore.inMemory()
        let t0 = Date(timeIntervalSince1970: 100)
        let t1 = Date(timeIntervalSince1970: 200)
        try store.record(app: "Safari", ja4: "t13d_a_b", label: "Chrome / Chromium", transport: "tcp", at: t0)
        try store.record(app: "Safari", ja4: "t13d_a_b", label: "Chrome / Chromium", transport: "tcp", at: t1)
        let loaded = try store.load()
        #expect(loaded["Safari"]?.count == 1)
        let fp = try #require(loaded["Safari"]?.first)
        #expect(fp.count == 2)
        #expect(fp.firstSeen == t0)
        #expect(fp.lastSeen == t1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter FingerprintStoreTests`
Expected: FAIL — `FingerprintStore` not found.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation
import SwiftData

/// A persisted TLS fingerprint for one app.
public struct StoredFingerprint: Sendable, Equatable {
    public let ja4: String
    public let label: String?
    public let transport: String
    public let firstSeen: Date
    public let lastSeen: Date
    public let count: Int
}

/// Persists per-app TLS client fingerprints, de-duplicated by app + JA4.
@MainActor
public final class FingerprintStore {
    private let container: ModelContainer

    public init(container: ModelContainer) {
        self.container = container
    }

    /// In-memory store for tests/previews (single-model in-memory is collision-free).
    public static func inMemory() throws -> FingerprintStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return FingerprintStore(container: try ModelContainer(for: AppFingerprintRecord.self, configurations: config))
    }

    /// Records an observation, bumping count + lastSeen when (app, ja4) exists.
    public func record(app: String, ja4: String, label: String?, transport: String, at time: Date) throws {
        let context = container.mainContext
        var descriptor = FetchDescriptor<AppFingerprintRecord>(
            predicate: #Predicate { $0.app == app && $0.ja4 == ja4 }
        )
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first {
            existing.count += 1
            existing.lastSeen = max(existing.lastSeen, time)
            if let label { existing.label = label }
        } else {
            context.insert(AppFingerprintRecord(
                app: app, ja4: ja4, label: label, transport: transport,
                firstSeen: time, lastSeen: time, count: 1
            ))
        }
        try context.save()
    }

    /// All stored fingerprints grouped by app.
    public func load() throws -> [String: [StoredFingerprint]] {
        let records = try container.mainContext.fetch(FetchDescriptor<AppFingerprintRecord>())
        var result: [String: [StoredFingerprint]] = [:]
        for record in records {
            result[record.app, default: []].append(StoredFingerprint(
                ja4: record.ja4, label: record.label, transport: record.transport,
                firstSeen: record.firstSeen, lastSeen: record.lastSeen, count: record.count
            ))
        }
        return result
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter FingerprintStoreTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MatrixNetStore/FingerprintStore.swift Tests/MatrixNetStoreTests/FingerprintStoreTests.swift
git commit -m "feat(store): FingerprintStore upsert + load"
```

---

# Phase 4 — App wiring + UI + ship 1.2.0

> These tasks touch the app target. Build with `xcodegen generate && xcodebuild ... build` (app does not run under `swift test`). Each task still follows red→green where a logic test is possible; UI is verified by build + manual smoke.

### Task 4.1: Record fingerprints from the capture pipeline

**Files:**
- Modify: `App/Sources/PacketCaptureModel.swift`

**Interfaces:**
- Consumes: `ConnectionAggregator.recordFingerprint`, `DissectedPacket.tlsClientFingerprint`.

- [ ] **Step 1: Implement** — in `attribute(_:)`, after recording hostnames, record fingerprints:

```swift
        let fingerprints = rows.compactMap { row -> (String, FlowKey, Int32)? in
            guard let ja4 = row.dissected.tlsClientFingerprint, let tuple = row.dissected.fiveTuple else { return nil }
            return (ja4, tuple.flowKey, row.packet.pid)
        }
        guard !attributions.isEmpty || !hostnames.isEmpty || !fingerprints.isEmpty else { return }
        Task.detached {
            await attribution.attributePackets(attributions)
            for observation in hostnames {
                await attribution.recordHostname(observation.name, for: observation.ip)
            }
            for (ja4, flowKey, pid) in fingerprints {
                await attribution.recordFingerprint(ja4, flowKey: flowKey, pid: pid)
            }
        }
```

(Update the early-return guard from the existing two-clause form to include `fingerprints`.)

- [ ] **Step 2: Build**

Run: `xcodegen generate && xcodebuild -scheme MatrixNet -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add App/Sources/PacketCaptureModel.swift
git commit -m "feat(app): record JA4 fingerprints from captured packets"
```

---

### Task 4.2: Persist fingerprints + expose to the UI in `AppModel`

**Files:**
- Modify: `App/Sources/AppModel.swift`

**Interfaces:**
- Consumes: `FingerprintStore`, `ConnectionAggregator.fingerprintSnapshot()`, `JA4Identifier.identify`.
- Produces: `AppModel.fingerprints(for app: String) -> [StoredFingerprint]` (or an observed `@MainActor` published map the inspector reads).

- [ ] **Step 1: Implement** — mirror the existing `flushUsage` throttle pattern:
  - In `init`, build `fingerprintStore = container.map(FingerprintStore.init(container:))` from the shared container; `try? loadFingerprints()` into an in-memory `[String: [StoredFingerprint]]`.
  - Add `flushFingerprints()` (≥30s throttle, same cadence as `flushUsage`): read `await aggregator.fingerprintSnapshot()`, for each compute `label = JA4Identifier.identify(obs.ja4)?.name`, `try fingerprintStore?.record(app:ja4:label:transport: "tcp", at: Date())`; then refresh the in-memory map via `load()`.
  - Call `flushFingerprints()` from the same place `flushUsage()` is called in the refresh loop.
  - Expose `func fingerprints(for app: String) -> [StoredFingerprint] { fingerprintsByApp[app] ?? [] }`.

- [ ] **Step 2: Build**

Run: `xcodebuild -scheme MatrixNet -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add App/Sources/AppModel.swift
git commit -m "feat(app): persist per-app JA4 fingerprints with throttled flush"
```

---

### Task 4.3: Show fingerprints in the connection inspector + empty state

**Files:**
- Modify: the connection inspector view (read `App/Sources/ConnectionsView.swift` / the inspector subview it uses).
- Localization: `App/Resources/Localizable.xcstrings` (or the relevant catalog) + run the localization helper for 7 translations.

**Interfaces:**
- Consumes: `AppModel.fingerprints(for:)`, `PacketCaptureModel.isCapturing`.

- [ ] **Step 1: Implement** — in the inspector for a selected connection, add a "TLS Fingerprint" section:
  - When `model.packetCapture.isCapturing` is false and there are no fingerprints: show localized `"Enable packet capture (Settings → Capture) to see TLS fingerprints."`
  - Otherwise list `fingerprints(for: connection.app.displayName)`: the JA4 string (monospaced) + identified `label` (or localized "Unknown stack") + `firstSeen`/`count`.
  - Show the current connection's own JA4 prominently when present.

- [ ] **Step 2: Add localized strings** — add every new key to the catalog with all 7 non-English translations (de/es/fr/ja/ko/zh-Hans/zh-Hant). Strings to add (English source):
  - `"TLS Fingerprint"`
  - `"Enable packet capture (Settings → Capture) to see TLS fingerprints."`
  - `"Unknown stack"`

Run: `python3 scripts/check-localizations.py`
Expected: no missing translations.

- [ ] **Step 3: Build + manual smoke**

Run: `xcodebuild -scheme MatrixNet -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED. Manually: enable helper, capture, open a TLS connection, confirm a JA4 appears in the inspector and on the TLS layer in Packets; with capture off, confirm the empty-state text.

- [ ] **Step 4: Commit**

```bash
git add App/Sources App/Resources
git commit -m "feat(app): TLS fingerprint section in the connection inspector"
```

---

### Task 4.4: Docs, attribution, version bump, release 1.2.0

**Files:**
- Modify: `README.md` + 7 translated READMEs; `CHANGELOG.md`; DocC article(s); `NOTICE`; `project.yml`; `settings.base` (if versioned there).

- [ ] **Step 1: Open-source docs (English)** — add a feature bullet to all 8 READMEs ("JA4 TLS client fingerprinting, passive, per-app — identify which TLS stack each process uses"); add a `CHANGELOG.md` entry under a new `## [1.2.0]` heading (no empty `[Unreleased]`); add/extend a DocC article describing JA4 (English); add JA4/FoxIO attribution to `NOTICE` (JA4 algorithm © FoxIO, BSD-3-Clause).

- [ ] **Step 2: Verify localization**

Run: `python3 scripts/check-localizations.py`
Expected: pass.

- [ ] **Step 3: Bump version** — in `project.yml` set both `info.properties` blocks to `CFBundleShortVersionString: "1.2.0"`, `CFBundleVersion: "31"`; sync `settings.base` `MARKETING_VERSION: "1.2.0"`, `CURRENT_PROJECT_VERSION: "31"`.

Run: `xcodegen generate && /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" App/MatrixNet-Info.plist`
Expected: `1.2.0`.

- [ ] **Step 4: Full local verification**

Run: `swift test 2>&1 | tail -5 && swiftlint --strict 2>&1 | tail -3 && swiftformat --lint . 2>&1 | tail -3`
Expected: all tests pass; lint/format clean.

- [ ] **Step 5: Commit, push, release**

```bash
git add -A
git commit -m "release: JA4 TLS client fingerprint × per-app (1.2.0)"
git push origin main
gh workflow run Release -f version=v1.2.0
```

- [ ] **Step 6: Verify release** — after CI: confirm appcast `sparkle:version` = 31 and `shortVersionString` = 1.2.0; locally install the Developer-ID build per the project's `sign.sh` + `ditto` convention; confirm "installed: 1.2.0 (build 31)".

**Phase 4 gate (final review):** all tests green, zero warnings, lint/format clean, 8 languages complete, CI release notarized + appcast correct, local install confirmed.

---

## Self-Review

**1. Spec coverage:**
- JA4 computation (spec §4.1) → Tasks 0.1–0.4. ✅
- ClientHello full parse (spec §4.1) → Task 0.5. ✅
- Client identification (spec §2.1, §4.1) → Task 0.6. ✅
- Spike / real-bytes validation (spec §6.1, user "small demo") → Task 0.7. ✅
- Fingerprint on DissectedPacket (spec §4.2) → Task 1.1. ✅
- Per-app attribution (spec §4.2) → Task 2.1. ✅
- Persistence in shared container (spec §4.3) → Tasks 3.1–3.2. ✅
- App wiring (spec §4.3) → Tasks 4.1–4.2. ✅
- UI + empty state (spec §4.4, §5) → Task 4.3. ✅
- Localization + docs + version + release (spec §7, Global Constraints) → Task 4.4. ✅
- QUIC deferred to feature ② — `JA4.Transport.quic` seam present (Task 0.4), not wired. ✅ (in scope as a seam only)

**2. Placeholder scan:** No TBD/"handle edge cases"/"similar to". Each code step shows full code. One intentional cross-reference: Task 1.1 reuses `JA4ParseFixtures` defined when Task 0.5's fixture is extracted — noted explicitly to extract it as a shared test enum.

**3. Type consistency:** `JA4ClientHello` fields (`tlsVersion/ciphers/extensions/signatureAlgorithms/alpnFirst/hasSNI`), `JA4.string(from:transport:)`, `JA4.Transport`, `JA4Label{name,category}`, `TLSDissector.Result.clientFingerprint`/`clientFingerprintLabel`, `DissectedPacket.tlsClientFingerprint`, `AppFingerprintObservation{app,ja4}`, `recordFingerprint(_:flowKey:pid:)`, `fingerprintSnapshot()`, `AppFingerprintRecord`, `StoredFingerprint`, `FingerprintStore.record(app:ja4:label:transport:at:)`/`load()`, `flushFingerprints()` — names consistent across all tasks. ✅
