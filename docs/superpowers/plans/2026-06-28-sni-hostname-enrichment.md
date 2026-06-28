# SNI/DNS Hostname Enrichment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development or superpowers:executing-plans. Steps use `- [ ]` checkboxes.

**Goal:** Show the hostname an app actually requested (TLS SNI + DNS answers) across Connections/Packets/Usage/Map, preferred over reverse-DNS (PTR).

**Architecture:** The dissector already extracts SNI and DNS answers but discards them. Surface them as `DissectedPacket.hostnames`, have the capture model feed them into the aggregator's existing `recordHostname` plumbing, and have `AppModel.publish` prefer these observed names over reverse DNS.

**Tech Stack:** Swift 6, Swift Testing, SwiftUI. No new dependencies.

## Global Constraints
- Swift 6 strict concurrency; zero warnings; SwiftLint --strict + SwiftFormat pass.
- TDD: failing test first. Open-source code/comments English; commits NO Claude authorship.
- Localize any new UI string into 8 languages; check-localizations.py passes.
- Passive only; no decryption/MITM/NetworkExtension.

---

## Task 1: Hostname normalization (pure)
**Files:** Create `Sources/MatrixNetDissection/HostnameNormalizer.swift`; Test `Tests/MatrixNetDissectionTests/HostnameNormalizerTests.swift`
**Produces:** `enum HostnameNormalizer { static func normalize(_ raw: String) -> String? }`

- [ ] Test (RED): trailing dot stripped, lowercased, empty/`.`→nil.
```swift
#expect(HostnameNormalizer.normalize("Example.COM.") == "example.com")
#expect(HostnameNormalizer.normalize("") == nil)
#expect(HostnameNormalizer.normalize(".") == nil)
#expect(HostnameNormalizer.normalize("a.b") == "a.b")
```
- [ ] Run `swift test --filter HostnameNormalizer` → fails (no symbol).
- [ ] Implement:
```swift
import Foundation
public enum HostnameNormalizer {
    public static func normalize(_ raw: String) -> String? {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        return host.isEmpty ? nil : host
    }
}
```
- [ ] Run → pass. Commit "Add hostname normalization".

## Task 2: Surface hostnames from the dissector
**Files:** Modify `Sources/MatrixNetDissection/DissectionResult.swift` (+`HostnameObservation`, `DissectedPacket.hostnames`), `Sources/MatrixNetDissection/PacketDissector.swift`; Test `Tests/MatrixNetDissectionTests/PacketDissectorHostnameTests.swift`
**Consumes:** `HostnameNormalizer`, existing `TLSDissector.dissect` (`.serverName`), `DNSDissector.dissect` (`.message.answers`).
**Produces:** `struct HostnameObservation: Sendable, Equatable { let ip: IPAddress; let name: String }`; `DissectedPacket.hostnames: [HostnameObservation]`.

- [ ] Test (RED): build a DNS-response packet and a TLS ClientHello packet (reuse byte fixtures from existing `Tests/MatrixNetDissectionTests` TLS/DNS tests; if none, construct minimal RFC bytes). Assert:
  - DNS packet → `dissected.hostnames` contains `(answerIP, queryName)`.
  - TLS ClientHello → `dissected.hostnames` contains `(destinationIP, sni)`.
  - plain TCP (no app layer) → `dissected.hostnames.isEmpty`.
- [ ] Run → fails (no `hostnames` member).
- [ ] Implement:
  - In `DissectionResult.swift`: add `HostnameObservation`; add `hostnames` to `DissectedPacket` with a defaulted initializer parameter (`hostnames: [HostnameObservation] = []`) so existing callers compile.
  - In `PacketDissector.swift`: change `parseApplicationLayer` to return `(node: DissectionNode, hostnames: [HostnameObservation])?` and accept the destination `IPAddress`. For DNS, map `message.answers` with non-nil `ip` through `HostnameNormalizer` → observations; for TLS, map `result.serverName` (normalized) + the passed destination IP. `dissect()` collects them into `DissectedPacket(hostnames:)`.
- [ ] Run → pass; run full `swift test --filter Dissection` to confirm no regression. Commit "Surface SNI/DNS hostnames from the packet dissector".

## Task 3: Aggregator hostname snapshot
**Files:** Modify `Sources/MatrixNetModel/FlowCorrelator.swift` (+`allHostnames()`), `Sources/MatrixNetCapture/ConnectionAggregator.swift` (+`hostnameSnapshot()`); Test add to `Tests/MatrixNetCaptureTests/ConnectionAggregatorTests.swift` (or a new file).
**Produces:** `FlowCorrelator.allHostnames() -> [IPAddress: String]`; `ConnectionAggregator.hostnameSnapshot() -> [IPAddress: String]`.

- [ ] Test (RED): `recordHostname("example.com", for: ip)` then `hostnameSnapshot()[ip] == "example.com"`; `reset()` clears it.
- [ ] Run → fails.
- [ ] Implement: `FlowCorrelator.allHostnames() { hostnamesByIP }`; `ConnectionAggregator.hostnameSnapshot() { await correlator.allHostnames() }`. (`recordHostname` already exists; `reset()` already clears the correlator? Verify — if the correlator isn't reset on `aggregator.reset()`, leave hostnames as session cache; adjust test accordingly.)
- [ ] Run → pass. Commit "Expose observed hostnames from the aggregator".

## Task 4: Feed dissected hostnames into the aggregator
**Files:** Modify `App/Sources/PacketCaptureModel.swift`
**Consumes:** `dissected.hostnames`, `aggregator.recordHostname`.

- [ ] (No unit test — app target; covered by aggregator tests + manual.) After obtaining `dissected` (≈ line 165), iterate `dissected.hostnames` and `await aggregator.recordHostname(obs.name, for: obs.ip)`.
- [ ] Build the app (`xcodebuild ... Debug`) → succeeds. Commit "Record SNI/DNS hostnames observed in captured packets".

## Task 5: Prefer observed hostnames over reverse DNS in AppModel
**Files:** Modify `App/Sources/AppModel.swift`
**Consumes:** `aggregator.hostnameSnapshot()`.

- [ ] In the refresh loop, fetch `let observed = await aggregator.hostnameSnapshot()` and thread it into `publish(...)`. In `publish`, when enriching `connection.remoteHostname` and building `resolvedHostnames`, prefer `observed[ip]` over the reverse-DNS `hostnames[ip]`.
- [ ] Build app → succeeds; run `swift test` (package) → all green. Commit "Prefer SNI/DNS hostnames over reverse DNS".

## Task 6: Docs + release (0.1.23)
- [ ] Bump project.yml to 0.1.23 / build 24 (×6) + `xcodegen generate`.
- [ ] CHANGELOG `## [0.1.23]` Added: exact requested hostnames via TLS SNI + DNS, preferred over reverse DNS, no decryption.
- [ ] Update the DNS/domain bullet in `README.md` + 7 translations to mention SNI.
- [ ] Full gate: swiftformat, swiftlint --strict, swift test, check-localizations → all pass; Release build.
- [ ] Commit (no Claude authorship), push, `gh workflow run release.yml -f version=v0.1.23`, watch, verify appcast `sparkle:version == 24`, local install.

## Self-Review
- Spec §3.1 → Tasks 1–2; §3.2 → Tasks 3–4; §3.3 → Task 5; §6 tests embedded; §7 docs → Task 6. Covered.
- Types: `HostnameObservation{ip,name}` defined Task 2, consumed Task 4; `hostnameSnapshot()` defined Task 3, consumed Task 5; `HostnameNormalizer.normalize` Task 1 used Task 2. Consistent.
- Placeholder check: byte fixtures referenced from existing dissection tests — confirm at execution; if absent, construct minimal bytes (not a placeholder, a documented fallback).
